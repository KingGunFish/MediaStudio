// src/renderer/src/types.ts - Shared type declarations
export interface InitResult {
  ok: boolean;
  version?: string;
  error?: string;
  path?: string;
}

export interface VideoToGifOptions {
  width?: number;
  height?: number;
  fps?: number;
  maxColors?: number;
  quality?: number;
  logLevel?: number;
  pingPong?: boolean;
  startSeconds?: number;
  endSeconds?: number;
}

export type KeyingAlgorithm =
  | 'brightness'
  | 'white'
  | 'chroma'
  | 'distance'
  | 'rgbSplit';

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
  logLevel?: number;
  pingPong?: boolean;
}

export interface MediaResult {
  code: number;
  message: string;
  frameCount: number;
  outputWidth: number;
  outputHeight: number;
  fileSize: number;
}

export interface MediaStudioApi {
  init: () => Promise<InitResult>;
  version: () => string;
  errorString: (code: number) => string;
  videoToGif: (
    input: string,
    output: string,
    options: VideoToGifOptions,
    onProgress: (progress: number, message: string) => void
  ) => Promise<MediaResult>;
  keying: (
    input: string,
    output: string,
    options: KeyingOptions,
    onProgress: (progress: number, message: string) => void
  ) => Promise<MediaResult>;
}

declare global {
  interface Window {
    mediaStudio: MediaStudioApi;
  }
}