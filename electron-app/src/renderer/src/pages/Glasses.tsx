// src/renderer/src/pages/Glasses.tsx - Eyeglasses removal (non-AI, research
// based): brush a mask over the frames, choose an inpainting engine, refine
// with the clone brush. Classical CV only - see lib/inpaint.ts.
import { useState, useEffect, useRef, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import { inpaintImage } from '../lib/inpaint';
import type { InpaintEngine } from '../lib/inpaint';
import { readFileBytes, writeFileBytes } from '../lib/mediaStudio';

interface Status {
  kind: 'success' | 'error' | 'info';
  text: string;
}

type Tool = 'brush' | 'erase' | 'pan';

const ACCEPT = 'image/png,image/jpeg,image/webp,image/bmp';
const VIEW = { w: 720, h: 460 };

function splitPath(p: string): { dir: string; nameNoExt: string } {
  const norm = p.replace(/\//g, '\\');
  const idx = norm.lastIndexOf('\\');
  const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
  const base = idx >= 0 ? norm.slice(idx + 1) : norm;
  const dot = base.lastIndexOf('.');
  const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
  return { dir, nameNoExt };
}

export function GlassesPage() {
  const [inputPath, setInputPath] = useState('');
  const [srcName, setSrcName] = useState('');
  const [origW, setOrigW] = useState(0);
  const [origH, setOrigH] = useState(0);

  const [tool, setTool] = useState<Tool>('brush');
  const [brushSize, setBrushSize] = useState(24);
  const [engine, setEngine] = useState<InpaintEngine>('fast');
  const [symmetry, setSymmetry] = useState(true);
  const [dilate, setDilate] = useState(2);
  const [feather, setFeather] = useState(2);
  const [format, setFormat] = useState<'png' | 'jpg'>('png');

  const [zoom, setZoom] = useState(1);
  const [panX, setPanX] = useState(0);
  const [panY, setPanY] = useState(0);
  const [showOriginal, setShowOriginal] = useState(false);

  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<Status | null>(null);

  const bitmapRef = useRef<ImageBitmap | null>(null);
  const workRef = useRef<HTMLCanvasElement | null>(null);
  const maskRef = useRef<HTMLCanvasElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const undoRef = useRef<ImageData[]>([]);
  const dragRef = useRef<{ mx: number; my: number; px: number; py: number } | null>(null);
  const paintRef = useRef<{ ix: number; iy: number } | null>(null);

  const fitScale = origW > 0 ? Math.min(VIEW.w / origW, VIEW.h / origH, 4) : 1;
  const total = fitScale * zoom;

  const draw = useCallback(() => {
    const cv = canvasRef.current;
    const bmp = bitmapRef.current;
    const work = workRef.current;
    const mask = maskRef.current;
    if (!cv || origW < 1) return;
    cv.width = VIEW.w;
    cv.height = VIEW.h;
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, VIEW.w, VIEW.h);
    ctx.fillStyle = '#141a22';
    ctx.fillRect(0, 0, VIEW.w, VIEW.h);
    const ox = (VIEW.w - origW * total) / 2 + panX;
    const oy = (VIEW.h - origH * total) / 2 + panY;
    ctx.imageSmoothingEnabled = total < 3;
    ctx.imageSmoothingQuality = 'high';
    if (showOriginal && bmp) {
      ctx.drawImage(bmp, ox, oy, origW * total, origH * total);
    } else if (work) {
      ctx.drawImage(work, ox, oy, origW * total, origH * total);
    }
    if (!showOriginal && mask) {
      ctx.save();
      ctx.globalAlpha = 0.45;
      ctx.drawImage(mask, ox, oy, origW * total, origH * total);
      ctx.restore();
    }
  }, [origW, origH, total, panX, panY, showOriginal]);

  useEffect(() => {
    draw();
  }, [draw]);

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
      const work = document.createElement('canvas');
      work.width = bmp.width;
      work.height = bmp.height;
      work.getContext('2d')!.drawImage(bmp, 0, 0);
      workRef.current = work;
      const mask = document.createElement('canvas');
      mask.width = bmp.width;
      mask.height = bmp.height;
      maskRef.current = mask;
      undoRef.current = [];
      setOrigW(bmp.width);
      setOrigH(bmp.height);
      setZoom(1);
      setPanX(0);
      setPanY(0);
      setTool('brush');
      const ext = p.split('.').pop()?.toLowerCase() || '';
      setFormat(ext === 'jpg' || ext === 'jpeg' ? 'jpg' : 'png');
      setStatus({ kind: 'info', text: `已加载 ${bmp.width} x ${bmp.height} — 用画笔涂抹眼镜区域(连同镜框和压痕), 然后点「开始修复」` });
    } catch {
      bitmapRef.current = null;
      workRef.current = null;
      maskRef.current = null;
      setStatus({ kind: 'error', text: '无法解码图片(内核不支持的格式,如 TIFF)' });
    }
  }, []);

  const handleReselect = useCallback(() => {
    setInputPath('');
    setSrcName('');
    bitmapRef.current = null;
    workRef.current = null;
    maskRef.current = null;
    undoRef.current = [];
    setOrigW(0);
    setOrigH(0);
    setStatus(null);
  }, []);

  const clearMask = useCallback(() => {
    const mask = maskRef.current;
    if (!mask) return;
    mask.getContext('2d')!.clearRect(0, 0, mask.width, mask.height);
    draw();
  }, [draw]);

  const pushUndo = useCallback(() => {
    const work = workRef.current;
    if (!work) return;
    const ctx = work.getContext('2d', { willReadFrequently: true })!;
    undoRef.current.push(ctx.getImageData(0, 0, work.width, work.height));
    if (undoRef.current.length > 12) undoRef.current.shift();
  }, []);

  const handleUndo = useCallback(() => {
    const work = workRef.current;
    const snap = undoRef.current.pop();
    if (!work || !snap) {
      setStatus({ kind: 'info', text: '没有可撤销的步骤' });
      return;
    }
    work.getContext('2d')!.putImageData(snap, 0, 0);
    draw();
  }, [draw]);

  // ---- pointer interaction ----
  const toImage = useCallback(
    (e: { clientX: number; clientY: number }): { ix: number; iy: number; inside: boolean } => {
      const cv = canvasRef.current!;
      const rect = cv.getBoundingClientRect();
      const k = VIEW.w / rect.width;
      const mx = (e.clientX - rect.left) * k;
      const my = (e.clientY - rect.top) * k;
      const ox = (VIEW.w - origW * total) / 2 + panX;
      const oy = (VIEW.h - origH * total) / 2 + panY;
      const ix = (mx - ox) / total;
      const iy = (my - oy) / total;
      const inside = mx >= ox && mx <= ox + origW * total && my >= oy && my <= oy + origH * total;
      return { ix, iy, inside };
    },
    [origW, origH, total, panX, panY],
  );

  const paintAt = useCallback(
    (ix: number, iy: number, px: number, py: number) => {
      const mask = maskRef.current;
      if (!mask) return;
      const ctx = mask.getContext('2d')!;
      const r = brushSize / 2;
      if (tool === 'erase') {
        ctx.save();
        ctx.globalCompositeOperation = 'destination-out';
        ctx.lineWidth = r * 2;
        ctx.strokeStyle = 'rgba(0,0,0,1)';
        ctx.beginPath();
        ctx.moveTo(px, py);
        ctx.lineTo(ix, iy);
        ctx.stroke();
        ctx.restore();
      } else {
        ctx.fillStyle = 'rgb(255,32,32)';
        const dist = Math.hypot(ix - px, iy - py);
        const steps = Math.max(1, Math.ceil(dist / (r / 2)));
        for (let s = 0; s <= steps; s++) {
          const t = steps === 0 ? 0 : s / steps;
          ctx.beginPath();
          ctx.arc(px + (ix - px) * t, py + (iy - py) * t, r, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      draw();
    },
    [brushSize, tool, draw],
  );

  const onPointerDown = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      const cur = toImage(e);
      if (tool === 'pan' || e.button === 1) {
        dragRef.current = { mx: e.clientX, my: e.clientY, px: panX, py: panY };
        e.currentTarget.setPointerCapture(e.pointerId);
        return;
      }
      if (!cur.inside) return;
      e.currentTarget.setPointerCapture(e.pointerId);
      paintRef.current = { ix: cur.ix, iy: cur.iy };
      paintAt(cur.ix, cur.iy, cur.ix, cur.iy);
    },
    [tool, panX, panY, toImage, paintAt],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent<HTMLCanvasElement>) => {
      if (dragRef.current) {
        const d = dragRef.current;
        setPanX(d.px + (e.clientX - d.mx));
        setPanY(d.py + (e.clientY - d.my));
        return;
      }
      if (!paintRef.current) return;
      const cur = toImage(e);
      const last = paintRef.current;
      paintAt(cur.ix, cur.iy, last.ix, last.iy);
      paintRef.current = { ix: cur.ix, iy: cur.iy };
    },
    [toImage, paintAt],
  );

  const onPointerUp = useCallback(() => {
    dragRef.current = null;
    paintRef.current = null;
  }, []);

  // Wheel zoom anchored at the cursor, only inside the image area; outside
  // it the wheel keeps scrolling the page (same rule as the crop page).
  useEffect(() => {
    const cv = canvasRef.current;
    if (!cv || origW < 1) return;
    const onWheel = (e: WheelEvent) => {
      const rect = cv.getBoundingClientRect();
      const k = VIEW.w / rect.width;
      const mx = (e.clientX - rect.left) * k;
      const my = (e.clientY - rect.top) * k;
      const t = fitScale * zoom;
      const ox = (VIEW.w - origW * t) / 2 + panX;
      const oy = (VIEW.h - origH * t) / 2 + panY;
      if (mx < ox || mx > ox + origW * t || my < oy || my > oy + origH * t) return;
      e.preventDefault();
      const ix = (mx - ox) / t;
      const iy = (my - oy) / t;
      const factor = Math.pow(1.0015, -e.deltaY);
      const nz = Math.min(12, Math.max(0.2, zoom * factor));
      const nt = fitScale * nz;
      setZoom(nz);
      setPanX(mx - ix * nt - (VIEW.w - origW * nt) / 2);
      setPanY(my - iy * nt - (VIEW.h - origH * nt) / 2);
    };
    cv.addEventListener('wheel', onWheel, { passive: false });
    return () => cv.removeEventListener('wheel', onWheel);
  }, [origW, origH, fitScale, zoom, panX, panY]);

  // ---- repair ----
  const handleRepair = useCallback(async () => {
    const work = workRef.current;
    const mask = maskRef.current;
    if (!work || !mask) return;
    const wctx = work.getContext('2d', { willReadFrequently: true })!;
    const mctx = mask.getContext('2d', { willReadFrequently: true })!;
    const img = wctx.getImageData(0, 0, work.width, work.height);
    const mimg = mctx.getImageData(0, 0, mask.width, mask.height);
    const n = work.width * work.height;
    const maskArr = new Uint8Array(n);
    let count = 0;
    for (let i = 0; i < n; i++) {
      if (mimg.data[i * 4 + 3] > 16) {
        maskArr[i] = 1;
        count++;
      }
    }
    if (!count) {
      setStatus({ kind: 'error', text: '请先用画笔涂抹要去除的眼镜区域' });
      return;
    }
    pushUndo();
    setBusy(true);
    setStatus({ kind: 'info', text: '修复中...' });
    await new Promise((r) => setTimeout(r, 30)); // let the UI paint the status
    try {
      inpaintImage(work.width, work.height, img.data, maskArr, {
        engine,
        symmetry,
        dilate,
        feather,
        seed: 1,
      });
      wctx.putImageData(img, 0, 0);
      mctx.clearRect(0, 0, mask.width, mask.height);
      draw();
      setStatus({ kind: 'success', text: '修复完成 — 不满意可撤销后换引擎/调大蒙版, 或用橡皮+修补笔刷微调后再修复一次' });
    } catch (e: any) {
      setStatus({ kind: 'error', text: `修复失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [engine, symmetry, dilate, feather, pushUndo, draw]);

  const handleSave = useCallback(async () => {
    const work = workRef.current;
    if (!work) return;
    const win = window as any;
    if (!win.electronAPI?.saveFile) return;
    const def = `${srcName || 'image'}_noglasses.${format}`;
    const path = await win.electronAPI.saveFile(def);
    if (!path) return;
    setBusy(true);
    try {
      const blob = await new Promise<Blob | null>((res) =>
        work.toBlob(res, format === 'png' ? 'image/png' : 'image/jpeg', 0.92),
      );
      if (!blob) throw new Error('图片编码失败');
      const bytes = new Uint8Array(await blob.arrayBuffer());
      const r = await writeFileBytes(path, bytes);
      if (!r?.ok) throw new Error(r?.error || '写入失败');
      setStatus({ kind: 'success', text: `已保存: ${path} (${(bytes.length / 1024).toFixed(1)}KB)` });
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [srcName, format]);

  const cursor = tool === 'pan' ? (dragRef.current ? 'grabbing' : 'grab') : 'crosshair';

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>图片去眼镜</h2>
          <div className="subtitle">
            半自动修复(非 AI): 涂抹眼镜区域 → 经典修复算法重建。细框效果最好; 墨镜会露出眼睛, 无法凭空重建
          </div>
        </div>
        {inputPath && (
          <button className="btn" onClick={handleReselect} disabled={busy}>重选</button>
        )}
      </div>

      {!inputPath && (
        <Dropzone accept={ACCEPT} onFile={handleInput} hint="支持 .png .jpg .webp .bmp, 建议正面或接近正面的人像" />
      )}

      {inputPath && (
        <>
          <div className="file-info">
            <div className="row"><span className="label">输入:</span><span className="value">{inputPath}</span></div>
            <div className="row"><span className="label">原始尺寸:</span><span className="value">{origW} x {origH}</span></div>
          </div>

          <div className="crop-toolbar">
            <button
              className={`btn small ${tool === 'brush' ? 'active' : ''}`}
              onClick={() => setTool('brush')}
              title="涂抹要去除的区域"
            >
              画笔
            </button>
            <button
              className={`btn small ${tool === 'erase' ? 'active' : ''}`}
              onClick={() => setTool('erase')}
              title="擦除蒙版(不修复)"
            >
              橡皮
            </button>
            <button
              className={`btn small ${tool === 'pan' ? 'active' : ''}`}
              onClick={() => setTool('pan')}
              title="移动/缩放画面"
            >
              移动
            </button>
            <span className="fld">
              <label>笔刷:</label>
              <input
                type="range"
                min={4}
                max={80}
                value={brushSize}
                onChange={(e) => setBrushSize(+e.target.value)}
                style={{ width: 110 }}
              />
              <span className="zoom-label">{brushSize}px</span>
            </span>
            <button className="btn small secondary" onClick={clearMask} disabled={busy}>清除蒙版</button>
            <button className="btn small secondary" onClick={handleUndo} disabled={busy}>撤销</button>
            <button
              className="btn small secondary"
              disabled={busy}
              onMouseDown={() => setShowOriginal(true)}
              onMouseUp={() => setShowOriginal(false)}
              onMouseLeave={() => setShowOriginal(false)}
              title="按住查看原图对比"
            >
              按住对比
            </button>
            <button className="btn small crop-primary" onClick={handleRepair} disabled={busy}>
              {busy ? '修复中...' : '开始修复'}
            </button>
          </div>

          <div className="options">
            <h3>
              修复引擎
              <span
                className="help-q"
                data-tip="快速: 扩散式修复(Telea 2004 思想), 细金属框近乎完美, 大区域会发糊。纹理: 块合成(Criminisi 2003 思想), 从周围复制皮肤纹理, 粗框更好, 速度慢一些。对称辅助: 用人脸另一侧镜像填补(仅正脸有效)。蒙版扩展: 把涂抹区域向外扩几个像素, 盖住镜框边缘和压痕。这些均为经典算法, 不含任何 AI。"
              >?</span>
            </h3>
            <div className="form-row">
              <label>引擎:</label>
              <select value={engine} onChange={(e) => setEngine(e.target.value as InpaintEngine)}>
                <option value="fast">快速修复 (细框/窄缝, 快)</option>
                <option value="texture">纹理修复 (粗框, 从周围合成皮肤纹理)</option>
              </select>
            </div>
            <div className="form-row">
              <label>对称辅助 (正脸):</label>
              <input type="checkbox" checked={symmetry} onChange={(e) => setSymmetry(e.target.checked)} />
              <span className="option-tip">用未遮挡的一侧镜像填补 — 正脸人像建议开启</span>
            </div>
            <div className="form-row">
              <label>蒙版扩展:</label>
              <input type="number" min={0} max={10} value={dilate} onChange={(e) => setDilate(+e.target.value)} />
              <label style={{ width: 'auto' }}>px</label>
              <span className="option-tip">把涂抹区域向外扩几像素, 盖住镜框边缘和压痕 (建议 2-4)</span>
            </div>
            <div className="form-row">
              <label>边缘羽化:</label>
              <input type="number" min={1} max={8} value={feather} onChange={(e) => setFeather(+e.target.value)} />
              <label style={{ width: 'auto' }}>px</label>
              <span className="option-tip">修复区与原图的过渡带宽度</span>
            </div>
            <div className="form-row">
              <label>保存格式:</label>
              <select value={format} onChange={(e) => setFormat(e.target.value as 'png' | 'jpg')}>
                <option value="png">PNG (无损)</option>
                <option value="jpg">JPG (体积小)</option>
              </select>
              <button className="btn small" onClick={handleSave} disabled={busy}>保存结果</button>
            </div>
          </div>

          <div className="crop-stage glasses-stage">
            <canvas
              ref={canvasRef}
              style={{ maxWidth: '100%', cursor, touchAction: 'none' }}
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerUp}
              onPointerCancel={onPointerUp}
            />
          </div>

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}
        </>
      )}
    </div>
  );
}
