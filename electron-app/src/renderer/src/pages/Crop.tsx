// src/renderer/src/pages/Crop.tsx - Interactive image crop (free-transform).
// W/H define an output canvas; the image is a layer that can be panned and
// zoomed (drag / wheel / buttons, Photoshop-style). "开始裁剪" bakes the
// canvas content into a new image file.
import { useState, useEffect, useRef, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import { readFileBytes, writeFileBytes } from '../lib/mediaStudio';

interface Status {
  kind: 'success' | 'error' | 'info';
  text: string;
}

interface Transform {
  scale: number; // image px per canvas px
  x: number; // image top-left in canvas coords
  y: number;
}

interface Dims {
  w: number;
  h: number;
}

const ACCEPT = 'image/png,image/jpeg,image/webp,image/gif,image/bmp';
const MAX_DIM = 8192;
// Logical viewport of the preview (CSS-scaled down on narrow windows).
const VIEW = { w: 720, h: 460 };

function clampZoom(s: number): number {
  return Math.min(64, Math.max(0.02, s));
}

// Keep the canvas point (cx, cy) fixed while scaling by `factor`.
function zoomAt(t: Transform, cx: number, cy: number, factor: number): Transform {
  const scale = clampZoom(t.scale * factor);
  const k = scale / t.scale;
  return { scale, x: cx - (cx - t.x) * k, y: cy - (cy - t.y) * k };
}

function splitPath(p: string): { dir: string; nameNoExt: string } {
  const norm = p.replace(/\//g, '\\');
  const idx = norm.lastIndexOf('\\');
  const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
  const base = idx >= 0 ? norm.slice(idx + 1) : norm;
  const dot = base.lastIndexOf('.');
  const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
  return { dir, nameNoExt };
}

// Small checkerboard tile for transparent canvas areas (source canvas is
// cached; the pattern itself is created per-context).
let checkerTile: HTMLCanvasElement | null = null;
function getChecker(ctx: CanvasRenderingContext2D): CanvasPattern | null {
  if (!checkerTile) {
    const c = document.createElement('canvas');
    c.width = 16;
    c.height = 16;
    const x = c.getContext('2d');
    if (!x) return null;
    x.fillStyle = '#3a4250';
    x.fillRect(0, 0, 16, 16);
    x.fillStyle = '#2a3038';
    x.fillRect(0, 0, 8, 8);
    x.fillRect(8, 8, 8, 8);
    checkerTile = c;
  }
  return ctx.createPattern(checkerTile, 'repeat');
}

type OutFormat = 'png' | 'jpg' | 'webp';

const FORMAT_MIME: Record<OutFormat, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  webp: 'image/webp',
};

// Encode output; PNG ignores the quality argument.
function encodeCanvas(c: HTMLCanvasElement, format: OutFormat): Promise<Blob | null> {
  return new Promise((res) =>
    c.toBlob(res, FORMAT_MIME[format], format === 'png' ? undefined : 0.92),
  );
}

export function CropPage() {
  const [inputPath, setInputPath] = useState('');
  const [srcName, setSrcName] = useState('');
  const [origW, setOrigW] = useState(0);
  const [origH, setOrigH] = useState(0);
  const [wStr, setWStr] = useState('');
  const [hStr, setHStr] = useState('');
  const [dims, setDims] = useState<Dims | null>(null);
  const [transform, setTransform] = useState<Transform>({ scale: 1, x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const [estBytes, setEstBytes] = useState<number | null>(null);
  const [format, setFormat] = useState<OutFormat>('png');
  const [transparent, setTransparent] = useState(false);
  const [bgColor, setBgColor] = useState('#ffffff');
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<Status | null>(null);
  const [lastOut, setLastOut] = useState('');

  const bitmapRef = useRef<ImageBitmap | null>(null);
  const previewRef = useRef<HTMLCanvasElement>(null);
  const dragRef = useRef<{ mx: number; my: number; x: number; y: number } | null>(null);

  const handleInput = useCallback(async (p: string) => {
    setInputPath(p);
    setStatus({ kind: 'info', text: '读取图片中...' });
    setSrcName(splitPath(p).nameNoExt);
    const bytes = await readFileBytes(p);
    if (!bytes) {
      setStatus({ kind: 'error', text: '无法读取文件(路径不存在或不可访问)' });
      return;
    }
    try {
      const bmp = await createImageBitmap(new Blob([bytes]));
      bitmapRef.current = bmp;
      setOrigW(bmp.width);
      setOrigH(bmp.height);
      setWStr(String(bmp.width));
      setHStr(String(bmp.height));
      // Default the output format to the source format (gif/bmp -> png,
      // single frame only / no encoder).
      const ext = p.split('.').pop()?.toLowerCase() || '';
      setFormat(ext === 'jpg' || ext === 'jpeg' ? 'jpg' : ext === 'webp' ? 'webp' : 'png');
      const d = { w: bmp.width, h: bmp.height };
      setDims(d);
      const scale = Math.min(d.w / bmp.width, d.h / bmp.height);
      setTransform({
        scale,
        x: (d.w - bmp.width * scale) / 2,
        y: (d.h - bmp.height * scale) / 2,
      });
      setStatus({ kind: 'info', text: `已加载 ${bmp.width} x ${bmp.height} — 拖拽移动图片, 滚轮缩放` });
    } catch {
      bitmapRef.current = null;
      setDims(null);
      setStatus({ kind: 'error', text: '无法解码图片(内核不支持的格式,如 TIFF)' });
    }
  }, []);

  const handleReselect = useCallback(() => {
    setInputPath('');
    setSrcName('');
    bitmapRef.current = null;
    setDims(null);
    setStatus(null);
    setEstBytes(null);
    setOrigW(0);
    setOrigH(0);
    setWStr('');
    setHStr('');
  }, []);

  // View geometry: the W x H canvas fitted into the fixed logical viewport.
  const viewScale = dims ? Math.min((VIEW.w - 24) / dims.w, (VIEW.h - 24) / dims.h) : 1;
  const viewOx = dims ? (VIEW.w - dims.w * viewScale) / 2 : 0;
  const viewOy = dims ? (VIEW.h - dims.h * viewScale) / 2 : 0;

  // Bake the current composition into an offscreen canvas at exact output size.
  const renderOutput = useCallback((): HTMLCanvasElement | null => {
    const bmp = bitmapRef.current;
    if (!bmp || !dims) return null;
    const c = document.createElement('canvas');
    c.width = dims.w;
    c.height = dims.h;
    const ctx = c.getContext('2d');
    if (!ctx) return null;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    if (!(transparent && format !== 'jpg')) {
      ctx.fillStyle = bgColor;
      ctx.fillRect(0, 0, dims.w, dims.h);
    }
    ctx.drawImage(bmp, transform.x, transform.y, bmp.width * transform.scale, bmp.height * transform.scale);
    return c;
  }, [dims, transform, transparent, format, bgColor]);

  // Live preview: page background, canvas area (checkerboard or bg), image
  // clipped to the canvas, blue border marking the crop bounds.
  useEffect(() => {
    const cv = previewRef.current;
    if (!cv || !dims) return;
    cv.width = VIEW.w;
    cv.height = VIEW.h;
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, VIEW.w, VIEW.h);
    const cw = dims.w * viewScale;
    const ch = dims.h * viewScale;
    ctx.fillStyle = transparent && format !== 'jpg' ? '#141a22' : bgColor;
    ctx.fillRect(viewOx, viewOy, cw, ch);
    if (transparent && format !== 'jpg') {
      const pat = getChecker(ctx);
      if (pat) {
        ctx.save();
        ctx.fillStyle = pat;
        ctx.fillRect(viewOx, viewOy, cw, ch);
        ctx.restore();
      }
    }
    const bmp = bitmapRef.current;
    if (bmp) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(viewOx, viewOy, cw, ch);
      ctx.clip();
      ctx.imageSmoothingEnabled = true;
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(
        bmp,
        viewOx + transform.x * viewScale,
        viewOy + transform.y * viewScale,
        bmp.width * transform.scale * viewScale,
        bmp.height * transform.scale * viewScale,
      );
      ctx.restore();
    }
    ctx.strokeStyle = '#4d9fff';
    ctx.lineWidth = 1;
    ctx.strokeRect(viewOx + 0.5, viewOy + 0.5, cw - 1, ch - 1);
  }, [dims, transform, viewScale, viewOx, viewOy, transparent, format, bgColor]);

  // File size estimate: encode the actual output (same pixels the crop
  // writes) so the number is exact for the current composition.
  useEffect(() => {
    if (!dims) return;
    const timer = setTimeout(() => {
      const c = renderOutput();
      if (!c) return;
      encodeCanvas(c, format).then((blob) => {
        if (blob) setEstBytes(blob.size);
      });
    }, 350);
    return () => clearTimeout(timer);
  }, [dims, transform, format, transparent, bgColor, renderOutput]);

  const applyCanvas = useCallback(() => {
    const w = parseInt(wStr, 10);
    const h = parseInt(hStr, 10);
    if (!Number.isFinite(w) || !Number.isFinite(h) || w < 1 || h < 1) {
      setStatus({ kind: 'error', text: '请输入有效的宽度和高度 (>=1)' });
      return;
    }
    if (w > MAX_DIM || h > MAX_DIM) {
      setStatus({ kind: 'error', text: `宽高不能超过 ${MAX_DIM}px` });
      return;
    }
    const d = { w, h };
    setDims(d);
    const bmp = bitmapRef.current;
    const scale = bmp ? Math.min(w / bmp.width, h / bmp.height) : 1;
    setTransform({
      scale,
      x: bmp ? (w - bmp.width * scale) / 2 : 0,
      y: bmp ? (h - bmp.height * scale) / 2 : 0,
    });
  }, [wStr, hStr]);

  const fitToCanvas = useCallback(() => {
    if (!dims) return;
    const bmp = bitmapRef.current;
    if (!bmp) return;
    const scale = Math.min(dims.w / bmp.width, dims.h / bmp.height);
    setTransform({
      scale,
      x: (dims.w - bmp.width * scale) / 2,
      y: (dims.h - bmp.height * scale) / 2,
    });
  }, [dims]);

  const zoomCenter = useCallback(
    (factor: number) => {
      if (!dims) return;
      setTransform((t) => zoomAt(t, dims.w / 2, dims.h / 2, factor));
    },
    [dims],
  );

  // Wheel zoom anchored at the cursor — but ONLY when the cursor is inside
  // the W x H canvas area. Over the stage's letterbox padding (or anywhere
  // else on the page) the wheel keeps its normal page-scroll behavior.
  useEffect(() => {
    const cv = previewRef.current;
    if (!cv || !dims) return;
    const onWheel = (e: WheelEvent) => {
      const rect = cv.getBoundingClientRect();
      const k = VIEW.w / rect.width;
      const mx = (e.clientX - rect.left) * k;
      const my = (e.clientY - rect.top) * k;
      const cw = dims.w * viewScale;
      const ch = dims.h * viewScale;
      if (mx < viewOx || mx > viewOx + cw || my < viewOy || my > viewOy + ch) return;
      e.preventDefault();
      const cx = (mx - viewOx) / viewScale;
      const cy = (my - viewOy) / viewScale;
      const factor = Math.pow(1.0015, -e.deltaY);
      setTransform((t) => zoomAt(t, cx, cy, factor));
    };
    cv.addEventListener('wheel', onWheel, { passive: false });
    return () => cv.removeEventListener('wheel', onWheel);
  }, [dims, viewScale, viewOx, viewOy]);

  // Drag panning (window-level listeners keep it smooth outside the canvas).
  const onMouseDown = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      dragRef.current = { mx: e.clientX, my: e.clientY, x: transform.x, y: transform.y };
      setDragging(true);
    },
    [transform],
  );

  useEffect(() => {
    if (!dragging) return;
    const start = dragRef.current;
    if (!start) return;
    const onMove = (e: MouseEvent) => {
      const cv = previewRef.current;
      if (!cv) return;
      const rect = cv.getBoundingClientRect();
      const k = VIEW.w / rect.width;
      const dx = ((e.clientX - start.mx) * k) / viewScale;
      const dy = ((e.clientY - start.my) * k) / viewScale;
      setTransform((t) => ({ ...t, x: start.x + dx, y: start.y + dy }));
    };
    const onUp = () => setDragging(false);
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
  }, [dragging, viewScale]);

  const handleCrop = useCallback(async () => {
    if (!dims) return;
    const win = window as any;
    if (!win.electronAPI?.saveFile) return;
    const def = `${srcName || 'image'}_crop_${dims.w}x${dims.h}.${format}`;
    const path = await win.electronAPI.saveFile(def);
    if (!path) return;
    setBusy(true);
    setStatus({ kind: 'info', text: '裁剪中...' });
    try {
      const c = renderOutput();
      if (!c) throw new Error('画布无效');
      const blob = await encodeCanvas(c, format);
      if (!blob) throw new Error('图片编码失败');
      const bytes = new Uint8Array(await blob.arrayBuffer());
      const r = await writeFileBytes(path, bytes);
      if (!r?.ok) throw new Error(r?.error || '写入失败');
      setLastOut(path);
      setStatus({ kind: 'success', text: `已裁剪: ${path} (${(bytes.length / 1024).toFixed(1)}KB)` });
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [dims, srcName, format, renderOutput]);

  const openFolder = useCallback(() => {
    const win = window as any;
    if (win.electronAPI?.revealInFolder && lastOut) win.electronAPI.revealInFolder(lastOut);
  }, [lastOut]);

  const dimsValid = !!dims;
  const wValid = Number.isFinite(parseInt(wStr, 10)) && parseInt(wStr, 10) >= 1 && parseInt(wStr, 10) <= MAX_DIM;
  const hValid = Number.isFinite(parseInt(hStr, 10)) && parseInt(hStr, 10) >= 1 && parseInt(hStr, 10) <= MAX_DIM;

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>图片裁剪</h2>
          <div className="subtitle">
            自定义画布裁剪: 输入宽高建立画布, 拖拽/缩放摆放图片, 按当前画面输出新图
          </div>
        </div>
        {inputPath && (
          <button className="btn" onClick={handleReselect} disabled={busy}>重选</button>
        )}
      </div>

      {!inputPath && (
        <Dropzone accept={ACCEPT} onFile={handleInput} hint="支持 .png .jpg .bmp .gif(取首帧) .webp" />
      )}

      {inputPath && (
        <>
          <div className="file-info">
            <div className="row"><span className="label">输入:</span><span className="value">{inputPath}</span></div>
            <div className="row"><span className="label">原始尺寸:</span><span className="value">{origW} x {origH}</span></div>
          </div>

          <div className="crop-toolbar">
            <span className="fld">
              <label>宽度W:</label>
              <input
                type="number"
                min={1}
                max={MAX_DIM}
                value={wStr}
                onChange={(e) => setWStr(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && applyCanvas()}
              />
            </span>
            <span className="fld">
              <label>高度H:</label>
              <input
                type="number"
                min={1}
                max={MAX_DIM}
                value={hStr}
                onChange={(e) => setHStr(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && applyCanvas()}
              />
            </span>
            <span className="est-size" title="按当前画面与输出格式真实编码得到的大小">
              {dimsValid && estBytes != null ? `预计 ≈ ${(estBytes / 1024).toFixed(0)} KB` : '预计 ≈ --'}
            </span>
            <button className="btn small" onClick={applyCanvas} disabled={!wValid || !hValid || !bitmapRef.current}>
              调整
            </button>
            <button className="btn small" onClick={() => zoomCenter(1.25)} disabled={!dimsValid} title="放大">
              ⊕
            </button>
            <button className="btn small" onClick={() => zoomCenter(0.8)} disabled={!dimsValid} title="缩小">
              ⊖
            </button>
            <span className="zoom-label">{Math.round(transform.scale * 100)}%</span>
            <button className="btn small secondary" onClick={fitToCanvas} disabled={!dimsValid} title="图片居中并适应画布">
              适应
            </button>
            <button className="btn small crop-primary" onClick={handleCrop} disabled={busy || !dimsValid}>
              {busy ? '裁剪中...' : '开始裁剪'}
            </button>
          </div>

          <div className="options">
            <h3>输出设置</h3>
            <div className="form-row">
              <label>格式:</label>
              <select value={format} onChange={(e) => setFormat(e.target.value as OutFormat)}>
                <option value="png">PNG (支持透明)</option>
                <option value="jpg">JPG (体积小, 自动压平)</option>
                <option value="webp">WebP (支持透明, 体积更小)</option>
              </select>
              <span className="option-tip">导入时自动跟随原图格式, 可随时切换</span>
            </div>
            <div className="form-row">
              <label>透明背景 (PNG/WebP):</label>
              <input
                type="checkbox"
                checked={transparent}
                disabled={format === 'jpg'}
                onChange={(e) => setTransparent(e.target.checked)}
              />
              <span className="option-tip">
                勾选后画布未被图片覆盖的区域输出为透明; JPG 不支持透明, 会用背景色压平
              </span>
            </div>
            <div className="form-row">
              <label>背景色:</label>
              <input type="color" value={bgColor} onChange={(e) => setBgColor(e.target.value)} />
              <span className="option-tip">画布底色 (未被图片覆盖的区域)</span>
            </div>
          </div>

          <div className="crop-stage">
            <canvas
              ref={previewRef}
              className={dragging ? 'dragging' : ''}
              onMouseDown={onMouseDown}
            />
          </div>

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}

          {status?.kind === 'success' && (
            <div className="actions">
              <button className="btn secondary" onClick={openFolder}>打开文件夹</button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
