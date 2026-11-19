// common/ImageIo.ets - image decoding, scaling and file output.
//
// The Windows build decodes images in the renderer with createImageBitmap()
// and reads the pixels back from a canvas. The HarmonyOS build uses the
// platform image framework (ImageKit) for decoding and keeps the pixel maths
// in ArkTS, so both platforms work on the same straight (non premultiplied)
// RGBA bytes.
//
// ImageKit rows are padded (stride >= width * 4) and may carry premultiplied
// alpha, so the buffer is normalised here once and every caller can assume
// a tight, straight-alpha RGBA layout.

import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

export interface RgbaImage {
  width: number;
  height: number;
  /** width * height * 4, non premultiplied RGBA */
  data: Uint8Array;
}

/** Reads a whole file into memory. */
export function readFileBytes(path: string): ArrayBuffer {
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const stat = fileIo.statSync(file.fd);
    const buffer = new ArrayBuffer(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fileIo.readSync(file.fd, buffer, {
        offset: offset,
        length: stat.size - offset
      });
      if (read <= 0) {
        break;
      }
      offset += read;
    }
    return buffer;
  } finally {
    fileIo.closeSync(file.fd);
  }
}

/** Writes bytes into the sandbox, replacing whatever was there. */
export function writeFileBytes(path: string, bytes: Uint8Array): boolean {
  try {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(file.fd);
    }
    return true;
  } catch (e) {
    return false;
  }
}

/** Writes a text file into the sandbox (UTF-8). */
export function writeTextFile(path: string, text: string): boolean {
  try {
    const file = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
    } finally {
      fileIo.closeSync(file.fd);
    }
    return true;
  } catch (e) {
    return false;
  }
}

/** Creates a directory (and its parents) in the sandbox. */
export function ensureDir(path: string): boolean {
  try {
    if (!fileIo.accessSync(path)) {
      fileIo.mkdirSync(path, true);
    }
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * Decodes an image file into straight RGBA pixels.
 *
 * When width / height are given the decoder scales the image to exactly that
 * size, which is how the icon generator produces every launcher size.
 */
export async function decodeImage(path: string, width: number = 0, height: number = 0): Promise<RgbaImage> {
  return decodeBytes(readFileBytes(path), width, height);
}

/**
 * Decodes an already loaded image buffer.
 *
 * The same buffer is decoded several times when the icon generator renders
 * every launcher size, so the file is read only once.
 *
 * Note: ImageKit scales to exactly the requested size, it does not keep the
 * aspect ratio. Callers that need a proportional fit have to compute the
 * target size themselves.
 */
export async function decodeBytes(buffer: ArrayBuffer, width: number = 0, height: number = 0): Promise<RgbaImage> {
  const source = image.createImageSource(buffer);
  const options: image.DecodingOptions = {
    desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: true
  };
  if (width > 0 && height > 0) {
    options.desiredSize = { width: width, height: height };
  }
  const pixelMap = await source.createPixelMap(options);
  const info = await pixelMap.getImageInfo();
  const size = pixelMap.getPixelBytesNumber();
  const raw = new ArrayBuffer(size);
  await pixelMap.readPixelsToBuffer(raw);
  pixelMap.release();

  const bytes = new Uint8Array(raw);
  const w = info.size.width;
  const h = info.size.height;
  const stride = info.stride > 0 ? info.stride : w * 4;
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const from = y * stride;
    out.set(bytes.subarray(from, from + w * 4), y * w * 4);
  }
  if (info.alphaType === image.AlphaType.PREMUL) {
    unpremultiply(out);
  }
  return { width: w, height: h, data: out };
}

/**
 * Reads the pixel size of an image without decoding its pixels.
 * Returns [width, height].
 */
export async function probeSize(buffer: ArrayBuffer): Promise<number[]> {
  const source = image.createImageSource(buffer);
  const info = await source.getImageInfo();
  return [info.size.width, info.size.height];
}

/** Turns premultiplied RGBA into straight RGBA. */
function unpremultiply(data: Uint8Array): void {
  for (let i = 0; i < data.length; i += 4) {
    const a = data[i + 3];
    if (a === 0 || a === 255) {
      continue;
    }
    data[i] = Math.min(255, Math.round(data[i] * 255 / a));
    data[i + 1] = Math.min(255, Math.round(data[i + 1] * 255 / a));
    data[i + 2] = Math.min(255, Math.round(data[i + 2] * 255 / a));
  }
}

/** Copies a rectangle out of an RGBA buffer. */
export function cropRgba(src: Uint8Array, srcW: number, x: number, y: number,
  w: number, h: number): Uint8Array {
  const out = new Uint8Array(w * h * 4);
  for (let row = 0; row < h; row++) {
    const from = ((y + row) * srcW + x) * 4;
    out.set(src.subarray(from, from + w * 4), row * w * 4);
  }
  return out;
}

/**
 * Puts a rectangle of `src` onto a new canvas of dstW x dstH.
 *
 * The canvas is first filled with the background colour (bgA = 0 leaves it
 * transparent), then the source rectangle is copied at (offsetX, offsetY).
 * This is what the icon generator needs for the "safe" fit, where the scaled
 * image sits in the middle of the square.
 */
export function composeRgba(dstW: number, dstH: number, src: Uint8Array, srcW: number,
  offsetX: number, offsetY: number, copyW: number, copyH: number,
  bgR: number, bgG: number, bgB: number, bgA: number): Uint8Array {
  const out = new Uint8Array(dstW * dstH * 4);
  for (let i = 0; i < out.length; i += 4) {
    out[i] = bgR;
    out[i + 1] = bgG;
    out[i + 2] = bgB;
    out[i + 3] = bgA;
  }
  // The copy rectangle may hang over the canvas edges (the crop page pans the
  // image partly out of view), so it is clipped instead of written blindly.
  for (let row = 0; row < copyH; row++) {
    const dstRow = offsetY + row;
    if (dstRow < 0 || dstRow >= dstH) {
      continue;
    }
    let srcCol = 0;
    let dstCol = offsetX;
    let count = copyW;
    if (dstCol < 0) {
      srcCol = -dstCol;
      count += dstCol;
      dstCol = 0;
    }
    if (dstCol + count > dstW) {
      count = dstW - dstCol;
    }
    if (count <= 0) {
      continue;
    }
    const from = (row * srcW + srcCol) * 4;
    const to = (dstRow * dstW + dstCol) * 4;
    out.set(src.subarray(from, from + count * 4), to);
  }
  return out;
}

/**
 * Composites straight RGBA pixels onto an opaque background.
 *
 * Store icons must not carry an alpha channel (App Store Connect rejects
 * them, ITMS-90717), so the pixels are flattened and the alpha dropped.
 */
export function flattenRgba(src: Uint8Array, bgR: number, bgG: number, bgB: number): Uint8Array {
  const out = new Uint8Array(src.length);
  for (let i = 0; i < src.length; i += 4) {
    const a = src[i + 3] / 255;
    out[i] = Math.round(src[i] * a + bgR * (1 - a));
    out[i + 1] = Math.round(src[i + 1] * a + bgG * (1 - a));
    out[i + 2] = Math.round(src[i + 2] * a + bgB * (1 - a));
    out[i + 3] = 255;
  }
  return out;
}

/** Parses '#rrggbb' into its three channels. */
export function parseHexColor(hex: string): number[] {
  let value = hex.trim();
  if (value.startsWith('#')) {
    value = value.substring(1);
  }
  if (value.length === 3) {
    value = value.charAt(0) + value.charAt(0) +
      value.charAt(1) + value.charAt(1) +
      value.charAt(2) + value.charAt(2);
  }
  const r = parseInt(value.substring(0, 2), 16);
  const g = parseInt(value.substring(2, 4), 16);
  const b = parseInt(value.substring(4, 6), 16);
  if (isNaN(r) || isNaN(g) || isNaN(b)) {
    return [255, 255, 255];
  }
  return [r, g, b];
}

/**
 * Draws the source image onto a new canvas with a free transform.
 *
 * `scale` is the canvas pixels per source pixel (1 = 100% zoom) and
 * (offsetX, offsetY) is the top-left corner of the image in canvas
 * coordinates. The resampling is bilinear on premultiplied pixels, which is
 * the same composition the browser canvas produces in the Windows build.
 *
 * The background is painted first; bgA = 0 leaves the canvas transparent.
 */
export function drawScaledRgba(dstW: number, dstH: number, src: Uint8Array, srcW: number,
  srcH: number, scale: number, offsetX: number, offsetY: number,
  bgR: number, bgG: number, bgB: number, bgA: number): Uint8Array {
  // Premultiply once so that the bilinear filter does not bleed the colour of
  // fully transparent pixels into the visible ones.
  const pre = new Uint8Array(srcW * srcH * 4);
  for (let i = 0; i < pre.length; i += 4) {
    const a = src[i + 3];
    pre[i] = Math.round(src[i] * a / 255);
    pre[i + 1] = Math.round(src[i + 1] * a / 255);
    pre[i + 2] = Math.round(src[i + 2] * a / 255);
    pre[i + 3] = a;
  }

  const out = new Uint8Array(dstW * dstH * 4);
  const inv = 1 / scale;
  for (let y = 0; y < dstH; y++) {
    const sy = (y + 0.5 - offsetY) * inv - 0.5;
    const y0 = Math.floor(sy);
    const fy = sy - y0;
    const y0c = y0 < 0 ? 0 : (y0 > srcH - 1 ? srcH - 1 : y0);
    const y1c = y0 + 1 < 0 ? 0 : (y0 + 1 > srcH - 1 ? srcH - 1 : y0 + 1);
    for (let x = 0; x < dstW; x++) {
      const sx = (x + 0.5 - offsetX) * inv - 0.5;
      const x0 = Math.floor(sx);
      const fx = sx - x0;
      const x0c = x0 < 0 ? 0 : (x0 > srcW - 1 ? srcW - 1 : x0);
      const x1c = x0 + 1 < 0 ? 0 : (x0 + 1 > srcW - 1 ? srcW - 1 : x0 + 1);

      const idx00 = (y0c * srcW + x0c) * 4;
      const idx10 = (y0c * srcW + x1c) * 4;
      const idx01 = (y1c * srcW + x0c) * 4;
      const idx11 = (y1c * srcW + x1c) * 4;

      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      const w00 = (1 - fx) * (1 - fy);
      const w10 = fx * (1 - fy);
      const w01 = (1 - fx) * fy;
      const w11 = fx * fy;
      r = pre[idx00] * w00 + pre[idx10] * w10 + pre[idx01] * w01 + pre[idx11] * w11;
      g = pre[idx00 + 1] * w00 + pre[idx10 + 1] * w10 + pre[idx01 + 1] * w01 + pre[idx11 + 1] * w11;
      b = pre[idx00 + 2] * w00 + pre[idx10 + 2] * w10 + pre[idx01 + 2] * w01 + pre[idx11 + 2] * w11;
      a = pre[idx00 + 3] * w00 + pre[idx10 + 3] * w10 + pre[idx01 + 3] * w01 + pre[idx11 + 3] * w11;

      const idx = (y * dstW + x) * 4;
      if (bgA === 0) {
        // Transparent canvas: keep the straight alpha of the image.
        if (a > 0) {
          out[idx] = Math.min(255, Math.round(r * 255 / a));
          out[idx + 1] = Math.min(255, Math.round(g * 255 / a));
          out[idx + 2] = Math.min(255, Math.round(b * 255 / a));
        }
        out[idx + 3] = Math.max(0, Math.min(255, Math.round(a)));
      } else {
        const inv2 = 1 - a / 255;
        out[idx] = Math.min(255, Math.round(r + bgR * inv2));
        out[idx + 1] = Math.min(255, Math.round(g + bgG * inv2));
        out[idx + 2] = Math.min(255, Math.round(b + bgB * inv2));
        out[idx + 3] = 255;
      }
    }
  }
  return out;
}

/**
 * Encodes RGBA pixels with the platform image packer.
 *
 * Used for the formats the own PNG encoder does not cover: image/jpeg and
 * image/webp. JPEG has no alpha channel, so the pixels have to be flattened
 * before they are handed over.
 */
export async function encodeWithImageKit(rgba: Uint8Array, width: number, height: number,
  format: string, quality: number): Promise<Uint8Array> {
  const buffer = rgba.buffer.slice(rgba.byteOffset, rgba.byteOffset + rgba.byteLength) as ArrayBuffer;
  const options: image.InitializationOptions = {
    size: { width: width, height: height },
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    alphaType: image.AlphaType.UNPREMUL,
    editable: false
  };
  const pixelMap = await image.createPixelMap(buffer, options);
  const packer = image.createImagePacker();
  try {
    const packed = await packer.packing(pixelMap, { format: format, quality: quality });
    return new Uint8Array(packed);
  } finally {
    pixelMap.release();
    packer.release();
  }
}
