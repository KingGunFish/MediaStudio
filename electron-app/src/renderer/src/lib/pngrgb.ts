// src/renderer/src/lib/pngrgb.ts - Minimal PNG encoder that always emits
// 24-bit RGB (color type 2, no alpha channel).
//
// canvas.toBlob() always produces RGBA PNGs even when every pixel is opaque,
// and App Store Connect rejects store icons whose PNG carries an alpha
// channel (ITMS-90717). Icons meant to be opaque are therefore re-encoded
// here: pixels are already composited onto a background color, the alpha
// bytes are simply dropped. IDAT is compressed with CompressionStream
// ('deflate' = RFC 1950 zlib, exactly what PNG requires).

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const v = new DataView(out.buffer);
  v.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  v.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

async function zlibDeflate(raw: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([raw as unknown as BlobPart])
    .stream()
    .pipeThrough(new CompressionStream('deflate'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// rgba: width*height RGBA pixels (already flattened onto an opaque background).
export async function encodePngRgb(
  width: number,
  height: number,
  rgba: Uint8ClampedArray,
): Promise<Uint8Array> {
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
  const ihdr = new Uint8Array(13);
  const iv = new DataView(ihdr.buffer);
  iv.setUint32(0, width);
  iv.setUint32(4, height);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type 2 = truecolor RGB, no alpha
  const idat = await zlibDeflate(raw);
  const parts = [
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', new Uint8Array(0)),
  ];
  const total = 8 + parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(total);
  out.set(Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a), 0);
  let off = 8;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

// True when the PNG color type has no alpha channel (quick check for tests
// and debugging: reads the IHDR color-type byte).
export function pngHasAlpha(png: Uint8Array): boolean {
  // signature 8 + IHDR len 4 + 'IHDR' 4 -> width 4 + height 4 + depth 1 = 21
  return png[21] === 6; // 6 = RGBA, 2 = RGB
}
