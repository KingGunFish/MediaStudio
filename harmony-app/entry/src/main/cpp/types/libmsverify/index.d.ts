/**
 * Verification native module contract.
 *
 * Every entry here maps to one platform assumption that must hold before
 * porting Media Studio to HarmonyOS PC.
 */

/** NAPI bridge sanity check on a 2in1 device. */
export const ping: () => string;

/**
 * Compress a buffer into a zlib (RFC1950) stream.
 *
 * PNG IDAT requires zlib format; this is the primitive that replaces the
 * browser build's CompressionStream('deflate').
 */
export const zlibDeflate: (data: ArrayBuffer) => ArrayBuffer;

/** Reports the native zlib output format (header bytes, length, version). */
export const zlibProbe: () => string;

/**
 * Starts a native child process that loads this module's own .so.
 * Returns "rc=<code> pid=<pid>"; the child writes a marker file.
 */
export const childProcessProbe: (markerPath: string) => string;

/** musl / kernel / page size information from the device runtime. */
export const sysInfo: () => string;

/**
 * Parses the real keying filter_complex string and evaluates the real alpha
 * expression on synthetic frames.
 */
export const avfilterProbe: () => string;

/** Encodes a real animated GIF with the OHOS-built libavcodec/libavformat. */
export const gifEncodeProbe: (outputPath: string) => string;

/**
 * Runs the production C1 video -> GIF pipeline in-process on a real video
 * file and writes the result to `outputPath`.
 *
 * This is the end-to-end check: it exercises the same filter strings and the
 * same intermediate files as the Windows build.
 */
export const videoToGif: (inputPath: string, outputPath: string, keepIntermediates?: boolean) => string;

/**
 * Runs the production C2 keying pipeline (background keying of an animated
 * GIF) in-process on a real GIF file and writes the result to `outputPath`.
 *
 * The filter chain is the shared, unmodified mask_builder.cpp expression, so
 * the output has to match the Windows build pixel by pixel.
 */
export const gifKeying: (inputPath: string, outputPath: string) => string;

// ---------------------------------------------------------------------------
// Production API
//
// The option objects use the same field names as the Windows renderer
// (electron-app/src/renderer/src/types.ts), so both platforms speak one
// contract.
// ---------------------------------------------------------------------------

/** Geometry and metadata of a media file. */
export interface MediaInfo {
  ok: boolean;
  code: number;
  message: string;
  width: number;
  height: number;
  /** frames per second */
  fps: number;
  /** seconds */
  duration: number;
  nbFrames: number;
  fileSize: number;
  codec: string;
}

/** Outcome of a conversion. */
export interface MediaResult {
  ok: boolean;
  code: number;
  message: string;
  frameCount: number;
  outputWidth: number;
  outputHeight: number;
  fileSize: number;
  durationMs: number;
}

export interface VideoToGifOptions {
  width?: number;
  height?: number;
  fps?: number;
  maxColors?: number;
  quality?: number;
  pingPong?: boolean;
  startSeconds?: number;
  endSeconds?: number;
}

export type KeyingAlgorithm = 'brightness' | 'white' | 'chroma' | 'distance' | 'rgbSplit';

export interface KeyingOptions {
  algorithm?: KeyingAlgorithm;
  brightnessThreshold?: number;
  whiteThreshold?: number;
  distanceThreshold?: number;
  bgR?: number;
  bgG?: number;
  bgB?: number;
  channelThreshold?: number;
  useChannelFallback?: boolean;
  watermarkBottomRight?: boolean;
  watermarkTopLeft?: boolean;
  maxColors?: number;
  quality?: number;
  pingPong?: boolean;
}

export interface VideoCropOptions {
  outputWidth: number;
  outputHeight: number;
  /** source pixels per canvas pixel */
  scale: number;
  /** video top-left corner, in canvas coordinates */
  offsetX: number;
  offsetY: number;
  /** '#rrggbb' - fills the area the video does not cover */
  background: string;
  /** 0 (lossless) .. 51 (worst) */
  crf: number;
  keepAudio: boolean;
  sourceWidth?: number;
  sourceHeight?: number;
}

/** Progress callback: 0..1 and a short message. */
export type ProgressCallback = (value: number, message: string) => void;

/** Probes a media file. Runs off the UI thread. */
export const probeMedia: (path: string) => Promise<MediaInfo>;

/** Video -> animated GIF. */
export const convertVideoToGif: (inputPath: string, outputPath: string,
  options?: VideoToGifOptions, onProgress?: ProgressCallback) => Promise<MediaResult>;

/** Animated GIF -> animated GIF with the background keyed out. */
export const convertGifKeying: (inputPath: string, outputPath: string,
  options?: KeyingOptions, onProgress?: ProgressCallback) => Promise<MediaResult>;

/** Video -> fixed size canvas, honouring the pan/zoom transform. */
export const convertVideoCrop: (inputPath: string, outputPath: string,
  options: VideoCropOptions, onProgress?: ProgressCallback) => Promise<MediaResult>;

/** The first frame of a video, decoded and written as a PNG. */
export interface FrameInfo {
  ok: boolean;
  code: number;
  message: string;
  width: number;
  height: number;
  path: string;
}

export const decodeFirstFrame: (inputPath: string, outputPath: string) => FrameInfo;
