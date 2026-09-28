// src/renderer/src/lib/inpaint.ts - Classical (non-AI) image inpainting.
// Research basis: Telea 2004 (distance-weighted diffusion), Criminisi 2003 /
// PatchMatch (onion-peel exemplar synthesis), horizontal-symmetry prior for
// frontal faces. Pure functions over RGBA buffers, unit-testable in node.

export type InpaintEngine = 'fast' | 'texture';

export interface InpaintOptions {
  /** 'fast' = diffusion (thin masks), 'texture' = exemplar synthesis (wide masks) */
  engine?: InpaintEngine;
  /** mirror the un-occluded side onto the mask (frontal faces) */
  symmetry?: boolean;
  /** grow the mask by N px to cover frame edges/shadows (default 2) */
  dilate?: number;
  /** blend radius between repair and original at the seam (default 2) */
  feather?: number;
  /** RNG seed for the exemplar search (deterministic output) */
  seed?: number;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Chamfer distance from every pixel to the nearest seed pixel (seed=1).
// Two-pass 3-4 chamfer; good enough for weighting and onion peeling.
export function chamfer(seed: Uint8Array, w: number, h: number): Float32Array {
  const INF = 1e9;
  const d = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) d[i] = seed[i] ? 0 : INF;
  const D = 1.41421356;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (d[i] === 0) continue;
      let m = d[i];
      if (x > 0 && d[i - 1] + 1 < m) m = d[i - 1] + 1;
      if (y > 0 && d[i - w] + 1 < m) m = d[i - w] + 1;
      if (x > 0 && y > 0 && d[i - w - 1] + D < m) m = d[i - w - 1] + D;
      if (x < w - 1 && y > 0 && d[i - w + 1] + D < m) m = d[i - w + 1] + D;
      d[i] = m;
    }
  }
  for (let y = h - 1; y >= 0; y--) {
    for (let x = w - 1; x >= 0; x--) {
      const i = y * w + x;
      if (d[i] === 0) continue;
      let m = d[i];
      if (x < w - 1 && d[i + 1] + 1 < m) m = d[i + 1] + 1;
      if (y < h - 1 && d[i + w] + 1 < m) m = d[i + w] + 1;
      if (x < w - 1 && y < h - 1 && d[i + w + 1] + D < m) m = d[i + w + 1] + D;
      if (x > 0 && y < h - 1 && d[i + w - 1] + D < m) m = d[i + w - 1] + D;
      d[i] = m;
    }
  }
  return d;
}

// Grow the mask by ~r px (max-filter via distance field), so frame edges
// and compression halos are covered. r+0.5 counts diagonals, so r=1 yields
// a 3x3 block around each masked pixel.
export function expandMask(mask: Uint8Array, w: number, h: number, r: number): Uint8Array {
  if (r <= 0) return Uint8Array.from(mask);
  const d = chamfer(mask, w, h);
  const out = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) out[i] = d[i] <= r + 0.5 ? 1 : 0;
  return out;
}

// Simplified Telea: process masked pixels in ascending distance-to-known
// order; each pixel becomes the inverse-distance weighted average of its
// known neighbors within `radius`. Near-optimal for thin masks (frames).
export function fillThin(
  w: number,
  h: number,
  rgba: Uint8ClampedArray,
  mask: Uint8Array,
  radius = 6,
): void {
  const knownFlag = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) knownFlag[i] = mask[i] ? 0 : 1;
  const dist = chamfer(knownFlag, w, h); // distance from masked px to nearest known
  const order: number[] = [];
  for (let i = 0; i < w * h; i++) if (mask[i]) order.push(i);
  order.sort((a, b) => dist[a] - dist[b]);

  for (const i of order) {
    const x = i % w;
    const y = (i / w) | 0;
    let sr = 0;
    let sg = 0;
    let sb = 0;
    let sw = 0;
    const x0 = Math.max(0, x - radius);
    const x1 = Math.min(w - 1, x + radius);
    const y0 = Math.max(0, y - radius);
    const y1 = Math.min(h - 1, y + radius);
    for (let ny = y0; ny <= y1; ny++) {
      for (let nx = x0; nx <= x1; nx++) {
        const j = ny * w + nx;
        if (!knownFlag[j]) continue;
        const dx = nx - x;
        const dy = ny - y;
        const wgt = 1 / (dx * dx + dy * dy + 0.5);
        const p = j * 4;
        sr += rgba[p] * wgt;
        sg += rgba[p + 1] * wgt;
        sb += rgba[p + 2] * wgt;
        sw += wgt;
      }
    }
    if (sw > 0) {
      const p = i * 4;
      rgba[p] = sr / sw;
      rgba[p + 1] = sg / sw;
      rgba[p + 2] = sb / sw;
    }
    knownFlag[i] = 1;
  }
}

// Onion-peel exemplar synthesis (simplified Criminisi/PatchMatch): the mask
// boundary is repeatedly matched against fully-known patches and the best
// source patch fills the still-unknown pixels. `rgba` must already contain
// a coarse fill (run fillThin first) so matching sees plausible colors.
export function fillExemplar(
  w: number,
  h: number,
  rgba: Uint8ClampedArray,
  mask: Uint8Array,
  half = 4,
  seed = 1,
): void {
  const unknown = Uint8Array.from(mask);
  let remaining = 0;
  for (let i = 0; i < w * h; i++) if (unknown[i]) remaining++;
  if (!remaining) return;
  const rnd = mulberry32(seed);
  const size = half * 2 + 1;
  const maxCandidates = 500;

  let guard = 0;
  while (remaining > 0 && guard++ < 400) {
    // boundary = unknown pixels with at least one known 4-neighbor
    const boundary: number[] = [];
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const i = y * w + x;
        if (!unknown[i]) continue;
        if (
          (x > 0 && !unknown[i - 1]) ||
          (x < w - 1 && !unknown[i + 1]) ||
          (y > 0 && !unknown[i - w]) ||
          (y < h - 1 && !unknown[i + w])
        ) {
          boundary.push(i);
        }
      }
    }
    if (!boundary.length) break;

    // highest-confidence first: most known neighbors inside the patch
    const conf = (i: number) => {
      const x = i % w;
      const y = (i / w) | 0;
      let k = 0;
      for (let dy = -half; dy <= half; dy++) {
        const ny = y + dy;
        if (ny < 0 || ny >= h) continue;
        for (let dx = -half; dx <= half; dx++) {
          const nx = x + dx;
          if (nx < 0 || nx >= w) continue;
          if (!unknown[ny * w + nx]) k++;
        }
      }
      return k;
    };
    boundary.sort((a, b) => conf(b) - conf(a));
    if (boundary.length > 64) boundary.length = 64; // top slices per pass

    for (const bi of boundary) {
      if (remaining <= 0) break;
      const bx = bi % w;
      const by = (bi / w) | 0;

      // candidate centers with fully-known patches (grid + random), early exit
      let bestScore = Infinity;
      let bestQ = -1;
      const tryQ = (qx: number, qy: number): boolean => {
        const px0 = qx - half;
        const py0 = qy - half;
        if (px0 < 0 || py0 < 0 || px0 + size > w || py0 + size > h) return false;
        for (let dy = 0; dy < size; dy++) {
          for (let dx = 0; dx < size; dx++) {
            if (unknown[(py0 + dy) * w + px0 + dx]) return false;
          }
        }
        let score = 0;
        for (let dy = 0; dy < size && score < bestScore; dy++) {
          for (let dx = 0; dx < size; dx++) {
            const ui = (by - half + dy) * w + bx - half + dx;
            if (ui < 0 || ui >= w * h || unknown[ui]) continue;
            const a = ui * 4;
            const bq = ((qy - half + dy) * w + qx - half + dx) * 4;
            const dr = rgba[a] - rgba[bq];
            const dg = rgba[a + 1] - rgba[bq + 1];
            const db = rgba[a + 2] - rgba[bq + 2];
            score += dr * dr + dg * dg + db * db;
            if (score >= bestScore) return false;
          }
        }
        if (score < bestScore) {
          bestScore = score;
          bestQ = qy * w + qx;
          return bestScore === 0;
        }
        return false;
      };

      const stride = 4;
      let sampled = 0;
      for (let qy = half; qy < h - half && sampled < maxCandidates; qy += stride) {
        for (let qx = half; qx < w - half && sampled < maxCandidates; qx += stride) {
          sampled++;
          if (tryQ(qx, qy)) break;
        }
      }
      for (let s = 0; s < 200 && sampled < maxCandidates * 2; s++) {
        sampled++;
        const qx = half + Math.floor(rnd() * (w - size));
        const qy = half + Math.floor(rnd() * (h - size));
        if (tryQ(qx, qy)) break;
      }
      if (bestQ < 0) continue;

      const qx = bestQ % w;
      const qy = (bestQ / w) | 0;
      for (let dy = -half; dy <= half; dy++) {
        for (let dx = -half; dx <= half; dx++) {
          const ux = bx + dx;
          const uy = by + dy;
          if (ux < 0 || uy < 0 || ux >= w || uy >= h) continue;
          const ui = uy * w + ux;
          if (!unknown[ui]) continue;
          const q = (qy + dy) * w + (qx + dx);
          const a = ui * 4;
          const b = q * 4;
          rgba[a] = rgba[b];
          rgba[a + 1] = rgba[b + 1];
          rgba[a + 2] = rgba[b + 2];
          unknown[ui] = 0;
          remaining--;
        }
      }
    }
  }
}

// Frontal-face prior: fill masked pixels from the horizontal mirror point
// (around axisX, default image center) when the mirror pixel is unmasked.
// Returns the number of pixels filled.
export function symmetryFill(
  w: number,
  h: number,
  rgba: Uint8ClampedArray,
  mask: Uint8Array,
  axisX?: number,
): number {
  const ax = axisX ?? w / 2;
  const snap = Uint8ClampedArray.from(rgba);
  let changed = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      if (!mask[i]) continue;
      const mx = Math.round(2 * ax - x);
      if (mx < 0 || mx >= w) continue;
      const j = y * w + mx;
      if (mask[j]) continue; // mirror side is masked too -> keep engine result
      const a = i * 4;
      const b = j * 4;
      rgba[a] = snap[b];
      rgba[a + 1] = snap[b + 1];
      rgba[a + 2] = snap[b + 2];
      changed++;
    }
  }
  return changed;
}

// Feathered compositing: the repair is blended in at full strength in the
// mask interior and ramps to zero across the outer `feather` px ring of the
// mask, so the seam disappears without diluting the fill itself.
export function featherBlend(
  w: number,
  h: number,
  original: Uint8ClampedArray,
  repaired: Uint8ClampedArray,
  mask: Uint8Array,
  feather = 2,
): void {
  if (feather <= 0) return;
  const f = Math.round(feather);
  const known = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) known[i] = mask[i] ? 0 : 1;
  const dist = chamfer(known, w, h); // 0 outside the mask, grows inward
  for (let i = 0; i < w * h; i++) {
    if (!mask[i]) continue;
    const a = Math.min(1, dist[i] / (f + 1));
    const p = i * 4;
    repaired[p] = original[p] * (1 - a) + repaired[p] * a;
    repaired[p + 1] = original[p + 1] * (1 - a) + repaired[p + 1] * a;
    repaired[p + 2] = original[p + 2] * (1 - a) + repaired[p + 2] * a;
  }
}

// Full pipeline. Mutates and returns rgba.
export function inpaintImage(
  w: number,
  h: number,
  rgba: Uint8ClampedArray,
  mask: Uint8Array,
  opts: InpaintOptions = {},
): Uint8ClampedArray {
  const engine = opts.engine ?? 'fast';
  const dilate = opts.dilate ?? 2;
  const feather = opts.feather ?? 2;
  const original = Uint8ClampedArray.from(rgba);
  const m = expandMask(mask, w, h, dilate);

  fillThin(w, h, rgba, m, 6);
  if (engine === 'texture') fillExemplar(w, h, rgba, m, 4, opts.seed ?? 1);
  if (opts.symmetry) symmetryFill(w, h, rgba, m);
  featherBlend(w, h, original, rgba, m, feather);
  return rgba;
}
