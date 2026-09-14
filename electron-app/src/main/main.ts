// src/main/main.ts - Electron main process

// EARLY LOG: write log BEFORE anything else (TypeScript erases imports to
// runtime, so we use require() to ensure order). Write to MULTIPLE paths.
import { existsSync, appendFileSync } from 'fs';
import { tmpdir } from 'os';
import { join as pjoin } from 'path';

const _earlyLog = (msg: string) => {
  try {
    const ts = new Date().toISOString();
    const paths = [
      pjoin(tmpdir(), 'media-studio.log'),
      pjoin(tmpdir(), 'ms-early.log'),
      'C:\\Users\\Public\\media-studio.log',
    ];
    for (const p of paths) {
      try { appendFileSync(p, `[${ts}] ${msg}\n`); } catch {}
    }
  } catch {}
};
_earlyLog('main.ts: module load START');
_earlyLog(`execPath: ${process.execPath}`);
_earlyLog(`argv[0]: ${process.argv[0]}`);
_earlyLog(`node: ${process.versions.node}`);
_earlyLog(`electron: ${process.versions.electron}`);

import './logger';
import { log, logPath } from './logger';

log('main.ts: starting');
_earlyLog('main.ts: logger imported');
import { app, BrowserWindow, ipcMain, dialog, shell } from 'electron';
log('main.ts: electron imported');
_earlyLog('main.ts: electron imported');
import { spawn, ChildProcess } from 'child_process';
log('main.ts: child_process imported');
import * as path from 'path';
import * as fs from 'fs';
import * as readline from 'readline';
import { randomUUID } from 'crypto';
log('main.ts: stdlib imported');

log(`Log file: ${logPath}`);

let mainWindow: BrowserWindow | null = null;

// === Locate the SDK worker binary ===

function findSdkWorker(): string {
  const base = process.platform === 'win32' ? 'ms_demo.exe'
             : process.platform === 'darwin' ? 'ms_demo'
             : 'ms_demo';
  const candidates = [
    // Packaged: extraResources copies resources/sdk -> <resources>/sdk
    path.join(process.resourcesPath, 'sdk', base),
    // Packaged (fallback if getAppPath points at the resources dir)
    path.join(app.getAppPath(), 'sdk', base),
    // Dev / source tree: resources/sdk (prebuilt) or sdk/build (cmake output)
    path.join(process.cwd(), 'resources', 'sdk', base),
    path.join(process.cwd(), '..', 'sdk', 'build', base),
    path.join(process.cwd(), 'sdk', 'build', base),
    path.join(app.getAppPath(), 'resources', 'sdk', base),
    // Source tree (when running via electron . from dev dir)
    path.join(__dirname, '..', 'sdk', 'build', base),
    path.join(__dirname, '..', '..', 'sdk', 'build', base),
    path.join(__dirname, '..', '..', '..', 'sdk', 'build', base),
    path.join(__dirname, '..', '..', 'resources', 'sdk', base),
  ];
  if (process.env.MS_SDK_WORKER) candidates.unshift(process.env.MS_SDK_WORKER);
  for (const p of candidates) {
    try {
      if (fs.existsSync(p) && fs.statSync(p).isFile()) {
        log(`SDK worker found: ${p}`);
        return p;
      }
    } catch (e) {
      log(`SDK worker probe error for ${p}: ${(e as Error).message}`);
    }
  }
  log(`SDK worker NOT FOUND in any candidate`);
  return candidates[0];
}

// === SDK worker subprocess wrapper (one per request, or persistent) ===
//
// We use a *persistent* worker that reads JSON commands from stdin and
// writes JSON results to stdout. Each result is one line of JSON.
// The worker is `ms_ipc_server` (to be built into the SDK). For now we
// fall back to spawning `ms_demo` per request and parsing its stderr.

interface SdkRequest {
  id: string;
  cmd: 'video2gif' | 'keying' | 'version' | 'probe';
  args: any;
}

interface SdkResult {
  id: string;
  ok: boolean;
  result?: any;
  error?: string;
  progress?: { value: number; message: string };
  final?: boolean;
}

class SdkWorker {
  private proc: ChildProcess | null = null;
  private buf = '';
  private pending = new Map<string, {
    resolve: (r: SdkResult) => void;
    reject: (e: Error) => void;
    onProgress?: (p: number, m: string) => void;
  }>();
  private path: string;
  private mode: 'ipc' | 'cli';

  constructor() {
    this.path = findSdkWorker();
    // Detect which mode: if a sibling `ms_ipc_server` exists we use it,
    // otherwise fall back to per-request ms_demo.
    const ipcServer = this.path.replace(/ms_demo(\.\w+)?$/, 'ms_ipc_server$1');
    if (fs.existsSync(ipcServer)) {
      this.path = ipcServer;
      this.mode = 'ipc';
    } else {
      this.mode = 'cli';
    }
  }

  start() {
    if (this.mode !== 'ipc') return;  // CLI mode spawns per-request
    this.proc = spawn(this.path, [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const rl = readline.createInterface({ input: this.proc.stdout! });
    rl.on('line', (line) => {
      try {
        const msg = JSON.parse(line) as SdkResult;
        const entry = this.pending.get(msg.id);
        if (!entry) return;
        if (msg.progress && entry.onProgress) {
          entry.onProgress(msg.progress.value, msg.progress.message);
        }
        if (msg.final) {
          this.pending.delete(msg.id);
          entry.resolve(msg);
        }
      } catch (e) {
        // ignore non-JSON lines
      }
    });
    this.proc.stderr?.on('data', () => {});  // discard
    this.proc.on('exit', (code) => {
      for (const e of this.pending.values()) {
        e.reject(new Error(`SDK worker exited (code ${code})`));
      }
      this.pending.clear();
    });
  }

  send(req: SdkRequest, onProgress?: (p: number, m: string) => void): Promise<SdkResult> {
    if (this.mode === 'ipc') {
      return new Promise((resolve, reject) => {
        this.pending.set(req.id, { resolve, reject, onProgress });
        this.proc!.stdin!.write(JSON.stringify(req) + '\n');
      });
    } else {
      // CLI fallback: spawn ms_demo per call, parse stderr for progress.
      return this.runCli(req, onProgress);
    }
  }

  private runCli(req: SdkRequest, onProgress?: (p: number, m: string) => void): Promise<SdkResult> {
    return new Promise((resolve) => {
      const args = this.cliArgs(req);
      if (!args) {
        resolve({ id: req.id, ok: false, error: 'Unsupported cmd: ' + req.cmd, final: true });
        return;
      }
      const proc = spawn(this.path, args, { stdio: ['ignore', 'pipe', 'pipe'] });
      let stderr = '';
      proc.stderr.on('data', (chunk) => {
        const s = chunk.toString();
        stderr += s;
        for (const line of s.split('\n')) {
          if (!line.trim()) continue;
          if (onProgress) {
            // ms_demo prints "[60%] encoding" style
            const m = line.match(/\[(\d+)%\]/);
            if (m) onProgress(parseInt(m[1], 10) / 100, 'encoding');
          }
        }
      });
      proc.on('exit', (code) => {
        if (code === 0) {
          // Parse the "OK: ..." line
          const okLine = stderr.split('\n').reverse().find((l) => l.startsWith('OK:'));
          const result: any = {};
          if (okLine) {
            // e.g. "OK: 242 frames, 480x360, 13195194 bytes"
            const m = okLine.match(/(\d+)\s+frames?,\s+(\d+)x(\d+),\s+(\d+)\s+bytes/);
            if (m) {
              result.frameCount = +m[1];
              result.outputWidth = +m[2];
              result.outputHeight = +m[3];
              result.fileSize = +m[4];
            }
            const m2 = okLine.match(/(\d+)\s+->\s+(\d+)\s+frames?/);
            if (m2) {
              result.inputFrameCount = +m2[1];
              result.frameCount = +m2[2];
            }
          }
          resolve({ id: req.id, ok: true, result, final: true });
        } else {
          resolve({ id: req.id, ok: false, error: stderr || `exit ${code}`, final: true });
        }
      });
    });
  }

  private cliArgs(req: SdkRequest): string[] | null {
    if (req.cmd === 'version') return null;  // TODO
    if (req.cmd === 'video2gif') {
      const a = req.args;
      return [
        'video2gif', a.input, a.output,
        '--width', String(a.width ?? 480),
        '--fps', String(a.fps ?? 12),
        a.pingPong !== false ? '--ping-pong' : '--no-ping-pong',
      ];
    }
    if (req.cmd === 'keying') {
      const a = req.args;
      const algo = a.algorithm ?? 'rgbSplit';
      return [
        'keying', a.input, a.output,
        algo,
        a.pingPong !== false ? '--ping-pong' : '--no-ping-pong',
        ...(a.bgR !== undefined ? ['--bg', `${a.bgR},${a.bgG},${a.bgB}`] : []),
      ];
    }
    return null;
  }

  dispose() {
    if (this.proc) this.proc.kill();
    this.proc = null;
  }
}

let sdkWorker: SdkWorker | null = null;
function getWorker(): SdkWorker {
  if (!sdkWorker) {
    sdkWorker = new SdkWorker();
    sdkWorker.start();
  }
  return sdkWorker;
}

// === IPC handlers (main <-> renderer) ===

ipcMain.handle('dialog:openFile', async (_e, filters?: string) => {
  const filterArr: any[] = [];
  if (filters) {
    // The renderer passes MIME-ish tokens (e.g. "video/mp4,video/*" or
    // "image/gif"). Electron's dialog filters need real extensions, so we
    // normalize: "video/*" -> a known video set, "video/mp4" -> ["mp4"],
    // ".mp4" / "mp4" -> ["mp4"], "*" -> match all.
    const knownByCat: Record<string, string[]> = {
      video: ['mp4', 'mov', 'webm', 'avi', 'mkv', 'm4v', 'flv', 'wmv', 'mpeg', 'mpg', 'ogv'],
      image: ['gif', 'png', 'jpg', 'jpeg', 'bmp', 'webp', 'tiff'],
    };
    const exts = new Set<string>();
    for (const raw of filters.split(',')) {
      let t = raw.trim().toLowerCase();
      if (!t) continue;
      if (t.startsWith('.')) t = t.slice(1);
      if (t.includes('/')) {
        const [cat, sub] = t.split('/');
        if (!sub || sub === '*') {
          (knownByCat[cat] || ['*']).forEach((e) => exts.add(e));
        } else {
          exts.add(sub.replace(/^\./, ''));
        }
      } else if (t === '*' || t === '*.*') {
        exts.add('*');
      } else {
        exts.add(t);
      }
    }
    const list = [...exts];
    if (list.length) {
      const label = list.includes('*')
        ? 'All Supported'
        : list.map((e) => '.' + e).join(', ');
      filterArr.push({ name: label, extensions: list });
    }
  }
  filterArr.push({ name: 'All Files', extensions: ['*'] });
  const result = await dialog.showOpenDialog({
    properties: ['openFile'],
    filters: filterArr,
  });
  if (result.canceled || result.filePaths.length === 0) return '';
  return result.filePaths[0];
});

ipcMain.handle('dialog:saveFile', async (_e, defaultName?: string) => {
  const result = await dialog.showSaveDialog({
    defaultPath: defaultName,
  });
  if (result.canceled || !result.filePath) return '';
  return result.filePath;
});

ipcMain.handle('shell:reveal', (_e, filePath: string) => {
  shell.showItemInFolder(filePath);
});

// Read a whole file as bytes (used by the renderer to decode images without
// depending on file:// page access). Returns null when missing/unreadable.
ipcMain.handle('fs:readFile', (_e, p: string) => {
  try {
    if (!p || !fs.existsSync(p) || !fs.statSync(p).isFile()) return null;
    return fs.readFileSync(p);
  } catch (e) {
    log(`fs:readFile FAILED ${p}: ${(e as Error).message}`);
    return null;
  }
});

// Write bytes to disk (renderer-side generated BMP / .c / .bin outputs).
// Creates the parent directory when missing, mirroring the SDK handlers.
ipcMain.handle('fs:writeFile', (_e, p: string, data: Uint8Array) => {
  try {
    if (!p) return { ok: false, error: '输出路径为空' };
    const dir = path.dirname(p);
    if (dir && !fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(p, Buffer.from(data));
    log(`fs:writeFile OK ${p} (${data.length} bytes)`);
    return { ok: true };
  } catch (e) {
    const msg = (e as Error).message;
    log(`fs:writeFile FAILED ${p}: ${msg}`);
    return { ok: false, error: msg };
  }
});

// Resolve the ffprobe binary. The bundled SDK already depends on ffmpeg/ffprobe
// being reachable (it shells out to them), so we first try PATH, then a copy
// placed next to ms_demo in resources/sdk.
function findFfprobe(): string {
  const candidates = [
    'ffprobe',
    path.join(process.resourcesPath, 'sdk', 'ffprobe.exe'),
    path.join(app.getAppPath(), 'sdk', 'ffprobe.exe'),
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c) && fs.statSync(c).isFile()) {
        log(`ffprobe found: ${c}`);
        return c;
      }
    } catch {}
  }
  return 'ffprobe';
}

// Probe a video file for its original geometry, fps, duration and file size.
// Used by the renderer to show aspect-locked width/height boxes and to warn
// about very long / large inputs. Result is surfaced to the UI; a probe
// failure degrades gracefully (renderer falls back to independent boxes).
ipcMain.handle('sdk:probe', async (_e, input: string) => {
  if (!input || !fs.existsSync(input)) {
    return { ok: false, error: `输入文件不存在: ${input || '(空)'}` };
  }
  const ff = findFfprobe();
  const args = [
    '-v', 'error',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=width,height,r_frame_rate,nb_frames,duration,codec_name',
    '-of', 'json',
    input,
  ];
  log(`sdk:probe REQUEST input=${input} ff=${ff}`);
  return new Promise((resolve) => {
    const proc = spawn(ff, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let errOut = '';
    proc.stdout.on('data', (d: Buffer) => { out += d.toString(); });
    proc.stderr.on('data', (d: Buffer) => { errOut += d.toString(); });
    proc.on('exit', (code) => {
      if (code !== 0) {
        const msg = `ffprobe 执行失败 (exit ${code}): ${errOut || '(no stderr)'}`;
        log(`sdk:probe FAILED input=${input} ${msg}`);
        resolve({ ok: false, error: msg });
        return;
      }
      try {
        const json = JSON.parse(out);
        const s = json.streams && json.streams[0];
        if (!s) {
          resolve({ ok: false, error: '无法解析视频流信息(可能不是视频文件)' });
          return;
        }
        const fr = String(s.r_frame_rate || '').split('/');
        const fps = fr.length === 2
          ? (+fr[0] / (+fr[1] || 1))
          : (+fr[0] || 0);
        const stat = fs.statSync(input);
        const result = {
          ok: true,
          width: parseInt(s.width, 10) || 0,
          height: parseInt(s.height, 10) || 0,
          fps: Math.round(fps * 100) / 100,
          duration: parseFloat(s.duration) || 0,
          nbFrames: parseInt(s.nb_frames, 10) || 0,
          codec: s.codec_name || '',
          fileSize: stat.size,
        };
        log(`sdk:probe OK input=${input} ${result.width}x${result.height} dur=${result.duration}s size=${result.fileSize}`);
        resolve(result);
      } catch (e) {
        resolve({ ok: false, error: `解析 ffprobe 输出失败: ${(e as Error).message}` });
      }
    });
  });
});

ipcMain.handle('sdk:init', async () => {
  const p = findSdkWorker();
  if (!fs.existsSync(p)) {
    return { ok: false, error: `SDK worker not found: ${p}`, path: p };
  }
  // The bundled worker (ms_demo) does NOT implement a `version` subcommand,
  // and `ms_demo --help` exits with code 1, so it can't be used as a smoke
  // test. A present, executable worker binary is sufficient proof that the
  // SDK is loadable — the real commands (video2gif / keying) are exercised
  // on demand. We therefore treat existence as "loaded" and don't gate init
  // on a command the engine doesn't support (that previously produced
  // "SDK 加载失败: Unsupported cmd: version").
  log(`SDK worker present: ${p}`);
  _earlyLog(`SDK worker present: ${p}`);
  return { ok: true, version: 'ms_demo', path: p };
});

ipcMain.handle('sdk:video2gif', async (event, args: {
  input: string; output: string; options: any;
}, progressId: string) => {
  const id = randomUUID();
  const o = args.options || {};
  // Flatten options into the worker args (cliArgs expects flat fields,
  // not a nested `options` object).
  const workerArgs = {
    input: args.input,
    output: args.output,
    width: o.width,
    fps: o.fps,
    pingPong: o.pingPong,
  };
  log(`sdk:video2gif REQUEST input=${args.input} output=${args.output} width=${o.width} fps=${o.fps} pingPong=${o.pingPong}`);
  // Guard: input must exist, otherwise the worker would fail with a cryptic
  // "file not found". Surface a clear, logged reason instead.
  if (!args.input || !fs.existsSync(args.input)) {
    const msg = `输入文件不存在: ${args.input || '(空)'}`;
    log(`sdk:video2gif ERROR ${msg}`);
    return { id, ok: false, error: msg, final: true };
  }
  // Ensure the output directory exists (handles spaces / non-ASCII paths too).
  try {
    const outDir = path.dirname(args.output);
    if (outDir && !fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  } catch (e) {
    const msg = `无法创建输出目录: ${(e as Error).message}`;
    log(`sdk:video2gif ERROR ${msg}`);
    return { id, ok: false, error: msg, final: true };
  }
  return new Promise((resolve) => {
    getWorker().send(
      { id, cmd: 'video2gif', args: workerArgs },
      (p, m) => {
        if (event.sender && !event.sender.isDestroyed()) {
          event.sender.send(`progress:${progressId}`, { value: p, message: m });
        }
      }
    ).then((r) => {
      if (!r.ok) {
        log(`sdk:video2gif FAILED input=${args.input} error=${r.error}`);
      } else {
        log(`sdk:video2gif OK input=${args.input} frames=${r.result?.frameCount} size=${r.result?.fileSize}`);
      }
      if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send(`done:${progressId}`, r);
      }
      resolve(r);
    }).catch((e) => {
      log(`sdk:video2gif EXCEPTION input=${args.input} err=${(e as Error).message}`);
      resolve({ id, ok: false, error: (e as Error).message, final: true });
    });
  });
});

ipcMain.handle('sdk:keying', async (event, args: {
  input: string; output: string; options: any;
}, progressId: string) => {
  const id = randomUUID();
  const o = args.options || {};
  const workerArgs = {
    input: args.input,
    output: args.output,
    algorithm: o.algorithm,
    pingPong: o.pingPong,
    bgR: o.bgR,
    bgG: o.bgG,
    bgB: o.bgB,
  };
  log(`sdk:keying REQUEST input=${args.input} output=${args.output} algorithm=${o.algorithm}`);
  if (!args.input || !fs.existsSync(args.input)) {
    const msg = `输入文件不存在: ${args.input || '(空)'}`;
    log(`sdk:keying ERROR ${msg}`);
    return { id, ok: false, error: msg, final: true };
  }
  try {
    const outDir = path.dirname(args.output);
    if (outDir && !fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  } catch (e) {
    const msg = `无法创建输出目录: ${(e as Error).message}`;
    log(`sdk:keying ERROR ${msg}`);
    return { id, ok: false, error: msg, final: true };
  }
  return new Promise((resolve) => {
    getWorker().send(
      { id, cmd: 'keying', args: workerArgs },
      (p, m) => {
        if (event.sender && !event.sender.isDestroyed()) {
          event.sender.send(`progress:${progressId}`, { value: p, message: m });
        }
      }
    ).then((r) => {
      if (!r.ok) {
        log(`sdk:keying FAILED input=${args.input} error=${r.error}`);
      } else {
        log(`sdk:keying OK input=${args.input} frames=${r.result?.frameCount} size=${r.result?.fileSize}`);
      }
      if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send(`done:${progressId}`, r);
      }
      resolve(r);
    }).catch((e) => {
      log(`sdk:keying EXCEPTION input=${args.input} err=${(e as Error).message}`);
      resolve({ id, ok: false, error: (e as Error).message, final: true });
    });
  });
});

// === Window ===

async function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    backgroundColor: '#0f1419',
    title: 'Media Studio',
    icon: getIconPath(),
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) {
    await mainWindow.loadURL(devUrl);
  } else {
    // dist/main/main/main.js → ../../renderer/index.html
    const indexPath = path.join(__dirname, '..', '..', 'renderer', 'index.html');
    await mainWindow.loadFile(indexPath);
  }

  mainWindow.on('closed', () => { mainWindow = null; });
}

function getIconPath(): string {
  const candidates = [
    path.join(__dirname, '..', '..', 'resources', 'icon.ico'),
    path.join(__dirname, '..', '..', 'resources', 'icon.png'),
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return '';
}

app.whenReady().then(async () => {
  log('app: whenReady fired');
  _earlyLog('app: whenReady fired');
  // Eagerly init the worker so the renderer gets a fast first call
  try {
    getWorker();
    log('SDK worker initialized');
    _earlyLog('SDK worker initialized');
  } catch (e) {
    log(`SDK init failed: ${(e as Error).message}`);
    _earlyLog(`SDK init failed: ${(e as Error).message}`);
    console.error('SDK init failed:', e);
  }
  log('app: creating main window');
  _earlyLog('app: creating main window');
  await createMainWindow();
  log('app: main window created');
  _earlyLog('app: main window created');
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createMainWindow();
  });
}).catch((e) => {
  log(`app: whenReady error: ${(e as Error).message}`);
  _earlyLog(`app: whenReady error: ${(e as Error).message}`);
});

app.on('window-all-closed', () => {
  if (sdkWorker) sdkWorker.dispose();
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', () => {
  if (sdkWorker) sdkWorker.dispose();
});