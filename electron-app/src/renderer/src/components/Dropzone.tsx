// src/renderer/src/components/Dropzone.tsx
import { useState, useCallback, useRef } from 'react';

interface DropzoneProps {
  accept: string;
  onFile: (path: string) => void;
  hint?: string;
}

export function Dropzone({ accept, onFile, hint }: DropzoneProps) {
  const [dragOver, setDragOver] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const handleSelect = useCallback(async () => {
    const path = await window.electronAPI.openFile(accept);
    if (path) onFile(path);
  }, [accept, onFile]);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      // @ts-ignore - file.path is Electron-specific
      const filePath = (file as any).path || file.name;
      onFile(filePath);
    }
  };

  return (
    <div
      className={`dropzone ${dragOver ? 'dragover' : ''}`}
      onClick={handleSelect}
      onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
      onDragLeave={() => setDragOver(false)}
      onDrop={async (e) => {
        e.preventDefault();
        setDragOver(false);
        // Try to get the file path from Electron's webUtils
        const file = e.dataTransfer.files?.[0];
        if (file) {
          // @ts-ignore - webUtils.getPathForFile is Electron's way
          if (window.electronAPI.revealInFolder) {
            // path will be set via input change for input elements
          }
          // Fallback to file name (works on some platforms)
          // @ts-ignore
          const filePath = (file as any).path || file.name;
          onFile(filePath);
        }
      }}
    >
      <div className="icon">📁</div>
      <div className="text">点击或拖拽文件到此处</div>
      <div className="hint">{hint || `支持 ${accept}`}</div>
      <input
        ref={inputRef}
        type="file"
        accept={accept}
        onChange={handleChange}
        style={{ display: 'none' }}
      />
    </div>
  );
}