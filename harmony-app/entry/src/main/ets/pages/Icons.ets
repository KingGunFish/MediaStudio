// pages/Icons.ets - 应用图标生成 (C6).
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Icons.tsx: one
// input image produces every store / launcher icon the selected platform
// needs, written into a per-platform folder.
//
// The file plan comes from the shared, unmodified
// electron-app/src/renderer/src/lib/appicons.ts, ported to
// harmony-app/entry/src/main/ets/common/AppIcons.ets. The pixels are scaled
// by ImageKit and encoded by common/Png.ets.
//
// The Windows build draws with the browser canvas, which scales with a
// high quality filter and supports source-over blending. Here the fit is
// computed up front (ImageKit scales to an exact size, it does not keep the
// aspect ratio) and the blending is done on the raw pixels, so the result is
// the same composition with a slightly different resampling kernel.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pickAndStage } from '../common/FilePicker';
import {
  composeRgba,
  cropRgba,
  decodeBytes,
  ensureDir,
  flattenRgba,
  parseHexColor,
  probeSize,
  readFileBytes,
  writeFileBytes,
  writeTextFile
} from '../common/ImageIo';
import { encodePngRgb, encodePngRgba } from '../common/Png';
import {
  buildPlan,
  IconJob,
  OutFile,
  Plat,
  platDir,
  platLabel,
  planPngCount
} from '../common/AppIcons';

const TAG: string = 'MsVerify';

@Component
export struct IconsPage {
  @State inputPath: string = '';
  @State srcName: string = '';
  @State origW: number = 0;
  @State origH: number = 0;
  @State outRoot: string = '';

  @State plat: Plat = 'android';
  @State androidBg: string = '#ffffff';
  @State iosBg: string = '#ffffff';
  @State harmonyBg: string = '#ffffff';

  @State busy: boolean = false;
  @State failed: boolean = false;
  @State status: string = '';
  @State lines: string[] = [];
  @State previewUri: string = '';
  @State previewTick: number = 0;

  private sourceBytes: ArrayBuffer = new ArrayBuffer(0);
  private platOptions: SelectOption[] = [
    { value: 'Android' },
    { value: 'iOS' },
    { value: 'HarmonyOS' }
  ];

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** The background colour of the platform that is currently selected. */
  private bgHex(): string {
    if (this.plat === 'android') {
      return this.androidBg;
    }
    if (this.plat === 'ios') {
      return this.iosBg;
    }
    return this.harmonyBg;
  }

  private setBgHex(value: string): void {
    if (this.plat === 'android') {
      this.androidBg = value;
    } else if (this.plat === 'ios') {
      this.iosBg = value;
    } else {
      this.harmonyBg = value;
    }
  }

  private async pick(): Promise<void> {
    const path = await pickAndStage(this.ctx(), ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp']);
    if (!path) {
      return;
    }
    this.inputPath = path;
    this.status = '读取图片中...';
    this.failed = false;
    this.lines = [];
    const cut = path.lastIndexOf('/');
    const base = cut >= 0 ? path.substring(cut + 1) : path;
    this.srcName = base;
    try {
      const bytes = readFileBytes(path);
      const size = await probeSize(bytes);
      this.sourceBytes = bytes;
      this.origW = size[0];
      this.origH = size[1];
      const dot = base.lastIndexOf('.');
      const stem = dot > 0 ? base.substring(0, dot) : base;
      this.outRoot = this.ctx().filesDir + '/' + stem + '_icons';
      this.status = '已加载: ' + this.origW + ' x ' + this.origH + ', 建议输入 1024x1024 或更大';
      await this.renderPreview();
    } catch (e) {
      this.failed = true;
      this.status = '无法解码图片: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'icons decode failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Renders one icon job.
   *
   * 'cover' scales the source so that it fills the square and then center
   * crops it; 'safe' scales it into the centre box and leaves the rest
   * transparent; 'solid' paints the background colour only, which is what
   * the store guidelines ask for from a layered background layer.
   * A flattened job composites the result onto the background colour and is
   * written as a 24 bit RGB PNG (no alpha channel at all).
   */
  private async renderJob(job: IconJob, bgHex: string): Promise<Uint8Array> {
    const n = job.size;
    const sw = this.origW;
    const sh = this.origH;
    let pixels: Uint8Array;

    if (job.fit === 'solid') {
      const rgb = parseHexColor(bgHex);
      pixels = composeRgba(n, n, new Uint8Array(0), 0, 0, 0, 0, 0, rgb[0], rgb[1], rgb[2], 255);
    } else if (job.fit === 'cover') {
      const k = Math.max(n / sw, n / sh);
      const dw = Math.max(n, Math.round(sw * k));
      const dh = Math.max(n, Math.round(sh * k));
      const scaled = await decodeBytes(this.sourceBytes, dw, dh);
      const ox = Math.floor((dw - n) / 2);
      const oy = Math.floor((dh - n) / 2);
      pixels = cropRgba(scaled.data, dw, ox, oy, n, n);
    } else {
      const frac = job.safeScale > 0 ? job.safeScale : 1;
      const box = n * frac;
      const k = Math.min(box / sw, box / sh);
      const dw = Math.max(1, Math.round(sw * k));
      const dh = Math.max(1, Math.round(sh * k));
      const scaled = await decodeBytes(this.sourceBytes, dw, dh);
      pixels = composeRgba(n, n, scaled.data, dw, Math.floor((n - dw) / 2),
        Math.floor((n - dh) / 2), dw, dh, 0, 0, 0, 0);
    }

    if (job.flatten) {
      const rgb = parseHexColor(bgHex);
      return encodePngRgb(n, n, flattenRgba(pixels, rgb[0], rgb[1], rgb[2]));
    }
    return encodePngRgba(n, n, pixels);
  }

  /**
   * The preview the Windows build draws on a 128x128 canvas: iOS shows the
   * flattened square, the other platforms show a circular mask with the
   * foreground scaled into the safe zone.
   */
  private async renderPreview(): Promise<void> {
    if (this.origW < 1 || this.origH < 1) {
      return;
    }
    const n = 128;
    const rgb = parseHexColor(this.bgHex());
    let pixels: Uint8Array;

    if (this.plat === 'ios') {
      const k = Math.max(n / this.origW, n / this.origH);
      const dw = Math.max(n, Math.round(this.origW * k));
      const dh = Math.max(n, Math.round(this.origH * k));
      const scaled = await decodeBytes(this.sourceBytes, dw, dh);
      const cropped = cropRgba(scaled.data, dw, Math.floor((dw - n) / 2),
        Math.floor((dh - n) / 2), n, n);
      pixels = flattenRgba(cropped, rgb[0], rgb[1], rgb[2]);
    } else {
      const box = n * (2 / 3);
      const k = Math.min(box / this.origW, box / this.origH);
      const dw = Math.max(1, Math.round(this.origW * k));
      const dh = Math.max(1, Math.round(this.origH * k));
      const scaled = await decodeBytes(this.sourceBytes, dw, dh);
      const composed = composeRgba(n, n, scaled.data, dw, Math.floor((n - dw) / 2),
        Math.floor((n - dh) / 2), dw, dh, 0, 0, 0, 0);
      pixels = new Uint8Array(n * n * 4);
      const radius = n * 0.46;
      const cx = n / 2;
      const cy = n / 2;
      for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
          const dx = x + 0.5 - cx;
          const dy = y + 0.5 - cy;
          const idx = (y * n + x) * 4;
          if (dx * dx + dy * dy <= radius * radius) {
            const a = composed[idx + 3] / 255;
            pixels[idx] = Math.round(composed[idx] * a + rgb[0] * (1 - a));
            pixels[idx + 1] = Math.round(composed[idx + 1] * a + rgb[1] * (1 - a));
            pixels[idx + 2] = Math.round(composed[idx + 2] * a + rgb[2] * (1 - a));
            pixels[idx + 3] = 255;
          }
        }
      }
    }

    const previewPath = this.ctx().filesDir + '/media_studio_icon_preview.png';
    if (!writeFileBytes(previewPath, encodePngRgba(n, n, pixels))) {
      return;
    }
    this.previewTick = Date.now();
    this.previewUri = 'file://' + previewPath + '?v=' + this.previewTick;
  }

  private async generate(): Promise<void> {
    if (this.origW < 1 || this.sourceBytes.byteLength === 0) {
      return;
    }
    this.busy = true;
    this.failed = false;
    this.lines = [];
    this.status = '生成图标中...';
    try {
      const bgHex = this.bgHex();
      const plan: OutFile[] = buildPlan(this.plat, bgHex);
      const folder = this.outRoot + '/' + platDir(this.plat);
      const lines: string[] = [];
      for (const file of plan) {
        const path = folder + '/' + file.rel;
        const slash = path.lastIndexOf('/');
        if (slash > 0 && !ensureDir(path.substring(0, slash))) {
          throw new Error('无法创建目录: ' + path.substring(0, slash));
        }
        if (file.kind === 'text') {
          if (!writeTextFile(path, file.text)) {
            throw new Error(path + ': 写入失败');
          }
          lines.push('[配置] ' + file.rel);
        } else {
          const bytes = await this.renderJob(file.job, bgHex);
          if (!writeFileBytes(path, bytes)) {
            throw new Error(path + ': 写入失败');
          }
          lines.push('[' + (bytes.length / 1024).toFixed(1) + 'KB] ' + file.rel +
            ' — ' + file.job.note);
        }
      }
      this.lines = lines;
      this.status = '已生成 ' + plan.length + ' 个文件到: ' + folder;
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'icons generate failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('应用图标生成').fontSize(22).fontWeight(FontWeight.Bold)
            Text('一张图生成 Android / iOS / HarmonyOS 上架所需的全套图标，按平台分文件夹输出')
              .fontSize(12).fontColor('#5b6472')
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Button(this.inputPath.length > 0 ? '重选' : '选择图片')
            .onClick(() => { this.pick(); })
            .enabled(!this.busy)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.inputPath.length === 0) {
          Column({ space: 6 }) {
            Text('尚未选择图片').fontSize(15).fontColor('#5b6472')
            Text('支持 .png .jpg .webp .gif（取首帧）· 建议 1024x1024 以上')
              .fontSize(12).fontColor('#8a93a0')
          }
          .width('100%')
          .padding(28)
          .backgroundColor('#f2f4f7')
          .borderRadius(12)
        } else {
          Column({ space: 6 }) {
            Text('输入').fontSize(12).fontColor('#5b6472')
            Text(this.inputPath).fontSize(12).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('原始尺寸 ' + this.origW + ' × ' + this.origH)
              .fontSize(12).fontColor('#5b6472')
            Text('输出根目录').fontSize(12).fontColor('#5b6472')
            Text(this.outRoot).fontSize(12).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Row({ space: 8 }) {
            ForEach(this.platOptions, (option: SelectOption, index: number) => {
              Button(option.value)
                .layoutWeight(1)
                .fontSize(13)
                .backgroundColor(this.platIndex() === index ? '#2f6fed' : '#e8ebf0')
                .fontColor(this.platIndex() === index ? '#ffffff' : '#1d2430')
                .onClick(() => {
                  const next: Plat = index === 0 ? 'android' : (index === 1 ? 'ios' : 'harmony');
                  if (next !== this.plat) {
                    this.plat = next;
                    this.renderPreview();
                  }
                })
            }, (option: SelectOption) => option.value.toString())
          }
          .width('100%')

          Column({ space: 10 }) {
            Text(platLabel(this.plat) + ' 输出设置').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text(this.plat === 'ios' ? '压平背景色' : '背景层颜色').fontSize(13).width(96)
              TextInput({ text: this.bgHex(), placeholder: '#ffffff' })
                .layoutWeight(1)
                .onChange((value: string) => { this.setBgHex(value); })
            }
            .width('100%')
            Text(this.bgTip()).fontSize(12).fontColor('#5b6472')
            Text('将生成: ' + planPngCount(buildPlan(this.plat, this.bgHex())) + ' 个 PNG + ' +
              (buildPlan(this.plat, this.bgHex()).length -
                planPngCount(buildPlan(this.plat, this.bgHex()))) + ' 个配置/说明文件')
              .fontSize(12).fontColor('#5b6472')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          if (this.previewUri.length > 0) {
            Column({ space: 6 }) {
              Image(this.previewUri)
                .width(128)
                .height(128)
                .objectFit(ImageFit.Contain)
                .backgroundColor('#f2f4f7')
                .borderRadius(8)
              Text(this.plat === 'ios' ? '压平效果 (无透明，系统自动加圆角)' : '圆形蒙版模拟 (主体在中央 2/3 安全区)')
                .fontSize(11).fontColor('#5b6472')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          Button(this.busy ? '生成中...' : '生成 ' + platLabel(this.plat) + ' 图标')
            .width('100%')
            .enabled(!this.busy && this.origW > 0)
            .onClick(() => { this.generate(); })

          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(13)
              .fontColor(this.failed ? '#c0392b' : '#1e7f4f')
              .width('100%')
          }

          if (this.lines.length > 0) {
            Column({ space: 4 }) {
              Text('输出目录: ' + this.outRoot + '/' + platDir(this.plat))
                .fontSize(12).fontColor('#5b6472')
              Scroll() {
                Column({ space: 2 }) {
                  ForEach(this.lines, (line: string) => {
                    Text(line).fontSize(11).fontFamily('monospace').width('100%')
                  }, (line: string) => line)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .height(240)
              .align(Alignment.TopStart)
              .backgroundColor('#1d2430')
              .borderRadius(8)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
    }
    .width('100%')
    .height('100%')
    // Scroll centres its content by default; the page has to start at the top.
    .align(Alignment.TopStart)
  }

  /** The index of the selected platform tab. */
  private platIndex(): number {
    if (this.plat === 'android') {
      return 0;
    }
    if (this.plat === 'ios') {
      return 1;
    }
    return 2;
  }

  private bgTip(): string {
    if (this.plat === 'ios') {
      return 'iOS 图标不允许透明 (审核 ITMS-90717)，所有尺寸都会按此颜色压平为不透明 RGB PNG';
    }
    if (this.plat === 'android') {
      return '自适应图标背景层颜色 (不透明纯色)；商店图标中需要压平的也使用此色';
    }
    return '鸿蒙分层图标背景层颜色 (审核硬性要求: 背景层不允许透明)';
  }
}
