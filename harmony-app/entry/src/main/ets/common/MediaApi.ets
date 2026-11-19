// common/MediaApi.ets - typed wrapper around the native media engine.
//
// The native module is the in-process replacement for the ffmpeg CLI that
// the Windows build spawns (sdk/src/ffmpeg/executor.cpp). The option objects
// use the same field names as the Windows renderer
// (electron-app/src/renderer/src/types.ts), so both platforms speak one
// contract.

import msverify from 'libmsverify.so';
import {
  MediaInfo,
  MediaResult,
  VideoToGifOptions,
  KeyingOptions,
  KeyingAlgorithm,
  VideoCropOptions,
  ProgressCallback
} from 'libmsverify.so';

export { MediaInfo, MediaResult, VideoToGifOptions, KeyingOptions, KeyingAlgorithm, VideoCropOptions };

/** Probes a media file. Runs on a worker thread, never blocks the UI. */
export function probeMedia(path: string): Promise<MediaInfo> {
  return msverify.probeMedia(path);
}

/** Video -> animated GIF. */
export function convertVideoToGif(inputPath: string, outputPath: string,
  options: VideoToGifOptions, onProgress?: ProgressCallback): Promise<MediaResult> {
  return msverify.convertVideoToGif(inputPath, outputPath, options, onProgress);
}

/** Animated GIF -> animated GIF with the background keyed out. */
export function convertGifKeying(inputPath: string, outputPath: string,
  options: KeyingOptions, onProgress?: ProgressCallback): Promise<MediaResult> {
  return msverify.convertGifKeying(inputPath, outputPath, options, onProgress);
}

/** Video -> fixed size canvas, honouring the pan/zoom transform. */
export function convertVideoCrop(inputPath: string, outputPath: string,
  options: VideoCropOptions, onProgress?: ProgressCallback): Promise<MediaResult> {
  return msverify.convertVideoCrop(inputPath, outputPath, options, onProgress);
}

// ---------------------------------------------------------------------------
// Formatting helpers shared by the pages.

export function formatDuration(seconds: number): string {
  if (!seconds || seconds <= 0) {
    return '?';
  }
  if (seconds < 60) {
    return seconds.toFixed(1) + ' 秒';
  }
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  return m + ' 分 ' + s + ' 秒';
}

export function formatSize(bytes: number): string {
  if (!bytes || bytes <= 0) {
    return '?';
  }
  const mb = bytes / 1024 / 1024;
  if (mb < 1) {
    return Math.round(bytes / 1024) + ' KB';
  }
  return mb.toFixed(2) + ' MB';
}

/** Human readable ratio of a size, e.g. 200x140 -> "5:7". */
export function dimsToRatioLabel(w: number, h: number): string {
  const iw = Math.round(w);
  const ih = Math.round(h);
  if (!iw || !ih) {
    return '-';
  }
  let a = Math.abs(iw);
  let b = Math.abs(ih);
  while (b) {
    const t = b;
    b = a % b;
    a = t;
  }
  const rw = iw / a;
  const rh = ih / a;
  if (Math.abs(rw) <= 100 && Math.abs(rh) <= 100) {
    return rw + ':' + rh;
  }
  const r = iw / ih;
  return r >= 1 ? r.toFixed(2) + ':1' : '1:' + (1 / r).toFixed(2);
}
