// common/Png.ets - Minimal PNG encoder.
//
// Port of the Windows build's electron-app/src/renderer/src/lib/pngrgb.ts.
// The only difference is the deflate step: the browser build used
// CompressionStream('deflate'), the HarmonyOS build calls the native
// zlibDeflate primitive (harmony-app/entry/src/main/cpp/napi_init.cpp),
// which produces the very same RFC1950 zlib stream that PNG IDAT needs.
//
// Two colour types are supported:
//   2 = truecolor RGB  (no alpha) - required for store icons that must not
//                                    carry an alpha channel (ITMS-90717)
//   6 = truecolor RGBA - used wherever transparency has to survive

import msverify from 'libmsverify.so';

const CRC_TABLE: Uint32Array = ((): Uint32Array => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const v = new DataView(out.buffer);
  v.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) {
    out[4 + i] = type.charCodeAt(i);
  }
  out.set(data, 8);
  v.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) {
    total += p.length;
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function assemble(width: number, height: number, colorType: number, raw: Uint8Array): Uint8Array {
  const ihdr = new Uint8Array(13);
  const iv = new DataView(ihdr.buffer);
  iv.setUint32(0, width);
  iv.setUint32(4, height);
  ihdr[8] = 8; // bit depth
  ihdr[9] = colorType;
  const idat = new Uint8Array(msverify.zlibDeflate(raw.buffer as ArrayBuffer));
  const signature = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', new Uint8Array(0))
  ]);
}

/**
 * 24-bit RGB PNG (colour type 2, no alpha channel).
 *
 * The pixels must already be composited onto an opaque background; the alpha
 * bytes are simply dropped.
 */
export function encodePngRgb(width: number, height: number, rgba: Uint8Array): Uint8Array {
  const stride = 1 + width * 3; // filter byte 0 + RGB
  const raw = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    raw[y * stride] = 0;
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4;
      const d = y * stride + 1 + x * 3;
      raw[d] = rgba[s];
      raw[d + 1] = rgba[s + 1];
      raw[d + 2] = rgba[s + 2];
    }
  }
  return assemble(width, height, 2, raw);
}

/** 32-bit RGBA PNG (colour type 6), transparency preserved. */
export function encodePngRgba(width: number, height: number, rgba: Uint8Array): Uint8Array {
  const stride = 1 + width * 4; // filter byte 0 + RGBA
  const raw = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    raw[y * stride] = 0;
    for (let x = 0; x < width; x++) {
      const s = (y * width + x) * 4;
      const d = y * stride + 1 + x * 4;
      raw[d] = rgba[s];
      raw[d + 1] = rgba[s + 1];
      raw[d + 2] = rgba[s + 2];
      raw[d + 3] = rgba[s + 3];
    }
  }
  return assemble(width, height, 6, raw);
}

/**
 * True when the PNG carries an alpha channel.
 * Reads the IHDR colour type byte (signature 8 + IHDR len 4 + 'IHDR' 4 +
 * width 4 + height 4 + depth 1 = 21).
 */
export function pngHasAlpha(png: Uint8Array): boolean {
  return png[21] === 6; // 6 = RGBA, 2 = RGB
}
