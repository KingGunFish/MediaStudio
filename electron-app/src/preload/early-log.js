// src/preload/early-log.js
// Runs at the very TOP of the renderer/preload before anything else.
// Writes to MULTIPLE locations to maximize chance of finding the log.
//
// To use: edit main.ts to import this file first via a dynamic require.

const fs = require('fs');
const os = require('os');
const path = require('path');

function tryWrite(filePath, line) {
  try {
    fs.appendFileSync(filePath, line + '\n', 'utf-8');
    return true;
  } catch (e) {
    return false;
  }
}

function ts() { return new Date().toISOString(); }
function brk() { return '='.repeat(60); }

const lines = [
  brk(),
  `[${ts()}] early-log.js: started`,
  `[${ts()}] process.versions: ${JSON.stringify(process.versions)}`,
  `[${ts()}] process.platform: ${process.platform} ${process.arch}`,
  `[${ts()}] process.execPath: ${process.execPath}`,
  `[${ts()}] process.cwd: ${process.cwd()}`,
  `[${ts()}] process.argv: ${JSON.stringify(process.argv)}`,
  `[${ts()}] __dirname: ${__dirname}`,
  `[${ts()}] __filename: ${__filename}`,
];

// Try many paths
const paths = [
  path.join(os.tmpdir(), 'media-studio.log'),
  path.join(os.tmpdir(), 'ms-studio.log'),
  path.join(process.cwd(), 'media-studio.log'),
  path.join(__dirname, '..', '..', 'media-studio.log'),
  process.execPath ? path.join(path.dirname(process.execPath), 'media-studio.log') : null,
  'C:\\Users\\Public\\media-studio.log',
].filter(Boolean);

for (const p of paths) {
  for (const l of lines) tryWrite(p, l);
}

// Also: write a unique marker file with timestamp
const marker = `media-studio-${Date.now()}.marker`;
const markerPath = path.join(os.tmpdir(), marker);
tryWrite(markerPath, `started at ${ts()}`);