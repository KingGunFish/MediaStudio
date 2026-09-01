// src/main/logger.ts - write diagnostic log to file
// This file is loaded FIRST (before main.ts runs), so we can trace
// where the app crashes. The log is written to %TEMP%\media-studio.log
// (or C:\Users\<user>\AppData\Local\Temp\media-studio.log) and is
// appended across runs so we get a complete history.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const LOG_PATH = path.join(os.tmpdir(), 'media-studio.log');

function ts(): string {
  return new Date().toISOString();
}

function write(line: string) {
  try {
    fs.appendFileSync(LOG_PATH, `[${ts()}] ${line}\n`, 'utf-8');
  } catch {
    // best-effort
  }
}

// First line: marker
write('===========================================');
write(`Media Studio launched (pid=${process.pid}, node=${process.versions.node}, electron=${process.versions.electron})`);
write(`Platform: ${process.platform} ${process.arch}`);
write(`Executable: ${process.execPath}`);
write(`Cwd: ${process.cwd()}`);
write(`Log: ${LOG_PATH}`);

// Catch ALL errors
process.on('uncaughtException', (err) => {
  write(`!! uncaughtException: ${err && err.stack ? err.stack : err}`);
});
process.on('unhandledRejection', (reason) => {
  write(`!! unhandledRejection: ${reason}`);
});
process.on('exit', (code) => {
  write(`Process exit (code=${code})`);
});

export function log(msg: string) {
  write(msg);
}

export const logPath = LOG_PATH;