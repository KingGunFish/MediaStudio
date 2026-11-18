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
