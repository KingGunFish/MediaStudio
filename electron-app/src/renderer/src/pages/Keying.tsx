// src/renderer/src/pages/Keying.tsx
import { useState, useCallback } from 'react';
import { Dropzone } from '../components/Dropzone';
import { ProgressBar } from '../components/ProgressBar';
import { keying } from '../lib/mediaStudio';
import type { KeyingOptions, KeyingAlgorithm } from '../types';

export function KeyingPage() {
  const [inputPath, setInputPath] = useState('');
  const [outputPath, setOutputPath] = useState('');
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState('');
  const [status, setStatus] = useState<{ kind: 'success' | 'error' | 'info'; text: string } | null>(null);
  const [preview, setPreview] = useState('');

  // True after a successful conversion: grey the start button + show 打开文件夹.
  const [done, setDone] = useState(false);
  const [bgColor, setBgColor] = useState('#3a4250');

  // Algorithm settings
  const [algorithm, setAlgorithm] = useState<KeyingAlgorithm>('rgbSplit');
  const [useChannelFallback, setUseChannelFallback] = useState(true);
  const [watermarkBR, setWatermarkBR] = useState(true);
  const [watermarkTL, setWatermarkTL] = useState(true);
  const [pingPong, setPingPong] = useState(true);

  // Background color (for distance algorithm)
  const [bgR, setBgR] = useState(231);
  const [bgG, setBgG] = useState(225);
  const [bgB, setBgB] = useState(223);

  // When an input is chosen, default the output to <inputDir>/<inputName>_keyed.gif
  // (same base name as the input, only the extension changes to avoid collisions).
  const handleInput = useCallback((p: string) => {
    setInputPath(p);
    const norm = p.replace(/\//g, '\\');
    const idx = norm.lastIndexOf('\\');
    const dir = idx >= 0 ? norm.slice(0, idx + 1) : '';
    const base = idx >= 0 ? norm.slice(idx + 1) : norm;
    const dot = base.lastIndexOf('.');
    const nameNoExt = dot > 0 ? base.slice(0, dot) : base;
    setOutputPath(dir + nameNoExt + '_keyed.gif');
  }, []);

  const handleKeying = useCallback(async () => {
    if (!inputPath || !outputPath) return;
    setBusy(true);
    setProgress(0);
    setDone(false);
    setStatus({ kind: 'info', text: '处理中...' });

    const opts: KeyingOptions = {
      algorithm,
      useChannelFallback,
      watermarkBottomRight: watermarkBR,
      watermarkTopLeft: watermarkTL,
      pingPong,
      bgR, bgG, bgB,
    };
    try {
      const result = await keying(inputPath, outputPath, opts, (p, m) => {
        setProgress(p);
        setMessage(m);
      });
      setProgress(1);
      setStatus({
        kind: 'success',
        text: `完成: ${result?.frameCount ?? '?'} 帧, ${result?.fileSize ? (result.fileSize / 1024 / 1024).toFixed(2) : '?'} MB`,
      });
      setDone(true);
      // Preview: composite over a colored background
      const url = `file:///${outputPath.replace(/\\/g, '/')}`;
      setPreview(url);
    } catch (e: any) {
      setStatus({ kind: 'error', text: `失败: ${e.message}` });
    } finally {
      setBusy(false);
    }
  }, [inputPath, outputPath, algorithm, useChannelFallback, watermarkBR, watermarkTL, pingPong, bgR, bgG, bgB]);

  const chooseOutput = useCallback(async () => {
    const win = window as any;
    if (win.electronAPI?.saveFile) {
      const def = outputPath
        ? outputPath.split('\\').pop()!
        : (inputPath ? inputPath.split('\\').pop()!.replace(/\.[^.]+$/, '') + '_keyed.gif' : 'output.gif');
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
  }, []);

  return (
    <div className="page">
      <div className="page-header">
        <div>
          <h2>GIF 抠图</h2>
          <div className="subtitle">把 GIF 背景变为透明,同时去除水印(豆包 AI 等)</div>
        </div>
        {inputPath && (
          <button className="btn" onClick={handleReselect} disabled={busy}>重选</button>
        )}
      </div>

      {!inputPath && <Dropzone accept="image/gif" onFile={handleInput} hint="支持 .gif 格式" />}

      {inputPath && (
        <>
          <div className="file-info">
            <div className="row"><span className="label">输入:</span><span className="value">{inputPath}</span></div>
          </div>
          <div className="file-info">
            <div className="row"><span className="label">输出:</span><span className="value">{outputPath || '(未选择)'}</span></div>
            <div className="actions">
              <button className="btn secondary" onClick={chooseOutput} disabled={busy}>选择输出路径</button>
            </div>
          </div>

          <div className="options">
            <h3>算法设置</h3>
            <div className="form-row">
              <label>算法:</label>
              <select value={algorithm} onChange={(e) => setAlgorithm(e.target.value as KeyingAlgorithm)}>
                <option value="rgbSplit">RGB + Mask 拆分 (推荐)</option>
                <option value="distance">颜色距离 + 通道兜底</option>
                <option value="brightness">亮度阈值 (深色背景)</option>
                <option value="white">白色像素 (浅色背景)</option>
                <option value="chroma">Chroma Key (纯色背景)</option>
              </select>
            </div>
            <div className="form-row">
              <label>通道阈值兜底:</label>
              <input type="checkbox" checked={useChannelFallback} onChange={(e) => setUseChannelFallback(e.target.checked)} />
            </div>
            <div className="form-row">
              <label>去水印(右下):</label>
              <input type="checkbox" checked={watermarkBR} onChange={(e) => setWatermarkBR(e.target.checked)} />
            </div>
            <div className="form-row">
              <label>去水印(左上):</label>
              <input type="checkbox" checked={watermarkTL} onChange={(e) => setWatermarkTL(e.target.checked)} />
            </div>
            <div className="form-row">
              <label>Ping-pong:</label>
              <input type="checkbox" checked={pingPong} onChange={(e) => setPingPong(e.target.checked)} />
            </div>
          </div>

          {(algorithm === 'distance' || algorithm === 'rgbSplit') && (
            <div className="options">
              <h3>
                背景色 (RGB)
                <span
                  className="help-q"
                  data-tip="抠图算法会参考这个背景色来判断哪些像素属于背景、需要变为透明。请填入原始 GIF 中背景区域的 RGB 颜色值(0-255):R=红、G=绿、B=蓝。可用系统取色工具从原图背景处取色后填到这里。"
                >?</span>
              </h3>
              <div className="form-row rgb-row">
                <label>R:</label>
                <input type="number" value={bgR} min={0} max={255} onChange={(e) => setBgR(+e.target.value)} />
                <label>G:</label>
                <input type="number" value={bgG} min={0} max={255} onChange={(e) => setBgG(+e.target.value)} />
                <label>B:</label>
                <input type="number" value={bgB} min={0} max={255} onChange={(e) => setBgB(+e.target.value)} />
              </div>
            </div>
          )}

          <div className="options">
            <h3>预览背景(仅显示用,不影响输出)</h3>
            <div className="form-row">
              <label>颜色:</label>
              <input type="color" value={bgColor} onChange={(e) => setBgColor(e.target.value)} />
            </div>
          </div>

          <div className="actions">
            <button className="btn" onClick={handleKeying} disabled={busy || !outputPath || done}>
              {busy ? '处理中...' : done ? '已完成' : '开始抠图'}
            </button>
            <button className="btn secondary" onClick={openFolder} disabled={!done}>
              打开文件夹
            </button>
          </div>

          {busy && <ProgressBar progress={progress} message={message} />}

          {status && <div className={`status ${status.kind}`}>{status.text}</div>}

          {preview && (
            <div className="preview" style={{ background: bgColor }}>
              <img src={preview} alt="GIF preview" />
            </div>
          )}
        </>
      )}
    </div>
  );
}