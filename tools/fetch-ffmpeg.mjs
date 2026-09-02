#!/usr/bin/env node
/**
 * Fetch ffmpeg / ffprobe binaries into electron-app/resources/sdk so that
 * `npm run package` bundles them. The shipped app then works out of the box
 * with NO system ffmpeg on PATH.
 *
 * Defaults to the LGPL build (MIT-compatible). Set FFMPEG_BUILD=gpl to fetch
 * the full GPL build, or set FFMPEG_BUILD_URL to a custom archive.
 *
 * Skips downloading when a compatible ffmpeg(.exe) already exists in the
 * target dir, unless FORCE_FETCH=1. If the default (LGPL) build is requested
 * but an existing binary turns out to be a GPL build, it is re-fetched so the
 * shipped app stays MIT-compatible.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import {
  existsSync, mkdirSync, readdirSync, statSync, copyFileSync, rmSync,
} from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const sdkDir = join(__dirname, '..', 'electron-app', 'resources', 'sdk');
mkdirSync(sdkDir, { recursive: true });

const platform = process.platform; // win32 | linux | darwin
const variant = process.env.FFMPEG_BUILD === 'gpl' ? 'gpl' : 'lgpl';

const URLS = {
  win32: {
    lgpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip',
    gpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
  },
  linux: {
    lgpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-lgpl.tar.xz',
    gpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz',
  },
  darwin: {
    lgpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-macos64-lgpl.zip',
    gpl: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-macos64-gpl.zip',
  },
};

const exeSuffix = platform === 'win32' ? '.exe' : '';
const targetFfmpeg = join(sdkDir, `ffmpeg${exeSuffix}`);
const targetFfprobe = join(sdkDir, `ffprobe${exeSuffix}`);

// Detect whether an existing binary is a GPL build (so the default LGPL fetch
// can replace it and keep the shipped app MIT-compatible).
function binaryIsGpl(binPath) {
  try {
    const r = spawnSync(binPath, ['-version'], { encoding: 'utf8', timeout: 15000 });
    const out = `${r.stdout || ''}${r.stderr || ''}`;
    return /--enable-gpl\b/.test(out);
  } catch {
    return false; // cannot determine -> treat as compatible, don't block
  }
}

const present = existsSync(targetFfmpeg) && existsSync(targetFfprobe);
const presentIsGpl = present && variant === 'lgpl' && binaryIsGpl(targetFfmpeg);

if (present && !presentIsGpl && !process.env.FORCE_FETCH) {
  console.log('[fetch-ffmpeg] ffmpeg/ffprobe already present (LGPL-compatible) in resources/sdk — skipping.');
  process.exit(0);
}
if (presentIsGpl) {
  console.log('[fetch-ffmpeg] existing ffmpeg is a GPL build; re-fetching LGPL to keep the app MIT-compatible.');
}

const url = process.env.FFMPEG_BUILD_URL
  || (URLS[platform] && URLS[platform][variant])
  || URLS.win32.lgpl;

console.log(`[fetch-ffmpeg] downloading ${variant} build for ${platform}:\n  ${url}`);

const tmp = join(tmpdir(), `ffmpeg-${variant}-${platform}.${url.endsWith('.zip') ? 'zip' : 'txz'}`);
try {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const { writeFileSync } = await import('node:fs');
  writeFileSync(tmp, buf);
  console.log(`[fetch-ffmpeg] downloaded ${(buf.length / 1048576).toFixed(1)} MB -> ${tmp}`);
} catch (e) {
  console.error(`[fetch-ffmpeg] download failed: ${e.message}`);
  console.error('[fetch-ffmpeg] You can place ffmpeg.exe + ffprobe.exe manually into electron-app/resources/sdk/');
  process.exit(1);
}

// Extract with the system `tar` (handles .zip on Windows/macOS and .tar.xz on Linux).
const extractDir = join(tmpdir(), `ffmpeg-extract-${variant}-${platform}`);
rmSync(extractDir, { recursive: true, force: true });
mkdirSync(extractDir, { recursive: true });
try {
  execFileSync('tar', ['-xf', tmp, '-C', extractDir], { stdio: 'inherit' });
} catch (e) {
  console.error(`[fetch-ffmpeg] extraction failed: ${e.message}`);
  process.exit(1);
}

// BtbN archives nest binaries under <root>/bin/
function findBin(dir, name) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      const found = findBin(full, name);
      if (found) return found;
    } else if (entry === name) {
      return full;
    }
  }
  return null;
}

const srcFfmpeg = findBin(extractDir, `ffmpeg${exeSuffix}`);
const srcFfprobe = findBin(extractDir, `ffprobe${exeSuffix}`);
if (!srcFfmpeg || !srcFfprobe) {
  console.error('[fetch-ffmpeg] could not locate ffmpeg/ffprobe in archive');
  process.exit(1);
}
copyFileSync(srcFfmpeg, targetFfmpeg);
copyFileSync(srcFfprobe, targetFfprobe);
rmSync(extractDir, { recursive: true, force: true });
rmSync(tmp, { force: true });
console.log(`[fetch-ffmpeg] installed -> ${targetFfmpeg}\n                  ${targetFfprobe}`);
console.log('[fetch-ffmpeg] done.');
