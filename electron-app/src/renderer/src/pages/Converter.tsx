// src/renderer/src/pages/Converter.tsx
import { useState, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import { ProgressBar } from '../components/ProgressBar';
import { videoToGif, probeVideo } from '../lib/mediaStudio';
import type { VideoToGifOptions } from '../types';

// Advisory thresholds — the SDK itself enforces NO hard duration/size limit,
// but extremely long / large videos produce huge GIFs and take a long time.
// We surface the real values and warn when they exceed these soft limits.
const MAX_DURATION_SEC = 180; // 3 minutes
const MAX_SIZE_MB = 200;

function fmtDuration(sec: number): string {
  if (!sec || sec <= 0) return '?';
  if (sec < 60) return `${sec.toFixed(1)} 秒`;
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  return `${m} 分 ${s} 秒`;
}

function fmtSize(bytes: number): string {
  if (!bytes || bytes <= 0) return '?';
  const mb = bytes / 1024 / 1024;
  if (mb < 1) return `${Math.round(bytes / 1024)} KB`;
  return `${mb.toFixed(1)} MB`;
}

export function ConverterPage() {
  const [inputPath, setInputPath] = useState('');
  const [outputPath, setOutputPath] = useState('');
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState('');
  const [status, setStatus] = useState<{ kind: 'success' | 'error' | 'info'; text: string } | null>(null);
  const [preview, setPreview] = useState('');

  // Options
  const [width, setWidth] = useState(480);
  const [height, setHeight] = useState(0);
  const [fps, setFps] = useState(12);
  const [pingPong, setPingPong] = useState(true);

  // Probe result (original geometry / duration / size)
  const [origW, setOrigW] = useState(0);
  const [origH, setOrigH] = useState(0);
  const [duration, setDuration] = useState(0);
  const [fileSize, setFileSize] = useState(0);
  const [aspectKnown, setAspectKnown] = useState(false);
  const [probeError, setProbeError] = useState('');

  // True after a successful conversion: grey the start button + show 打开文件夹.
  const [done, setDone] = useState(false);

  const clearDone = useCallback(() => setDone(false), []);

  // When an input is chosen, default the output to <inputDir>/<inputName>.gif
  // (same base name as the input, only the extension changes). This avoids
  // collisions / accidental overwrites when converting several files, while
  // the user can still override it via "选择输出路径".
  const handleInput = useCallback(async (p: string) => {
    setInputPath(p);
    setDone(false);
    setStatus(null);
    setPreview('');
    setProbeError('');
    const norm = p.replace(/\//g, '\\');
    const idx = norm.lastIndexOf('\\');
    const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
    const base = idx >= 0 ? norm.slice(idx + 1) : norm;
    const dot = base.lastIndexOf('.');
    const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
    setOutputPath(dir + nameNoExt + '.gif');

    // Probe the video to learn its real geometry / duration / size.
    try {
      const info = await probeVideo(p);
      if (!info.ok) {
        setProbeError(info.error || '无法探测视频信息');
        setAspectKnown(false);
        setWidth(480);
        setHeight(480);
        return;
      }
      setOrigW(info.width || 0);
      setOrigH(info.height || 0);
      setDuration(info.duration || 0);
      setFileSize(info.fileSize || 0);
      if (info.width && info.height) {
        setAspectKnown(true);
        // Default width to 480 (or the original width if it's smaller).
        const defW = Math.min(480, info.width);
        setWidth(defW);
        setHeight(Math.max(2, Math.round(defW * info.height / info.width)));
      } else {
        setAspectKnown(false);
        setWidth(480);
        setHeight(480);
      }
    } catch (e: any) {
      setProbeError(e?.message || '探测失败');
      setAspectKnown(false);
      setWidth(480);
      setHeight(480);
    }
  }, []);

  // Aspect-ratio locked editing: changing one box recomputes the other.
  const onWidthChange = useCallback((w: number) => {
    setWidth(w);
    setDone(false);
    if (aspectKnown && origW > 0 && origH > 0) {
      setHeight(Math.max(2, Math.round(w * origH / origW)));
    }
  }, [aspectKnown, origW, origH]);

  const onHeightChange = useCallback((h: number) => {
    setHeight(h);
    setDone(false);
    if (aspectKnown && origW > 0 && origH > 0) {
      setWidth(Math.max(2, Math.round(h * origW / origH)));
    }
  }, [aspectKnown, origW, origH]);

  const handleConvert = useCallback(async () => {
    if (!inputPath || !outputPath) return;
    setBusy(true);
    setProgress(0);
    setDone(false);
    setStatus({ kind: 'info', text: '处理中...' });

    const opts: VideoToGifOptions = {
      width,
      fps,
      pingPong,
    };
    try {
      const result = await videoToGif(inputPath, outputPath, opts, (p, m) => {
        setProgress(p);
        setMessage(m);
      });
      setProgress(1);
      // Sync the displayed geometry to what was actually produced.
      if (result?.outputWidth) setWidth(result.outputWidth);
      if (result?.outputHeight) setHeight(result.outputHeight);
      setStatus({
        kind: 'success',
        text: `完成: ${result?.frameCount ?? '?'} 帧, ${result?.outputWidth ?? '?'}x${result?.outputHeight ?? '?'}, ${result?.fileSize ? (result.fileSize / 1024 / 1024).toFixed(2) : '?'} MB`,
      });
      setDone(true);
      // Load preview
      const url = `file:///${outputPath.replace(/\\/g, '/')}`;
      setPreview(url);
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [inputPath, outputPath, width, fps, pingPong]);

  const chooseOutput = useCallback(async () => {
    const win = window as any;
    if (win.electronAPI?.saveFile) {
      // Default the save dialog to the current (input-based) output name.
      const def = outputPath
        ? outputPath.split('\\').pop()!
        : (inputPath ? inputPath.split('\\').pop()!.replace(/\.[^.]+$/, '') + '.gif' : 'output.gif');
      const path = await win.electronAPI.saveFile(def);
      if (path) setOutputPath(path);
    }
  }, [inputPath, outputPath]);

  const openFolder = useCallback(() => {
    const win = window as any;
    if (win.electronAPI?.revealInFolder && outputPath) {
      win.electronAPI.revealInFolder(outputPath);
    }
  }, [outputPath]);

  // "重选": clear the current selection so the user can pick a new file.
  const handleReselect = useCallback(() => {
    setInputPath('');
    setOutputPath('');
    setStatus(null);
    setPreview('');
    setDone(false);
    setProbeError('');
    setAspectKnown(false);
    setOrigW(0);
    setOrigH(0);
    setDuration(0);
    setFileSize(0);
  }, []);

  // Limit advisory (soft — does not block conversion).
  const tooLong = duration > MAX_DURATION_SEC;
  const tooLarge = fileSize > MAX_SIZE_MB * 1024 * 1024;

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>视频 → GIF</h2>
          <div className="subtitle">把视频转换为高质量 GIF,支持缩放、调整帧率、ping-pong 循环</div>
        </div>
        {inputPath && (
          <button className="btn" onClick={handleReselect} disabled={busy}>重选</button>
        )}
      </div>

      {!inputPath && <Dropzone accept="video/mp4,video/*" onFile={handleInput} hint="支持 MP4 / MOV / WebM 等" />}

      {inputPath && (
        <>
          <div className="file-info">
            <div className="row"><span className="label">输入:</span><span className="value">{inputPath}</span></div>
            <div className="video-meta">
              {aspectKnown
                ? `${origW} × ${origH}　·　时长 ${fmtDuration(duration)}　·　大小 ${fmtSize(fileSize)}`
                : (probeError ? `探测失败: ${probeError}` : '探测中...')}
            </div>
          </div>
          {(tooLong || tooLarge) && (
            <div className="status info">
              提示: 视频{tooLong ? `时长较长(${fmtDuration(duration)})` : ''}{tooLong && tooLarge ? '、' : ''}{tooLarge ? `体积较大(${fmtSize(fileSize)})` : ''}，
              生成的 GIF 可能很大且转换较慢，建议降低分辨率 / 帧率或裁剪片段。
            </div>
          )}
          <div className="file-info">
            <div className="row"><span className="label">输出:</span><span className="value">{outputPath || '(未选择)'}</span></div>
            <div className="actions">
              <button className="btn secondary" onClick={chooseOutput} disabled={busy}>选择输出路径</button>
            </div>
          </div>

          <div className="options">
            <h3>输出设置</h3>
            <div className="form-row">
              <label>宽度 (px):</label>
              <input type="number" value={width} onChange={(e) => onWidthChange(+e.target.value)} min={50} max={4096} />
            </div>
            <div className="form-row">
              <label>高度 (px):</label>
              <input type="number" value={height} onChange={(e) => onHeightChange(+e.target.value)} min={50} max={4096} disabled={!aspectKnown} />
            </div>
            <div className="form-row">
              <span className="hint">{aspectKnown ? '宽高已锁定比例，改其一另一自动跟随' : '无法探测视频尺寸，宽高独立设置'}</span>
            </div>
            <div className="form-row">
              <label>帧率 (fps):</label>
              <input type="number" value={fps} onChange={(e) => { setFps(+e.target.value); clearDone(); }} min={1} max={60} />
            </div>
            <div className="form-row">
              <label>Ping-pong 循环:</label>
              <input type="checkbox" checked={pingPong} onChange={(e) => { setPingPong(e.target.checked); clearDone(); }} />
            </div>
          </div>

          <div className="actions">
            <button className="btn" onClick={handleConvert} disabled={busy || !outputPath || done}>
              {busy ? '处理中...' : done ? '已完成' : '开始转换'}
            </button>
            <button className="btn secondary" onClick={openFolder} disabled={!done}>
              打开文件夹
            </button>
          </div>

          {busy && <ProgressBar progress={progress} message={message} />}

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}

          {preview && (
            <div className="preview">
              <img src={preview} alt="GIF preview" />
            </div>
          )}
        </>
      )}
    </div>
  );
}
