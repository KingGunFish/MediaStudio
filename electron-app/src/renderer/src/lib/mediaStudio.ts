// src/renderer/src/lib/mediaStudio.ts - TypeScript wrapper around the IPC API
import type { MediaResult, InitResult, VideoToGifOptions, KeyingOptions } from '../types';

declare global {
  interface Window {
    electronAPI: {
      openFile: (filters?: string) => Promise<string>;
      saveFile: (defaultName?: string) => Promise<string>;
      revealInFolder: (path: string) => void;
      sdkInit: () => Promise<InitResult>;
      probeVideo: (input: string) => Promise<ProbeResult>;
      videoToGif: (input: string, output: string, options: VideoToGifOptions, progressId: string) => Promise<any>;
      keying: (input: string, output: string, options: KeyingOptions, progressId: string) => Promise<any>;
      onProgress: (pid: string, cb: (data: { value: number; message: string }) => void) => () => void;
      onDone: (pid: string, cb: (result: MediaResult) => void) => () => void;
      readFile: (path: string) => Promise<Uint8Array<ArrayBuffer> | null>;
      writeFile: (path: string, data: Uint8Array) => Promise<{ ok: boolean; error?: string }>;
    };
  }
}

function genId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

export interface ProbeResult {
  ok: boolean;
  error?: string;
  width?: number;
  height?: number;
  fps?: number;
  duration?: number;
  nbFrames?: number;
  codec?: string;
  fileSize?: number;
}

export async function probeVideo(input: string): Promise<ProbeResult> {
  if (!window.electronAPI) return { ok: false, error: 'electronAPI not available' };
  return window.electronAPI.probeVideo(input);
}

export async function init(): Promise<InitResult> {
  if (!window.electronAPI) {
    return { ok: false, error: 'electronAPI not exposed (preload missing?)' };
  }
  return window.electronAPI.sdkInit();
}

export async function videoToGif(
  input: string,
  output: string,
  options: VideoToGifOptions,
  onProgress: (progress: number, message: string) => void
): Promise<MediaResult> {
  if (!window.electronAPI) throw new Error('electronAPI not available');
  const pid = genId();
  const offProgress = window.electronAPI.onProgress(pid, (data) => {
    onProgress(data.value, data.message);
  });
  try {
    const result = await window.electronAPI.videoToGif(input, output, options, pid);
    // The IPC wrapper returns the full SdkResult ({ ok, result, error, final }).
    // A failed SDK run arrives as ok:false — surface it as a real error so the
    // UI shows "失败: <reason>" instead of a bogus "完成: ? 帧".
    if (!result) throw new Error('未收到 SDK 返回结果');
    if ((result as any).ok === false) {
      throw new Error((result as any).error || 'SDK 处理失败(未知原因)');
    }
    // The actual MediaResult lives in `.result`. Defensive either way.
    return (result && (result as any).result) ? (result as any).result : result;
  } finally {
    offProgress();
  }
}

export async function keying(
  input: string,
  output: string,
  options: KeyingOptions,
  onProgress: (progress: number, message: string) => void
): Promise<MediaResult> {
  if (!window.electronAPI) throw new Error('electronAPI not available');
  const pid = genId();
  const offProgress = window.electronAPI.onProgress(pid, (data) => {
    onProgress(data.value, data.message);
  });
  try {
    const result = await window.electronAPI.keying(input, output, options, pid);
    if (!result) throw new Error('未收到 SDK 返回结果');
    if ((result as any).ok === false) {
      throw new Error((result as any).error || 'SDK 处理失败(未知原因)');
    }
    return (result && (result as any).result) ? (result as any).result : result;
  } finally {
    offProgress();
  }
}

// Byte-level file IO for renderer-side conversions (image -> 1-bit BMP/array).
export async function readFileBytes(path: string): Promise<Uint8Array<ArrayBuffer> | null> {
  if (!window.electronAPI?.readFile) return null;
  return window.electronAPI.readFile(path);
}

export async function writeFileBytes(
  path: string,
  data: Uint8Array,
): Promise<{ ok: boolean; error?: string }> {
  if (!window.electronAPI?.writeFile) return { ok: false, error: 'electronAPI not available' };
  return window.electronAPI.writeFile(path, data);
}