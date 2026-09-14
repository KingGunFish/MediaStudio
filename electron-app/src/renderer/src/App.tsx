// src/renderer/src/App.tsx - Main app
import { useState, useEffect, useCallback, useRef } from 'react';
import { init, videoToGif, keying } from './lib/mediaStudio';
import type { KeyingOptions, VideoToGifOptions, InitResult } from './types';
import { ConverterPage } from './pages/Converter';
import { KeyingPage } from './pages/Keying';
import { MonoPage } from './pages/Mono';
import { IconsPage } from './pages/Icons';
import { SettingsPage } from './pages/Settings';

type Tab = 'converter' | 'keying' | 'mono' | 'icons' | 'settings';

export function App() {
  const [tab, setTab] = useState<Tab>('converter');
  const [initResult, setInitResult] = useState<InitResult | null>(null);

  useEffect(() => {
    init().then(setInitResult);
  }, []);

  return (
    <div className="app">
      <aside className="sidebar">
        <h1>🎬 Media Studio</h1>
        <div
          className={`nav-item ${tab === 'converter' ? 'active' : ''}`}
          onClick={() => setTab('converter')}
        >
          视频转GIF
        </div>
        <div
          className={`nav-item ${tab === 'keying' ? 'active' : ''}`}
          onClick={() => setTab('keying')}
        >
          GIF抠图
        </div>
        <div
          className={`nav-item ${tab === 'mono' ? 'active' : ''}`}
          onClick={() => setTab('mono')}
        >
          图片转黑白
        </div>
        <div
          className={`nav-item ${tab === 'icons' ? 'active' : ''}`}
          onClick={() => setTab('icons')}
        >
          应用图标生成
        </div>
        <div
          className={`nav-item ${tab === 'settings' ? 'active' : ''}`}
          onClick={() => setTab('settings')}
        >
          设置
        </div>
      </aside>
      <main className="main">
        {initResult && !initResult.ok && (
          <div className="page">
            <div className="status error">
              <strong>SDK 加载失败:</strong> {initResult.error}
            </div>
          </div>
        )}
        {initResult?.ok && tab === 'converter' && <ConverterPage />}
        {initResult?.ok && tab === 'keying' && <KeyingPage />}
        {initResult?.ok && tab === 'mono' && <MonoPage />}
        {initResult?.ok && tab === 'icons' && <IconsPage />}
        {initResult?.ok && tab === 'settings' && <SettingsPage />}
      </main>
    </div>
  );
}