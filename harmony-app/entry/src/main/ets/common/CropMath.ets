// common/CropMath.ets - geometry helpers for the image crop page.
//
// Port of the transform model of electron-app/src/renderer/src/lib/cropMath.ts
// (which is the same model as the inline helpers in
// electron-app/src/renderer/src/pages/Crop.tsx):
//   scale   canvas pixels per source pixel (1 = 100% zoom)
//   x, y    the image's top-left corner in canvas coordinates

export interface Transform {
  scale: number;
  x: number;
  y: number;
}

export type FitMode = 'fill' | 'fit';

export function clamp(v: number, lo: number, hi: number): number {
  if (hi < lo) {
    return lo;
  }
  return Math.min(hi, Math.max(lo, v));
}

export function clampZoom(s: number): number {
  return Math.min(64, Math.max(0.02, s));
}

/**
 * Keeps the canvas point (cx, cy) fixed while scaling by `factor`.
 * The anchor maths is identical to the Windows build.
 */
export function zoomAt(t: Transform, cx: number, cy: number, factor: number): Transform {
  const scale = clampZoom(t.scale * factor);
  const k = scale / t.scale;
  return { scale: scale, x: cx - (cx - t.x) * k, y: cy - (cy - t.y) * k };
}

/**
 * Initial placement of the image inside the canvas.
 *  fill -> the image covers the canvas, the overflow is cropped away
 *  fit  -> the whole image stays visible, the rest is background
 */
export function fitTransform(srcW: number, srcH: number, w: number, h: number,
  mode: FitMode): Transform {
  const sx = w / srcW;
  const sy = h / srcH;
  const scale = mode === 'fill' ? Math.max(sx, sy) : Math.min(sx, sy);
  return {
    scale: scale,
    x: (w - srcW * scale) / 2,
    y: (h - srcH * scale) / 2
  };
}
