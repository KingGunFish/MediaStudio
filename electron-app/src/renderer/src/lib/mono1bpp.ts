// src/renderer/src/lib/mono1bpp.ts - Image -> 1-bit black/white conversion.
// Pure functions (no DOM): binarize, bit packing, BMP writer and the
// Img2Lcd-style C-array / binary packers used by the e-paper page.

export type MonoMode = 'threshold' | 'dither';
export type ScanMode = 'horizontal' | 'vertical';

export interface MonoOptions {
  mode: MonoMode;
  /** 1..255, only used when mode === 'threshold' */
  threshold: number;
  /** swap black/white */
  invert: boolean;
  /** byte packing order for the C array / bin output */
  scan: ScanMode;
  /** prepend the 8-byte Img2Lcd-compatible header to C array / bin */
  withHeader: boolean;
}

// RGBA (non-premultiplied) -> one byte per pixel, 1 = white / 0 = black.
// Alpha is composited over white so transparent areas end up as blank paper.
export function binarize(
  width: number,
  height: number,
  rgba: Uint8ClampedArray,
  mode: MonoMode,
  threshold: number,
  invert: boolean,
): Uint8Array {
  const n = width * height;
  const lum = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const a = rgba[i * 4 + 3] / 255;
    const inv = 255 * (1 - a);
    const r = rgba[i * 4] * a + inv;
    const g = rgba[i * 4 + 1] * a + inv;
    const b = rgba[i * 4 + 2] * a + inv;
    lum[i] = 0.299 * r + 0.587 * g + 0.114 * b;
  }
  const out = new Uint8Array(n);
  if (mode === 'threshold') {
    for (let i = 0; i < n; i++) out[i] = lum[i] >= threshold ? 1 : 0;
  } else {
    floydSteinberg(lum, width, height, out);
  }
  if (invert) {
    for (let i = 0; i < n; i++) out[i] ^= 1;
  }
  return out;
}

// Serpentine Floyd-Steinberg error diffusion: alternates scan direction per
// row, which avoids the regular "worm" artifacts of the one-directional pass.
function floydSteinberg(lum: Float32Array, w: number, h: number, out: Uint8Array) {
  const buf = Float32Array.from(lum);
  for (let y = 0; y < h; y++) {
    const ltr = y % 2 === 0;
    const x0 = ltr ? 0 : w - 1;
    const xEnd = ltr ? w : -1;
    const dx = ltr ? 1 : -1;
    for (let x = x0; x !== xEnd; x += dx) {
      const i = y * w + x;
      const old = buf[i];
      out[i] = old >= 128 ? 1 : 0;
      const err = old - (out[i] ? 255 : 0);
      const below = y + 1 < h;
      if (ltr) {
        if (x + 1 < w) buf[i + 1] += (err * 7) / 16;
        if (below) {
          if (x > 0) buf[i + w - 1] += (err * 3) / 16;
          buf[i + w] += (err * 5) / 16;
          if (x + 1 < w) buf[i + w + 1] += err / 16;
        }
      } else {
        if (x > 0) buf[i - 1] += (err * 7) / 16;
        if (below) {
          if (x + 1 < w) buf[i + w + 1] += (err * 3) / 16;
          buf[i + w] += (err * 5) / 16;
          if (x > 0) buf[i + w - 1] += err / 16;
        }
      }
    }
  }
}

// Pack 0/1 pixels into bytes, MSB = first pixel. Horizontal: 8 pixels per
// byte, rows left->right. Vertical: 8 pixels per byte down each column,
// columns left->right. Trailing padding bits are set to 1 (white).
export function packBits(width: number, height: number, px: Uint8Array, scan: ScanMode): Uint8Array {
  if (scan === 'horizontal') {
    const rowBytes = (width + 7) >> 3;
    const out = new Uint8Array(rowBytes * height).fill(0xff);
    for (let y = 0; y < height; y++) {
      const rowOff = y * rowBytes;
      for (let x = 0; x < width; x++) {
        if (!px[y * width + x]) out[rowOff + (x >> 3)] &= ~(0x80 >> (x & 7));
      }
    }
    return out;
  }
  const colBytes = (height + 7) >> 3;
  const out = new Uint8Array(colBytes * width).fill(0xff);
  for (let x = 0; x < width; x++) {
    const colOff = x * colBytes;
    for (let y = 0; y < height; y++) {
      if (!px[y * width + x]) out[colOff + (y >> 3)] &= ~(0x80 >> (y & 7));
    }
  }
  return out;
}

// Standard 1-bit BMP: BITMAPFILEHEADER + BITMAPINFOHEADER + 2-color palette,
// bottom-up rows padded to 4 bytes, MSB = leftmost pixel, 1 = white.
export function buildBmp1bpp(width: number, height: number, px: Uint8Array): Uint8Array {
  const rowBytes = ((width + 31) >> 5) << 2;
  const pixSize = rowBytes * height;
  const offset = 14 + 40 + 8;
  const buf = new ArrayBuffer(offset + pixSize);
  const v = new DataView(buf);
  const u8 = new Uint8Array(buf);
  // BITMAPFILEHEADER
  v.setUint8(0, 0x42);
  v.setUint8(1, 0x4d); // 'BM'
  v.setUint32(2, buf.byteLength, true);
  v.setUint32(10, offset, true);
  // BITMAPINFOHEADER
  v.setUint32(14, 40, true);
  v.setInt32(18, width, true);
  v.setInt32(22, height, true); // positive height = bottom-up rows
  v.setUint16(26, 1, true); // planes
  v.setUint16(28, 1, true); // 1 bpp
  v.setUint32(30, 0, true); // BI_RGB
  v.setUint32(34, pixSize, true);
  v.setInt32(38, 2835, true); // 72 dpi
  v.setInt32(42, 2835, true);
  v.setUint32(46, 2, true); // colors used
  v.setUint32(50, 2, true); // colors important
  // palette: index 0 = black, index 1 = white (BGRX)
  u8[58] = 255;
  u8[59] = 255;
  u8[60] = 255;
  // pixel data
  for (let y = 0; y < height; y++) {
    const src = y * width;
    const dst = offset + (height - 1 - y) * rowBytes;
    for (let x = 0; x < width; x++) {
      if (px[src + x]) u8[dst + (x >> 3)] |= 0x80 >> (x & 7);
    }
  }
  return u8;
}

// 8-byte header, same layout as Img2Lcd's "包含图像头数据":
// [scanMode, bpp, width BE16, height BE16, xOffset, yOffset].
// scanMode: 0x00 horizontal, 0x01 vertical. bpp is always 0x01 here.
export function arrayHeader(width: number, height: number, scan: ScanMode): Uint8Array {
  return Uint8Array.of(
    scan === 'horizontal' ? 0x00 : 0x01,
    0x01,
    (width >> 8) & 0xff,
    width & 0xff,
    (height >> 8) & 0xff,
    height & 0xff,
    0,
    0,
  );
}

export interface ArrayOutput {
  /** complete .c file content (ASCII-safe comments for embedded toolchains) */
  cSource: string;
  /** bytes for the .bin output (header included when opts.withHeader) */
  bin: Uint8Array;
  /** total data bytes, header included */
  totalBytes: number;
}

export function buildArrayOutput(
  varName: string,
  sourceName: string,
  width: number,
  height: number,
  px: Uint8Array,
  opts: MonoOptions,
): ArrayOutput {
  const packed = packBits(width, height, px, opts.scan);
  const header = opts.withHeader ? arrayHeader(width, height, opts.scan) : new Uint8Array(0);
  const bin = new Uint8Array(header.length + packed.length);
  bin.set(header);
  bin.set(packed, header.length);

  const lines: string[] = [];
  lines.push('/* Generated by Media Studio - 1-bit bitmap for e-paper displays');
  lines.push(` * source : ${sourceName}`);
  lines.push(` * size   : ${width} x ${height}`);
  lines.push(` * scan   : ${opts.scan}, MSB first`);
  lines.push(' * bits   : 0 = black, 1 = white, row padding bits = 1');
  if (opts.withHeader) {
    lines.push(' * header : 8 bytes (scan mode, bpp, width BE16, height BE16, x, y)');
  }
  lines.push(` * bytes  : ${bin.length}`);
  lines.push(' */');
  lines.push(`const unsigned char ${varName}[${bin.length}] = {`);
  const hex: string[] = new Array(bin.length);
  for (let i = 0; i < bin.length; i++) hex[i] = '0x' + bin[i].toString(16).padStart(2, '0');
  for (let i = 0; i < hex.length; i += 16) {
    lines.push('  ' + hex.slice(i, i + 16).join(', ') + ',');
  }
  lines.push('};');
  return { cSource: lines.join('\n') + '\n', bin, totalBytes: bin.length };
}

// "photo 01.png" -> "gImage_photo_01" (valid C identifier)
export function cVarName(fileName: string): string {
  const base = fileName.replace(/\.[^.]+$/, '').replace(/[^A-Za-z0-9_]/g, '_');
  return 'gImage_' + base;
}
