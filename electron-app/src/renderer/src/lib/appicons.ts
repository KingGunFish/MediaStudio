// src/renderer/src/lib/appicons.ts - Output file plans for the three
// platform icon tabs (Android / iOS / HarmonyOS). Pure data + text so the
// plans are unit-testable; pixels are rendered in the page.

export type Plat = 'android' | 'ios' | 'harmony';

export type Fit = 'cover' | 'safe';

export interface IconJob {
  rel: string; // path relative to the platform output folder
  size: number; // square side in px
  fit: Fit; // cover = fill & center-crop; safe = fit inside center box
  flatten: boolean; // composite onto bg color (drops alpha)
  safeScale?: number; // for fit 'safe': content box = size * safeScale
  note: string;
}

export type OutFile =
  | { rel: string; kind: 'png'; job: IconJob }
  | { rel: string; kind: 'text'; text: string };

export const PLAT_DIRS: Record<Plat, string> = {
  android: 'Android',
  ios: 'iOS',
  harmony: 'HarmonyOS',
};

export const PLAT_LABELS: Record<Plat, string> = {
  android: 'Android',
  ios: 'iOS',
  harmony: 'HarmonyOS',
};

// Android adaptive icon: 108dp canvas, the mask can cut into anything beyond
// the center 66dp, so key content goes inside a 2/3 (=72/108) box.
const SAFE = 2 / 3;

const MIPMAP: Array<[string, number]> = [
  ['mipmap-mdpi', 48],
  ['mipmap-hdpi', 72],
  ['mipmap-xhdpi', 96],
  ['mipmap-xxhdpi', 144],
  ['mipmap-xxxhdpi', 192],
];

// 108dp foreground/background layers per density (108 * 1/1.5/2/3/4).
const MIPMAP_LAYER: Array<[string, number]> = [
  ['mipmap-mdpi', 108],
  ['mipmap-hdpi', 162],
  ['mipmap-xhdpi', 216],
  ['mipmap-xxhdpi', 324],
  ['mipmap-xxxhdpi', 432],
];

export function androidPlan(bgHex: string): OutFile[] {
  const files: OutFile[] = [];
  const png = (
    rel: string,
    size: number,
    fit: Fit,
    flatten: boolean,
    note: string,
    safeScale?: number,
  ) =>
    files.push({
      rel,
      kind: 'png',
      job: { rel, size, fit, flatten, safeScale, note },
    });

  png('playstore-512.png', 512, 'cover', false, 'Google Play 商店图标 512x512 (允许透明)');
  png('huawei-market-216.png', 216, 'cover', true, '华为应用市场商店图标 216x216, PNG<=500KB (不透明)');

  for (const [dir, s] of MIPMAP) {
    png(`${dir}/ic_launcher.png`, s, 'cover', false, `传统桌面图标 ${s}x${s} (保留透明)`);
  }
  for (const [dir, s] of MIPMAP_LAYER) {
    png(
      `${dir}/ic_launcher_foreground.png`,
      s,
      'safe',
      false,
      `自适应图标前景层 ${s}x${s} (主体缩进中央 2/3 安全区)`,
      SAFE,
    );
    png(
      `${dir}/ic_launcher_background.png`,
      s,
      'cover',
      true,
      `自适应图标背景层 ${s}x${s} (纯色 ${bgHex}, 不透明)`,
    );
  }

  const adaptiveXml = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">',
    '    <background android:drawable="@mipmap/ic_launcher_background" />',
    '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />',
    '</adaptive-icon>',
    '',
  ].join('\n');
  files.push({ rel: 'mipmap-anydpi-v26/ic_launcher.xml', kind: 'text', text: adaptiveXml });
  files.push({ rel: 'mipmap-anydpi-v26/ic_launcher_round.xml', kind: 'text', text: adaptiveXml });

  files.push({
    rel: 'README.txt',
    kind: 'text',
    text: [
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
      '',
    ].join('\n'),
  });
  return files;
}

// Official iOS size table; Contents.json maps all idiom/scale slots onto
// the unique pixel-size files below.
const IOS_ENTRIES: Array<{ size: string; idiom: string; scale: string; px: number }> = [
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
  { size: '1024x1024', idiom: 'ios-marketing', scale: '1x', px: 1024 },
];

// Unique pixel sizes actually rendered as files.
const IOS_PX = [...new Set(IOS_ENTRIES.map((e) => e.px))].sort((a, b) => a - b);

export function iosContentsJson(): string {
  const images = IOS_ENTRIES.map((e) => ({
    size: e.size,
    idiom: e.idiom,
    filename: `icon-${e.px}.png`,
    scale: e.scale,
  }));
  return JSON.stringify({ images, info: { author: 'xcode', version: 1 } }, null, 2) + '\n';
}

export function iosPlan(): OutFile[] {
  const files: OutFile[] = [];
  for (const s of IOS_PX) {
    const rel = `icon-${s}.png`;
    files.push({
      rel,
      kind: 'png',
      job: {
        rel,
        size: s,
        fit: 'cover',
        flatten: true,
        note: s === 1024 ? 'App Store 商店图标 1024x1024 (无 alpha, 强制)' : `iOS 图标 ${s}x${s}`,
      },
    });
  }
  files.push({ rel: 'Contents.json', kind: 'text', text: iosContentsJson() });
  files.push({
    rel: 'README.txt',
    kind: 'text',
    text: [
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
      '',
    ].join('\n'),
  });
  return files;
}

export function harmonyPlan(bgHex: string): OutFile[] {
  const files: OutFile[] = [];
  const png = (
    rel: string,
    size: number,
    fit: Fit,
    flatten: boolean,
    note: string,
    safeScale?: number,
  ) =>
    files.push({
      rel,
      kind: 'png',
      job: { rel, size, fit, flatten, safeScale, note },
    });

  png('media/foreground.png', 1024, 'safe', false, '分层图标前景层 1024x1024 (主体缩进中央安全区)', SAFE);
  png('media/background.png', 1024, 'cover', true, `分层图标背景层 1024x1024 (纯色 ${bgHex}, 不透明, 审核硬性要求)`);
  png('agc-store-216.png', 216, 'cover', true, 'AppGallery 上架展示图标 216x216, PNG<=500KB');
  png('agc-store-1024.png', 1024, 'cover', true, 'AppGallery 上架展示图标 1024x1024 (备用)');

  files.push({
    rel: 'media/layered_image.json',
    kind: 'text',
    text:
      JSON.stringify(
        {
          'layered-image': {
            background: '$media:background',
            foreground: '$media:foreground',
          },
        },
        null,
        2,
      ) + '\n',
  });

  files.push({
    rel: 'README.txt',
    kind: 'text',
    text: [
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
      '',
    ].join('\n'),
  });
  return files;
}

export function buildPlan(plat: Plat, bgHex: string): OutFile[] {
  if (plat === 'android') return androidPlan(bgHex);
  if (plat === 'ios') return iosPlan();
  return harmonyPlan(bgHex);
}

export function planPngCount(plan: OutFile[]): number {
  return plan.filter((f) => f.kind === 'png').length;
}
