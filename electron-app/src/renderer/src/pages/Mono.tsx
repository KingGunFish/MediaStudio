// src/renderer/src/pages/Mono.tsx - Image -> 1-bit black/white page.
// The 1-bit BMP is generated (and kept updated) automatically while options
// change; the "生成数组" button produces the Img2Lcd-style C array / bin.
import { useState, useEffect, useRef, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import {
  binarize,
  buildBmp1bpp,
  buildArrayOutput,
  cVarName,
} from '../lib/mono1bpp';
import type { MonoMode, ScanMode, MonoOptions } from '../lib/mono1bpp';
import { readFileBytes, writeFileBytes } from '../lib/mediaStudio';

interface Status {
  kind: 'success' | 'error' | 'info';
  text: string;
}

const ACCEPT = 'image/png,image/jpeg,image/bmp,image/gif,image/webp';

function splitPath(p: string): { dir: string; base: string; nameNoExt: string } {
  const norm = p.replace(/\//g, '\\');
  const idx = norm.lastIndexOf('\\');
  const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
  const base = idx >= 0 ? norm.slice(idx + 1) : norm;
  const dot = base.lastIndexOf('.');
  const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
  return { dir, base, nameNoExt };
}

// Empty string -> fallback (original size); garbage -> 0 (invalid, disables UI).
function clampDim(s: string, fallback: number): number {
  const t = s.trim();
  if (!t) return fallback;
  const v = parseInt(t, 10);
  if (!Number.isFinite(v) || v < 1) return 0;
  return Math.min(v, 10000);
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

export function MonoPage() {
  const [inputPath, setInputPath] = useState('');
  const [outputPath, setOutputPath] = useState('');
  const [srcName, setSrcName] = useState('');

  const [origW, setOrigW] = useState(0);
  const [origH, setOrigH] = useState(0);
  const [wStr, setWStr] = useState('');
  const [hStr, setHStr] = useState('');
  const [lockAspect, setLockAspect] = useState(true);

  const [mode, setMode] = useState<MonoMode>('dither');
  const [threshold, setThreshold] = useState(128);
  const [invert, setInvert] = useState(false);
  const [scan, setScan] = useState<ScanMode>('horizontal');
  const [withHeader, setWithHeader] = useState(false);
  const [wantBin, setWantBin] = useState(false);

  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<Status | null>(null);
  const [arrayView, setArrayView] = useState<{ path: string; text: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const bitmapRef = useRef<ImageBitmap | null>(null);
  const pxRef = useRef<{ px: Uint8Array; w: number; h: number } | null>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  const handleInput = useCallback(async (p: string) => {
    setInputPath(p);
    setStatus({ kind: 'info', text: '读取图片中...' });
    const { dir, base, nameNoExt } = splitPath(p);
    setSrcName(base);
    setOutputPath(dir + nameNoExt + '_mono.bmp');
    setArrayView(null);
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
      setStatus({ kind: 'info', text: `已加载: ${bmp.width} x ${bmp.height},BMP 正在生成...` });
    } catch {
      bitmapRef.current = null;
      pxRef.current = null;
      setStatus({ kind: 'error', text: '无法解码图片(内核不支持的格式,如 TIFF)' });
    }
  }, []);

  // Recompute binarization + preview whenever the source or an option changes.
  // The preview draws the same 1-bit data that gets exported, and the BMP file
  // is written automatically (debounced) so it always matches the preview.
  useEffect(() => {
    const bmp = bitmapRef.current;
    const tw = clampDim(wStr, origW);
    const th = clampDim(hStr, origH);
    if (!bmp || tw < 1 || th < 1) return;

    const off = document.createElement('canvas');
    off.width = tw;
    off.height = th;
    const ctx = off.getContext('2d', { willReadFrequently: true });
    if (!ctx) return;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, tw, th);
    ctx.drawImage(bmp, 0, 0, tw, th);
    const img = ctx.getImageData(0, 0, tw, th);
    const px = binarize(tw, th, img.data, mode, threshold, invert);
    pxRef.current = { px, w: tw, h: th };

    const cv = canvasRef.current;
    if (cv) {
      cv.width = tw;
      cv.height = th;
      const pctx = cv.getContext('2d');
      if (pctx) {
        const out = pctx.createImageData(tw, th);
        for (let i = 0; i < px.length; i++) {
          const v = px[i] ? 255 : 0;
          out.data[i * 4] = v;
          out.data[i * 4 + 1] = v;
          out.data[i * 4 + 2] = v;
          out.data[i * 4 + 3] = 255;
        }
        pctx.putImageData(out, 0, 0);
      }
    }

    // Auto-write the BMP (debounced: the threshold slider fires rapidly).
    const timer = setTimeout(() => {
      writeFileBytes(outputPath, buildBmp1bpp(tw, th, px)).then((r) => {
        if (r && !r.ok) setStatus({ kind: 'error', text: `BMP 写入失败: ${r.error}` });
      });
    }, 300);
    return () => clearTimeout(timer);
  }, [wStr, hStr, mode, threshold, invert, origW, origH, outputPath]);

  const setW = (v: string) => {
    setWStr(v);
    const bmp = bitmapRef.current;
    if (lockAspect && bmp) {
      const w = parseInt(v, 10);
      if (Number.isFinite(w) && w > 0) {
        setHStr(String(Math.max(1, Math.round((w * bmp.height) / bmp.width))));
      }
    }
  };

  const setH = (v: string) => {
    setHStr(v);
    const bmp = bitmapRef.current;
    if (lockAspect && bmp) {
      const h = parseInt(v, 10);
      if (Number.isFinite(h) && h > 0) {
        setWStr(String(Math.max(1, Math.round((h * bmp.width) / bmp.height))));
      }
    }
  };

  const chooseOutput = useCallback(async () => {
    const win = window as any;
    if (!win.electronAPI?.saveFile) return;
    const def = outputPath ? outputPath.split('\\').pop()! : 'output_mono.bmp';
    const path = await win.electronAPI.saveFile(def);
    if (path) {
      setOutputPath(path);
      setSrcName(splitPath(path).nameNoExt);
    }
  }, [outputPath]);

  const handleGenerate = useCallback(async () => {
    const cur = pxRef.current;
    if (!cur || !outputPath) return;
    setBusy(true);
    setStatus({ kind: 'info', text: '生成数组中...' });
    try {
      const { px, w, h } = cur;
      const { dir, nameNoExt } = splitPath(outputPath);
      const base = dir + nameNoExt;
      const opts: MonoOptions = { mode, threshold, invert, scan, withHeader };
      const cPath = base + '.c';
      const out = buildArrayOutput(cVarName(srcName || 'image'), srcName || 'image', w, h, px, opts);
      const written: string[] = [];
      const r = await writeFileBytes(cPath, new TextEncoder().encode(out.cSource));
      if (!r?.ok) throw new Error(`${cPath}: ${r?.error || '写入失败'}`);
      written.push(`C 数组: ${cPath}`);
      if (wantBin) {
        const binPath = base + '.bin';
        const rb = await writeFileBytes(binPath, out.bin);
        if (!rb?.ok) throw new Error(`${binPath}: ${rb?.error || '写入失败'}`);
        written.push(`BIN: ${binPath}`);
      }
      setArrayView({ path: cPath, text: out.cSource });
      setStatus({ kind: 'success', text: `已生成: ${written.join('  |  ')}` });
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [outputPath, mode, threshold, invert, scan, withHeader, wantBin, srcName]);

  const handleCopy = useCallback(async () => {
    if (!arrayView) return;
    const ok = await copyText(arrayView.text);
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } else {
      setStatus({ kind: 'error', text: '复制失败,请手动选中数组文本复制' });
    }
  }, [arrayView]);

  const openFolder = useCallback(() => {
    const win = window as any;
    if (win.electronAPI?.revealInFolder && outputPath) win.electronAPI.revealInFolder(outputPath);
  }, [outputPath]);

  const handleReselect = useCallback(() => {
    setInputPath('');
    setOutputPath('');
    setSrcName('');
    bitmapRef.current = null;
    pxRef.current = null;
    setStatus(null);
    setArrayView(null);
    setOrigW(0);
    setOrigH(0);
    setWStr('');
    setHStr('');
  }, []);

  const outW = clampDim(wStr, origW);
  const outH = clampDim(hStr, origH);
  const valid = outW >= 1 && outH >= 1;
  const bmpBytes = valid ? 62 + (((outW + 31) >> 5) << 2) * outH : 0;
  const arrBytes = valid
    ? (scan === 'horizontal'
        ? Math.ceil(outW / 8) * outH
        : Math.ceil(outH / 8) * outW) + (withHeader ? 8 : 0)
    : 0;

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>图片转黑白</h2>
          <div className="subtitle">
            图片转 1 位黑白 BMP(选图后自动生成),并可生成墨水屏可用的 C 数组 / BIN (Img2Lcd 风格)
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

          <div className="file-info">
            <div className="row"><span className="label">BMP 输出路径:</span><span className="value">{outputPath || '(未选择)'}</span></div>
            <div className="row">
              <span className="label">说明:</span>
              <span className="value">选图后自动生成 BMP,调整参数时自动覆盖更新;数组文件生成到同目录</span>
            </div>
            <div className="actions">
              <button className="btn secondary" onClick={chooseOutput} disabled={busy}>选择输出路径</button>
            </div>
          </div>

          <div className="options">
            <h3>输出尺寸</h3>
            <div className="form-row rgb-row">
              <label>宽:</label>
              <input type="number" min={1} value={wStr} onChange={(e) => setW(e.target.value)} />
              <label>高:</label>
              <input type="number" min={1} value={hStr} onChange={(e) => setH(e.target.value)} />
              <label>锁定比例:</label>
              <input
                type="checkbox"
                checked={lockAspect}
                onChange={(e) => setLockAspect(e.target.checked)}
              />
            </div>
          </div>

          <div className="options">
            <h3>
              二值化
              <span
                className="help-q"
                data-tip="把灰度/彩色像素变成纯黑或纯白。阈值: 亮度 ≥ 阈值判白,其余判黑,适合高对比线条图、文字;抖动: Floyd-Steinberg 误差扩散,用黑白点阵模拟灰度层次,适合照片。透明像素按白色处理。反色可把黑白互换。"
              >?</span>
            </h3>
            <div className="form-row">
              <label>方式:</label>
              <select value={mode} onChange={(e) => setMode(e.target.value as MonoMode)}>
                <option value="dither">抖动 (适合照片)</option>
                <option value="threshold">阈值 (适合线条图/文字)</option>
              </select>
            </div>
            {mode === 'threshold' && (
              <div className="form-row">
                <label>阈值 ({threshold}):</label>
                <input
                  type="range"
                  min={1}
                  max={255}
                  value={threshold}
                  onChange={(e) => setThreshold(+e.target.value)}
                />
              </div>
            )}
            <div className="form-row">
              <label>反色 (黑白互换):</label>
              <input type="checkbox" checked={invert} onChange={(e) => setInvert(e.target.checked)} />
            </div>
          </div>

          <div className="options">
            <h3>
              数组 / BIN 设置
              <span
                className="help-q"
                data-tip="水平扫描: 每字节 8 个横向像素,MSB=最左像素,逐行排列 —— 墨水屏全帧刷新缓冲的常见格式。垂直扫描: 每字节 8 个纵向像素(自上而下),逐列排列。位含义: 1=白(不吸墨), 0=黑;末尾不足 8 位补 1(白)。包含头数据: 数据前追加 8 字节 Img2Lcd 兼容头(扫描方式、位深、宽/高 各 16 位大端、X/Y 偏移)。"
              >?</span>
            </h3>
            <div className="form-row">
              <label>扫描方向:</label>
              <select value={scan} onChange={(e) => setScan(e.target.value as ScanMode)}>
                <option value="horizontal">水平扫描 (每字节 8 个横向像素)</option>
                <option value="vertical">垂直扫描 (每字节 8 个纵向像素)</option>
              </select>
            </div>
            <div className="form-row">
              <label>包含头数据 (Img2Lcd 兼容):</label>
              <input
                type="checkbox"
                checked={withHeader}
                onChange={(e) => setWithHeader(e.target.checked)}
              />
            </div>
            <div className="form-row">
              <label>同时生成 .bin (烧录 Flash 用):</label>
              <input type="checkbox" checked={wantBin} onChange={(e) => setWantBin(e.target.checked)} />
            </div>
          </div>

          <div className="actions">
            <button className="btn" onClick={handleGenerate} disabled={busy || !valid || !outputPath}>
              {busy ? '生成中...' : '生成数组'}
            </button>
            <button className="btn secondary" onClick={openFolder} disabled={!outputPath}>
              打开文件夹
            </button>
          </div>

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}

          {valid && (
            <>
              <div className="preview-path">
                <span className="label">BMP 文件:</span>
                <span className="value">{outputPath}</span>
                <span className="size">{(bmpBytes / 1024).toFixed(1)}KB</span>
              </div>
              <div className="preview attached">
                <canvas
                  ref={canvasRef}
                  style={{ maxWidth: '100%', maxHeight: 420, imageRendering: 'pixelated' }}
                />
              </div>
              <div className="array-hint">数组: {(arrBytes / 1024).toFixed(1)}KB ({outW} x {outH} ÷ 8 字节/行) —— 点击「生成数组」后可在此页预览并复制</div>
            </>
          )}

          {arrayView && (
            <div className="array-box">
              <div className="array-box-header">
                <span className="path" title={arrayView.path}>{arrayView.path}</span>
                <button className="copy-btn" onClick={handleCopy}>
                  {copied ? '已复制 ✓' : '复制'}
                </button>
              </div>
              <pre className="array-pre">{arrayView.text}</pre>
            </div>
          )}
        </>
      )}
    </div>
  );
}
