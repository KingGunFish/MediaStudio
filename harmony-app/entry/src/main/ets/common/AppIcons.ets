// common/AppIcons.ets - output plans for the three platform icon tabs.
//
// Port of the Windows build's electron-app/src/renderer/src/lib/appicons.ts.
// The module stays pure data + text (no pixels), so the plans can be read and
// checked on their own; the pixels are rendered by pages/Icons.ets.

export type Plat = 'android' | 'ios' | 'harmony';

export type Fit = 'cover' | 'safe' | 'solid';

export type OutKind = 'png' | 'text';

export interface IconJob {
  /** path relative to the platform output folder */
  rel: string;
  /** square side in px */
  size: number;
  /**
   * cover = fill & center-crop;
   * safe  = fit inside the center box;
   * solid = a plain background colour, no image at all
   */
  fit: Fit;
  /** composite onto the background colour (drops alpha) */
  flatten: boolean;
  /** for fit 'safe': the content box is size * safeScale */
  safeScale: number;
  note: string;
}

export interface OutFile {
  /** path relative to the platform output folder */
  rel: string;
  kind: OutKind;
  /** valid when kind is 'png' */
  job: IconJob;
  /** valid when kind is 'text' */
  text: string;
}

interface MipmapEntry {
  dir: string;
  size: number;
}

interface IosEntry {
  size: string;
  idiom: string;
  scale: string;
  px: number;
}

interface IosImageEntry {
  size: string;
  idiom: string;
  filename: string;
  scale: string;
}

interface IosInfo {
  author: string;
  version: number;
}

interface IosContents {
  images: IosImageEntry[];
  info: IosInfo;
}

/** The folder a platform writes into. */
export function platDir(plat: Plat): string {
  if (plat === 'android') {
    return 'Android';
  }
  if (plat === 'ios') {
    return 'iOS';
  }
  return 'HarmonyOS';
}

/** The label shown on the platform tab. */
export function platLabel(plat: Plat): string {
  if (plat === 'android') {
    return 'Android';
  }
  if (plat === 'ios') {
    return 'iOS';
  }
  return 'HarmonyOS';
}

// Android adaptive icon: 108dp canvas, the mask can cut into anything beyond
// the center 66dp, so key content goes inside a 2/3 (=72/108) box.
const SAFE: number = 2 / 3;

const MIPMAP: MipmapEntry[] = [
  { dir: 'mipmap-mdpi', size: 48 },
  { dir: 'mipmap-hdpi', size: 72 },
  { dir: 'mipmap-xhdpi', size: 96 },
  { dir: 'mipmap-xxhdpi', size: 144 },
  { dir: 'mipmap-xxxhdpi', size: 192 }
];

// 108dp foreground/background layers per density (108 * 1/1.5/2/3/4).
const MIPMAP_LAYER: MipmapEntry[] = [
  { dir: 'mipmap-mdpi', size: 108 },
  { dir: 'mipmap-hdpi', size: 162 },
  { dir: 'mipmap-xhdpi', size: 216 },
  { dir: 'mipmap-xxhdpi', size: 324 },
  { dir: 'mipmap-xxxhdpi', size: 432 }
];

function pngFile(rel: string, size: number, fit: Fit, flatten: boolean, note: string,
  safeScale: number): OutFile {
  const job: IconJob = {
    rel: rel,
    size: size,
    fit: fit,
    flatten: flatten,
    safeScale: safeScale,
    note: note
  };
  const file: OutFile = { rel: rel, kind: 'png', job: job, text: '' };
  return file;
}

function textFile(rel: string, text: string): OutFile {
  const job: IconJob = {
    rel: rel,
    size: 0,
    fit: 'cover',
    flatten: false,
    safeScale: 0,
    note: ''
  };
  const file: OutFile = { rel: rel, kind: 'text', job: job, text: text };
  return file;
}

export function androidPlan(bgHex: string): OutFile[] {
  const files: OutFile[] = [];

  files.push(pngFile('playstore-512.png', 512, 'cover', false,
    'Google Play 商店图标 512x512 (允许透明)', 0));
  files.push(pngFile('huawei-market-216.png', 216, 'cover', true,
    '华为应用市场商店图标 216x216, PNG<=500KB (不透明)', 0));

  for (const entry of MIPMAP) {
    files.push(pngFile(entry.dir + '/ic_launcher.png', entry.size, 'cover', false,
      '传统桌面图标 ' + entry.size + 'x' + entry.size + ' (保留透明)', 0));
  }
  for (const entry of MIPMAP_LAYER) {
    files.push(pngFile(entry.dir + '/ic_launcher_foreground.png', entry.size, 'safe', false,
      '自适应图标前景层 ' + entry.size + 'x' + entry.size + ' (主体缩进中央 2/3 安全区)', SAFE));
    files.push(pngFile(entry.dir + '/ic_launcher_background.png', entry.size, 'solid', true,
      '自适应图标背景层 ' + entry.size + 'x' + entry.size + ' (纯色 ' + bgHex + ', 不透明)', 0));
  }

  const adaptiveXml: string = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">',
    '    <background android:drawable="@mipmap/ic_launcher_background" />',
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />',
    '</adaptive-icon>',
    ''
  ].join('\n');
  files.push(textFile('mipmap-anydpi-v26/ic_launcher.xml', adaptiveXml));
  files.push(textFile('mipmap-anydpi-v26/ic_launcher_round.xml', adaptiveXml));

  files.push(textFile('README.txt', [
    'Android 图标输出说明 (Media Studio 生成)',
    '==========================================',
    '',
    '1. mipmap-*/ 目录: 把这些文件夹整体复制到 Android 工程的 app/src/main/res/ 下。',
    '   - ic_launcher.png             传统桌面图标 (Android 7.x 及以下兜底)',
    '   - ic_launcher_foreground.png  自适应图标前景层 (Android 8.0+)',
    '   - ic_launcher_background.png  自适应图标背景层 (纯色, 不透明)',
    '   - mipmap-anydpi-v26/ic_launcher(.round).xml  自适应图标声明',
    '   AndroidManifest.xml 保持 android:icon="@mipmap/ic_launcher" 即可, 无需其它改动。',
    '',
    '2. playstore-512.png: 上传到 Google Play Console 的商店图标 (512x512, 允许透明)。',
    '',
    '3. huawei-market-216.png: 华为 AppGallery 上架图标 (216x216, PNG 需 <=500KB)。',
    '   已压平为不透明图片; 官方素材规范要求 PNG<=500KB / WEBP<=100KB。',
    '',
    '安全区提醒: 自适应图标的系统蒙版可能裁掉中心 66dp 以外的区域,',
    '前景层主体已自动缩放进中央 2/3 区域, 请确保原图主体居中。',
    ''
  ].join('\n')));
  return files;
}

// Official iOS size table; Contents.json maps all idiom/scale slots onto the
// unique pixel-size files below.
const IOS_ENTRIES: IosEntry[] = [
  { size: '20x20', idiom: 'iphone', scale: '2x', px: 40 },
  { size: '20x20', idiom: 'iphone', scale: '3x', px: 60 },
  { size: '29x29', idiom: 'iphone', scale: '1x', px: 29 },
  { size: '29x29', idiom: 'iphone', scale: '2x', px: 58 },
  { size: '29x29', idiom: 'iphone', scale: '3x', px: 87 },
  { size: '40x40', idiom: 'iphone', scale: '2x', px: 80 },
  { size: '40x40', idiom: 'iphone', scale: '3x', px: 120 },
  { size: '60x60', idiom: 'iphone', scale: '2x', px: 120 },
  { size: '60x60', idiom: 'iphone', scale: '3x', px: 180 },
  { size: '20x20', idiom: 'ipad', scale: '1x', px: 20 },
  { size: '20x20', idiom: 'ipad', scale: '2x', px: 40 },
  { size: '29x29', idiom: 'ipad', scale: '1x', px: 29 },
  { size: '29x29', idiom: 'ipad', scale: '2x', px: 58 },
  { size: '40x40', idiom: 'ipad', scale: '1x', px: 40 },
  { size: '40x40', idiom: 'ipad', scale: '2x', px: 80 },
  { size: '76x76', idiom: 'ipad', scale: '1x', px: 76 },
  { size: '76x76', idiom: 'ipad', scale: '2x', px: 152 },
  { size: '83.5x83.5', idiom: 'ipad', scale: '2x', px: 167 },
  { size: '1024x1024', idiom: 'ios-marketing', scale: '1x', px: 1024 }
];

function iosUniqueSizes(): number[] {
  const seen: number[] = [];
  for (const entry of IOS_ENTRIES) {
    if (seen.indexOf(entry.px) < 0) {
      seen.push(entry.px);
    }
  }
  seen.sort((a: number, b: number) => a - b);
  return seen;
}

export function iosContentsJson(): string {
  const images: IosImageEntry[] = [];
  for (const entry of IOS_ENTRIES) {
    const item: IosImageEntry = {
      size: entry.size,
      idiom: entry.idiom,
      filename: 'icon-' + entry.px + '.png',
      scale: entry.scale
    };
    images.push(item);
  }
  const info: IosInfo = { author: 'xcode', version: 1 };
  const contents: IosContents = { images: images, info: info };
  return JSON.stringify(contents, null, 2) + '\n';
}

export function iosPlan(): OutFile[] {
  const files: OutFile[] = [];
  const sizes: number[] = iosUniqueSizes();
  for (const size of sizes) {
    const rel: string = 'icon-' + size + '.png';
    const note: string = size === 1024 ?
      'App Store 商店图标 1024x1024 (无 alpha, 强制)' : 'iOS 图标 ' + size + 'x' + size;
    files.push(pngFile(rel, size, 'cover', true, note, 0));
  }
  files.push(textFile('Contents.json', iosContentsJson()));
  files.push(textFile('README.txt', [
    'iOS 图标输出说明 (Media Studio 生成)',
    '======================================',
    '',
    '1. 所有 PNG 已压平为不透明 24 位 RGB (无 alpha 通道), 符合 App Store',
    '   审核要求 (ITMS-90717: 图标不允许透明或含 alpha 通道)。',
    '',
    '2. Xcode 接入: 把本目录整体改名为 AppIcon.appiconset, 放入工程的',
    '   Assets.xcassets, Target > General > App Icons 选中即可; Contents.json',
    '   已按官方尺寸表生成, 无需手工填写。',
    '',
    '3. App Store Connect 上传只强制校验 icon-1024.png; 其余尺寸供旧版',
    '   Xcode / iPad 兼容使用。',
    '',
    '4. 不要自己加圆角: 上传直角正方形, 系统自动加圆角。',
    '   色彩空间 sRGB / Display P3 均可。',
    ''
  ].join('\n')));
  return files;
}

export function harmonyPlan(bgHex: string): OutFile[] {
  const files: OutFile[] = [];

  files.push(pngFile('media/foreground.png', 1024, 'safe', false,
    '分层图标前景层 1024x1024 (主体缩进中央安全区)', SAFE));
  files.push(pngFile('media/background.png', 1024, 'solid', true,
    '分层图标背景层 1024x1024 (纯色 ' + bgHex + ', 不透明, 审核硬性要求)', 0));
  files.push(pngFile('agc-store-216.png', 216, 'cover', true,
    'AppGallery 上架展示图标 216x216, PNG<=500KB', 0));
  files.push(pngFile('agc-store-1024.png', 1024, 'cover', true,
    'AppGallery 上架展示图标 1024x1024 (备用)', 0));

  // Byte for byte the same as JSON.stringify(..., null, 2) + '\n'.
  files.push(textFile('media/layered_image.json', [
    '{',
    '  "layered-image": {',
    '    "background": "$media:background",',
    '    "foreground": "$media:foreground"',
    '  }',
    '}',
    ''
  ].join('\n')));

  files.push(textFile('README.txt', [
    'HarmonyOS 图标输出说明 (Media Studio 生成)',
    '==========================================',
    '',
    '回答常见疑问: 鸿蒙分层图标是【两张】独立图片, 不是一张!',
    '前景图 foreground.png + 背景图 background.png, 各 1024x1024 PNG;',
    '背景层不允许有任何透明像素 (本次已输出为不透明纯色)。',
    '',
    '1. 工程内分层图标 (包内强制要求, 缺失会被审核驳回):',
    '   a. 把 media/foreground.png、media/background.png 复制到工程的',
    '      AppScope/resources/base/media/ 目录;',
    '   b. 把 media/layered_image.json 也复制到该目录;',
    '   c. AppScope/app.json5 中确认: "icon": "$media:layered_image"。',
    '   注意: 不要自己裁圆角、不要在图内自行预留白边, 主体居中即可;',
    '   前景层主体已缩放进中央 2/3 安全区, 系统按设备自动遮罩。',
    '   DevEco Studio 需 5.0.5.315 及以上版本。',
    '',
    '2. AGC 上架展示图标 (与包内分层图标是两回事, 都要提供):',
    '   AppGallery Connect 填写应用信息时上传 agc-store-216.png',
    '   (216x216, PNG<=500KB); 如入口支持 1024 也可用 agc-store-1024.png。',
    ''
  ].join('\n')));
  return files;
}

export function buildPlan(plat: Plat, bgHex: string): OutFile[] {
  if (plat === 'android') {
    return androidPlan(bgHex);
  }
  if (plat === 'ios') {
    return iosPlan();
  }
  return harmonyPlan(bgHex);
}

export function planPngCount(plan: OutFile[]): number {
  let count: number = 0;
  for (const file of plan) {
    if (file.kind === 'png') {
      count++;
    }
  }
  return count;
}
