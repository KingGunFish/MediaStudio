// src/renderer/src/components/ProgressBar.tsx
interface ProgressBarProps {
  progress: number;  // 0..1
  message?: string;
}

export function ProgressBar({ progress, message }: ProgressBarProps) {
  const pct = Math.max(0, Math.min(100, Math.round(progress * 100)));
  return (
    <div className="progress">
      <div className="progress-bar">
        <div className="progress-bar-fill" style={{ width: `${pct}%` }} />
      </div>
      <div className="progress-text">
        {pct}%{message ? ` - ${message}` : ''}
      </div>
    </div>
  );
}