// src/renderer/src/pages/Settings.tsx
export function SettingsPage() {
  return (
    <div className="page">
      <h2>设置</h2>
      <div className="subtitle">关于 Media Studio</div>

      <div className="options">
        <h3>关于</h3>
        <p style={{ color: '#a0a8b0', fontSize: 13, lineHeight: 1.6 }}>
          Media Studio v1.0.0 — 把视频/GIF 转为透明背景 GIF。<br />
          基于 ffmpeg + 颜色/亮度边界识别算法。<br />
          <br />
          <strong>5 种抠图算法:</strong><br />
          · RGB + Mask 拆分(推荐,本工具创新)<br />
          · 颜色距离 + 通道阈值兜底<br />
          · 亮度阈值 / 白色像素 / Chroma Key
        </p>
      </div>
    </div>
  );
}
