#!/usr/bin/env node
// tools/update-version.mjs - Bump electron-app/package.json version.
//
// Scheme: <year>.<week>.<build>   e.g. 1.1.202609141506
//   1st segment: year version   +1 when crossing into a new year (1.1.x -> 2.0.x)
//   2nd segment: week version   +1 when crossing into a new week  (1.1.x -> 1.2.x)
//   3rd segment: build version  build timestamp YYYYMMDDHHMM (local, minute
//               precision) - changes on every build.
//
// Week boundary follows the ISO week (Monday as first day of week).
// Versions that do not match the scheme (e.g. the old 2026.0914.1513
// format) are migrated to 1.1.<now>.

import { readFileSync, writeFileSync } from 'node:fs';

const pkgPath = new URL('../electron-app/package.json', import.meta.url);
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));

const pad = (n) => String(n).padStart(2, '0');

// Build timestamp: YYYYMMDDHHMM
const buildStamp = (d = new Date()) =>
  `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}`;

// ISO week number (Monday-first).
function isoWeek(d) {
  const date = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const day = date.getDay() || 7; // Mon=1 ... Sun=7
  date.setDate(date.getDate() + 4 - day);
  const yearStart = new Date(date.getFullYear(), 0, 1);
  return Math.ceil(((date - yearStart) / 86400000 + 1) / 7);
}

let major = 1;
let minor = 1;
const current = typeof pkg.version === 'string' ? pkg.version : '';
if (/^\d+\.\d+\.\d{12}$/.test(current)) {
  const [maj, min, stamp] = current.split('.').map(Number);
  const prev = new Date(
    Math.floor(stamp / 1e8),
    Math.floor((stamp % 1e8) / 1e6) - 1,
    Math.floor((stamp % 1e6) / 1e4),
  );
  const now = new Date();
  if (now.getFullYear() > prev.getFullYear()) {
    // 跨年: 年度版本 +1, 周版本归零 (1.1.x -> 2.0.x)
    major = maj + 1;
    minor = 0;
  } else if (isoWeek(now) !== isoWeek(prev)) {
    // 跨周: 周版本 +1 (1.1.x -> 1.2.x)
    major = maj;
    minor = min + 1;
  } else {
    // 同一周: 只更新编译版本
    major = maj;
    minor = min;
  }
}

pkg.version = `${major}.${minor}.${buildStamp()}`;
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
console.log(`[update-version] ${pkg.name} version -> ${pkg.version}`);
