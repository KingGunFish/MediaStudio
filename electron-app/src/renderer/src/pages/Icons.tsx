// src/renderer/src/pages/Icons.tsx - Mobile app icon generator.
// One input image -> every store/launcher icon required by the selected
// platform (Android / iOS / HarmonyOS), written into per-platform folders.
import { useState, useEffect, useRef, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import { encodePngRgb } from '../lib/pngrgb';
import {
  buildPlan,
  planPngCount,
  PLAT_DIRS,
  PLAT_LABELS,
} from '../lib/appicons';
import type { Plat, IconJob } from '../lib/appicons';
import { readFileBytes, writeFileBytes } from '../lib/mediaStudio';

interface Status {
  kind: 'success' | 'error' | 'info';
  text: string;
}

interface GenResult {
  folder: string;
  lines: string[];
}

const ACCEPT = 'image/png,image/jpeg,image/webp,image/gif';

function splitPath(p: string): { dir: string; base: string; nameNoExt: string } {
  const norm = p.replace(/\//g, '\\');
  const idx = norm.lastIndexOf('\\');
  const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
  const base = idx >= 0 ? norm.slice(idx + 1) : norm;
  const dot = base.lastIndexOf('.');
  const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
  return { dir, base, nameNoExt };
}

function joinPath(a: string, b: string): string {
  return a.replace(/[\\/]+$/, '') + '\\' + b;
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch {
      return false;
    }
  }
}

function drawCoverInto(
  ctx: CanvasRenderingContext2D,
  src: CanvasImageSource,
  sw: number,
  sh: number,
  x: number,
  y: number,
  w: number,
  h: number,
) {
  const k = Math.max(w / sw, h / sh);
  const dw = sw * k;
  const dh = sh * k;
  ctx.drawImage(src, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh);
}

function drawSafeInto(
  ctx: CanvasRenderingContext2D,
  src: CanvasImageSource,
  sw: number,
  sh: number,
  x: number,
  y: number,
  w: number,
  h: number,
  frac: number,
) {
  const box = w * frac;
  const k = Math.min(box / sw, box / sh);
  const dw = sw * k;
  const dh = sh * k;
  ctx.drawImage(src, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh);
}

// Render one icon job. Big inputs are halved repeatedly before the final
// draw so tiny sizes (48px) stay clean.
function renderJob(bmp: ImageBitmap, job: IconJob, bgHex: string): HTMLCanvasElement {
  let cur: CanvasImageSource = bmp;
  let cw = bmp.width;
  let ch = bmp.height;
  while (cw > job.size * 2 && ch > job.size * 2) {
    const nw = Math.max(job.size, Math.floor(cw / 2));
    const nh = Math.max(job.size, Math.floor(ch / 2));
    const step = document.createElement('canvas');
    step.width = nw;
    step.height = nh;
    const sctx = step.getContext('2d');
    if (!sctx) break;
    sctx.imageSmoothingEnabled = true;
    sctx.imageSmoothingQuality = 'high';
    sctx.drawImage(cur, 0, 0, nw, nh);
    cur = step;
    cw = nw;
    ch = nh;
  }
  const out = document.createElement('canvas');
  out.width = job.size;
  out.height = job.size;
  const ctx = out.getContext('2d');
  if (!ctx) return out;
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  if (job.flatten) {
    ctx.fillStyle = bgHex;
    ctx.fillRect(0, 0, job.size, job.size);
  }
  if (job.fit === 'cover') {
    drawCoverInto(ctx, cur, cw, ch, 0, 0, job.size, job.size);
  } else {
    drawSafeInto(ctx, cur, cw, ch, 0, 0, job.size, job.size, job.safeScale ?? 1);
  }
  return out;
}

// Flatten jobs are re-encoded as 24-bit RGB PNGs (no alpha channel at all):
// canvas.toBlob() always emits RGBA and App Store Connect rejects alpha
// icons (ITMS-90717).
async function canvasBytes(cv: HTMLCanvasElement, flatten: boolean): Promise<Uint8Array> {
  if (flatten) {
    const ctx = cv.getContext('2d');
    if (!ctx) throw new Error('canvas 2d 不可用');
    const img = ctx.getImageData(0, 0, cv.width, cv.height);
    return encodePngRgb(cv.width, cv.height, img.data);
  }
  const blob = await new Promise<Blob | null>((res) => cv.toBlob(res, 'image/png'));
  if (!blob) throw new Error('PNG 编码失败');
  return new Uint8Array(await blob.arrayBuffer());
}

export function IconsPage() {
  const [inputPath, setInputPath] = useState('');
  const [outRoot, setOutRoot] = useState('');
  const [origW, setOrigW] = useState(0);
  const [origH, setOrigH] = useState(0);

  const [plat, setPlat] = useState<Plat>('android');
  const [androidBg, setAndroidBg] = useState('#ffffff');
  const [iosBg, setIosBg] = useState('#ffffff');
  const [harmonyBg, setHarmonyBg] = useState('#ffffff');

  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<Status | null>(null);
  const [result, setResult] = useState<GenResult | null>(null);
  const [copied, setCopied] = useState(false);

  const bitmapRef = useRef<ImageBitmap | null>(null);
  const previewRef = useRef<HTMLCanvasElement>(null);

  const handleInput = useCallback(async (p: string) => {
    setInputPath(p);
    setStatus({ kind: 'info', text: '读取图片中...' });
    const { dir, nameNoExt } = splitPath(p);
    setOutRoot(dir + nameNoExt + '_icons');
    setResult(null);
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
      setStatus({ kind: 'info', text: `已加载: ${bmp.width} x ${bmp.height},建议输入 1024x1024 或更大` });
    } catch {
      bitmapRef.current = null;
      setStatus({ kind: 'error', text: '无法解码图片(内核不支持的格式,如 TIFF)' });
    }
  }, []);

  // Live preview: iOS shows the flattened square look; Android / HarmonyOS
  // show a circular mask with the foreground scaled into the safe zone —
  // close to what launchers actually draw.
  useEffect(() => {
    const bmp = bitmapRef.current;
    const cv = previewRef.current;
    if (!bmp || !cv) return;
    const N = 128;
    cv.width = N;
    cv.height = N;
    const ctx = cv.getContext('2d');
    if (!ctx) return;
    ctx.clearRect(0, 0, N, N);
    const bg = plat === 'android' ? androidBg : plat === 'ios' ? iosBg : harmonyBg;
    if (plat === 'ios') {
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, N, N);
      drawCoverInto(ctx, bmp, bmp.width, bmp.height, 0, 0, N, N);
    } else {
      ctx.save();
      ctx.beginPath();
      ctx.arc(N / 2, N / 2, N * 0.46, 0, Math.PI * 2);
      ctx.clip();
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, N, N);
      drawSafeInto(ctx, bmp, bmp.width, bmp.height, 0, 0, N, N, 2 / 3);
      ctx.restore();
    }
  }, [plat, androidBg, iosBg, harmonyBg, origW, origH]);

  const handleGenerate = useCallback(async () => {
    const bmp = bitmapRef.current;
    if (!bmp || !outRoot) return;
    setBusy(true);
    setStatus({ kind: 'info', text: '生成图标中...' });
    try {
      const bgHex = plat === 'android' ? androidBg : plat === 'ios' ? iosBg : harmonyBg;
      const plan = buildPlan(plat, bgHex);
      const folder = joinPath(outRoot, PLAT_DIRS[plat]);
      const lines: string[] = [];
      for (const f of plan) {
        const path = joinPath(folder, f.rel);
        if (f.kind === 'text') {
          const r = await writeFileBytes(path, new TextEncoder().encode(f.text));
          if (!r?.ok) throw new Error(`${path}: ${r?.error || '写入失败'}`);
          lines.push(`[配置] ${f.rel}`);
        } else {
          const cv = renderJob(bmp, f.job, bgHex);
          const bytes = await canvasBytes(cv, f.job.flatten);
          const r = await writeFileBytes(path, bytes);
          if (!r?.ok) throw new Error(`${path}: ${r?.error || '写入失败'}`);
          lines.push(`[${(bytes.length / 1024).toFixed(1)}KB] ${f.rel} — ${f.job.note}`);
        }
      }
      setResult({ folder, lines });
      setStatus({ kind: 'success', text: `已生成 ${plan.length} 个文件到: ${folder}` });
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [plat, outRoot, androidBg, iosBg, harmonyBg]);

  const handleCopy = useCallback(async () => {
    if (!result) return;
    const ok = await copyText(result.folder);
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    }
  }, [result]);

  const handleReselect = useCallback(() => {
    setInputPath('');
    setOutRoot('');
    bitmapRef.current = null;
    setStatus(null);
    setResult(null);
    setOrigW(0);
    setOrigH(0);
  }, []);

  const plan = buildPlan(plat, plat === 'android' ? androidBg : plat === 'ios' ? iosBg : harmonyBg);
  const pngCount = planPngCount(plan);
  const textCount = plan.length - pngCount;
  const bgValue = plat === 'android' ? androidBg : plat === 'ios' ? iosBg : harmonyBg;
  const setBgValue = (v: string) => {
    if (plat === 'android') setAndroidBg(v);
    else if (plat === 'ios') setIosBg(v);
    else setHarmonyBg(v);
  };

  const previewCaption =
    plat === 'ios'
      ? '压平效果 (无透明, 系统自动加圆角)'
      : '圆形蒙版模拟 (主体在中央 2/3 安全区)';

  const bgTip =
    plat === 'ios'
      ? 'iOS 图标不允许透明 (审核 ITMS-90717), 所有尺寸都会按此颜色压平为不透明 RGB PNG'
      : plat === 'android'
        ? '自适应图标背景层颜色 (不透明纯色); 商店图标中需要压平的也使用此色'
        : '鸿蒙分层图标背景层颜色 (审核硬性要求: 背景层不允许透明)';

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>应用图标生成</h2>
          <div className="subtitle">
            一张图生成 Android / iOS / HarmonyOS 上架所需的全套图标, 按平台分文件夹输出
          </div>
        </div>
        {inputPath && (
          <button className="btn" onClick={handleReselect} disabled={busy}>重选</button>
        )}
      </div>

      {!inputPath && (
        <Dropzone accept={ACCEPT} onFile={handleInput} hint="支持 .png .jpg .webp .gif(取首帧), 建议 1024x1024 以上" />
      )}

      {inputPath && (
        <>
          <div className="file-info">
            <div className="row"><span className="label">输入:</span><span className="value">{inputPath}</span></div>
            <div className="row"><span className="label">原始尺寸:</span><span className="value">{origW} x {origH}</span></div>
            <div className="row"><span className="label">输出根目录:</span><span className="value">{outRoot}</span></div>
            <div className="actions">
              <label className="label" style={{ width: 'auto' }}>输出根目录:</label>
              <input
                type="text"
                value={outRoot}
                onChange={(e) => setOutRoot(e.target.value)}
                style={{ flex: 1 }}
              />
            </div>
          </div>

          <div className="plat-tabs">
            {(['android', 'ios', 'harmony'] as Plat[]).map((p) => (
              <div
                key={p}
                className={`plat-tab ${plat === p ? 'active' : ''}`}
                onClick={() => setPlat(p)}
              >
                {PLAT_LABELS[p]}
              </div>
            ))}
          </div>

          <div className="options">
            <h3>{PLAT_LABELS[plat]} 输出设置</h3>
            <div className="form-row">
              <label>{plat === 'ios' ? '压平背景色:' : '背景层颜色:'}</label>
              <input type="color" value={bgValue} onChange={(e) => setBgValue(e.target.value)} />
              <span className="option-tip">{bgTip}</span>
            </div>
            <div className="form-row">
              <label>说明:</label>
              <span className="option-tip">
                {plat === 'android' && '输出商店图标 (Google Play 512 / 华为市场 216) + mipmap 五密度传统图标与自适应前景/背景层 + 声明 XML'}
                {plat === 'ios' && '输出 13 个官方尺寸 + Contents.json, 整个文件夹改名 AppIcon.appiconset 放入 Assets.xcassets 即用'}
                {plat === 'harmony' && '输出分层图标前景/背景两张 1024 PNG (两张独立图片!) + layered_image.json + AGC 上架 216/1024'}
              </span>
            </div>
            <div className="form-row">
              <label>将生成:</label>
              <span className="option-tip">{pngCount} 个 PNG + {textCount} 个配置/说明文件</span>
            </div>
          </div>

          <div className="preview mini">
            <div style={{ textAlign: 'center' }}>
              <canvas ref={previewRef} style={{ width: 128, height: 128, imageRendering: 'auto' }} />
              <div className="mini-cap">{previewCaption}</div>
            </div>
          </div>

          <div className="actions">
            <button className="btn" onClick={handleGenerate} disabled={busy || !outRoot}>
              {busy ? '生成中...' : `生成 ${PLAT_LABELS[plat]} 图标`}
            </button>
          </div>

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}

          {result && (
            <div className="array-box">
              <div className="array-box-header">
                <span className="path" title={result.folder}>{result.folder}</span>
                <button className="copy-btn" onClick={handleCopy}>
                  {copied ? '已复制 ✓' : '复制路径'}
                </button>
              </div>
              <pre className="array-pre">{result.lines.join('\n')}</pre>
            </div>
          )}
        </>
      )}
    </div>
  );
}
