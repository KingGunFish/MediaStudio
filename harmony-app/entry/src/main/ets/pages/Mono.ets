// pages/Mono.ets - 图片转 1 位黑白.
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Mono.tsx:
// pick an image, the 1-bit BMP is produced (and kept up to date) automatically,
// and the Img2Lcd style C array / bin can be exported on top of it.
//
// The pixel maths is the shared, unmodified electron-app/src/renderer/src/lib/
// mono1bpp.ts, ported to harmony-app/entry/src/main/ets/common/Mono1bpp.ets.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pickAndStage, outputPath } from '../common/FilePicker';
import { decodeImage, writeFileBytes, writeTextFile } from '../common/ImageIo';
import {
  binarize,
  buildBmp1bpp,
  buildArrayOutput,
  cVarName,
  MonoMode,
  ScanMode,
  MonoOptions
} from '../common/Mono1bpp';

const TAG: string = 'MsVerify';

@Component
export struct MonoPage {
  @State inputPath: string = '';
  @State srcName: string = '';
  @State origW: number = 0;
  @State origH: number = 0;
  @State outW: number = 0;
  @State outH: number = 0;
  @State lockAspect: boolean = true;

  @State mode: MonoMode = 'dither';
  @State threshold: number = 128;
  @State inverted: boolean = false;
  @State scan: ScanMode = 'horizontal';
  @State withHeader: boolean = false;
  @State wantBin: boolean = false;

  @State busy: boolean = false;
  @State status: string = '';
  @State failed: boolean = false;
  @State bmpPath: string = '';
  @State previewUri: string = '';
  @State arrayText: string = '';
  @State arrayPath: string = '';
  @State pixelReady: boolean = false;

  private timer: number = -1;
  private px: Uint8Array = new Uint8Array(0);
  private modeOptions: SelectOption[] = [
    { value: '抖动 (适合照片)' },
    { value: '阈值 (适合线条图/文字)' }
  ];
  private scanOptions: SelectOption[] = [
    { value: '水平扫描 (每字节 8 个横向像素)' },
    { value: '垂直扫描 (每字节 8 个纵向像素)' }
  ];

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async pick(): Promise<void> {
    const path = await pickAndStage(this.ctx(), ['.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp']);
    if (!path) {
      return;
    }
    this.inputPath = path;
    this.status = '读取图片中...';
    this.failed = false;
    this.arrayText = '';
    this.arrayPath = '';
    this.px = new Uint8Array(0);
    this.pixelReady = false;
    const cut = path.lastIndexOf('/');
    const base = cut >= 0 ? path.substring(cut + 1) : path;
    this.srcName = base;
    try {
      const img = await decodeImage(path);
      this.origW = img.width;
      this.origH = img.height;
      this.outW = img.width;
      this.outH = img.height;
      this.bmpPath = outputPath(this.ctx(), 'media_studio_mono.bmp');
      this.status = '已加载: ' + img.width + ' x ' + img.height + ', BMP 正在生成...';
      this.recompute();
    } catch (e) {
      this.failed = true;
      this.status = '无法解码图片: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'mono decode failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Decodes the source at the requested size, binarizes it and writes the BMP.
   * The Windows page debounces this because the threshold slider fires rapidly.
   */
  private scheduleRecompute(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.recompute();
    }, 300);
  }

  private async recompute(): Promise<void> {
    if (!this.inputPath || this.outW < 1 || this.outH < 1) {
      return;
    }
    try {
      const img = await decodeImage(this.inputPath, this.outW, this.outH);
      const px = binarize(img.width, img.height, img.data, this.mode, this.threshold, this.inverted);
      this.px = px;
      this.pixelReady = true;
      const bmp = buildBmp1bpp(img.width, img.height, px);
      if (!writeFileBytes(this.bmpPath, bmp)) {
        this.failed = true;
        this.status = 'BMP 写入失败: ' + this.bmpPath;
        return;
      }
      // The counter keeps the URI unique so that the preview is not served
      // from the image cache after the file was rewritten.
      this.previewUri = 'file://' + this.bmpPath + '?v=' + Date.now();
      this.failed = false;
      this.status = 'BMP 已更新: ' + img.width + ' x ' + img.height + ', ' +
        (bmp.length / 1024).toFixed(1) + ' KB';
    } catch (e) {
      this.failed = true;
      this.status = '生成失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'mono recompute failed: %{public}s', JSON.stringify(e));
    }
  }

  private onWidthChanged(text: string): void {
    const w = parseInt(text);
    if (isNaN(w) || w <= 0) {
      return;
    }
    this.outW = w;
    if (this.lockAspect && this.origW > 0) {
      this.outH = Math.max(1, Math.round(w * this.origH / this.origW));
    }
    this.scheduleRecompute();
  }

  private onHeightChanged(text: string): void {
    const h = parseInt(text);
    if (isNaN(h) || h <= 0) {
      return;
    }
    this.outH = h;
    if (this.lockAspect && this.origH > 0) {
      this.outW = Math.max(1, Math.round(h * this.origW / this.origH));
    }
    this.scheduleRecompute();
  }

  private async generateArray(): Promise<void> {
    if (this.px.length === 0 || !this.bmpPath) {
      return;
    }
    this.busy = true;
    this.status = '生成数组中...';
    try {
      const base = this.bmpPath.substring(0, this.bmpPath.lastIndexOf('.'));
      const opts: MonoOptions = {
        mode: this.mode,
        threshold: this.threshold,
        invert: this.inverted,
        scan: this.scan,
        withHeader: this.withHeader
      };
      const name = this.srcName.length > 0 ? this.srcName : 'image';
      const out = buildArrayOutput(cVarName(name), name, this.outW, this.outH, this.px, opts);

      const cPath = base + '.c';
      if (!writeTextFile(cPath, out.cSource)) {
        throw new Error('C 数组写入失败: ' + cPath);
      }
      const written: string[] = ['C 数组: ' + cPath];
      if (this.wantBin) {
        const binPath = base + '.bin';
        if (!writeFileBytes(binPath, out.bin)) {
          throw new Error('BIN 写入失败: ' + binPath);
        }
        written.push('BIN: ' + binPath);
      }
      this.arrayText = out.cSource;
      this.arrayPath = cPath;
      this.failed = false;
      this.status = '已生成: ' + written.join('  |  ');
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('图片转黑白').fontSize(22).fontWeight(FontWeight.Bold)
            Text('图片转 1 位黑白 BMP（选图后自动生成），并可生成墨水屏可用的 C 数组 / BIN')
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
            Text('支持 PNG / JPG / BMP / GIF（取首帧）/ WEBP')
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
            Text('原始尺寸 ' + this.origW + ' × ' + this.origH +
              '　·　输出 ' + this.outW + ' × ' + this.outH)
              .fontSize(12).fontColor('#5b6472')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Column({ space: 10 }) {
            Text('输出尺寸').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text('宽度').fontSize(13).width(52)
              TextInput({ text: this.outW.toString(), placeholder: '160' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.onWidthChanged(v); })
              Text('高度').fontSize(13).width(52)
              TextInput({ text: this.outH.toString(), placeholder: '120' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.onHeightChanged(v); })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('锁定比例').fontSize(13).width(70)
              Toggle({ type: ToggleType.Switch, isOn: this.lockAspect })
                .onChange((v: boolean) => { this.lockAspect = v; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Column({ space: 10 }) {
            Text('二值化').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text('方式').fontSize(13).width(52)
              Select(this.modeOptions)
                .selected(this.mode === 'threshold' ? 1 : 0)
                .value(this.mode === 'threshold' ? '阈值 (适合线条图/文字)' : '抖动 (适合照片)')
                .layoutWeight(1)
                .onSelect((index: number) => {
                  this.mode = index === 1 ? 'threshold' : 'dither';
                  this.scheduleRecompute();
                })
            }
            .width('100%')
            if (this.mode === 'threshold') {
              Row({ space: 10 }) {
                Text('阈值').fontSize(13).width(52)
                Slider({ value: this.threshold, min: 1, max: 255, step: 1 })
                  .layoutWeight(1)
                  .onChange((v: number) => {
                    this.threshold = v;
                    this.scheduleRecompute();
                  })
                Text(this.threshold.toString()).fontSize(12).width(34)
              }
              .width('100%')
            }
            Row({ space: 10 }) {
              Text('反色 (黑白互换)').fontSize(13).width(120)
              Toggle({ type: ToggleType.Switch, isOn: this.inverted })
                .onChange((v: boolean) => {
                  this.inverted = v;
                  this.scheduleRecompute();
                })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Column({ space: 10 }) {
            Text('数组 / BIN 设置').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text('扫描方向').fontSize(13).width(70)
              Select(this.scanOptions)
                .selected(this.scan === 'vertical' ? 1 : 0)
                .value(this.scan === 'vertical' ? '垂直扫描 (每字节 8 个纵向像素)' : '水平扫描 (每字节 8 个横向像素)')
                .layoutWeight(1)
                .onSelect((index: number) => {
                  this.scan = index === 1 ? 'vertical' : 'horizontal';
                })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('包含头数据 (Img2Lcd 兼容)').fontSize(13).width(170)
              Toggle({ type: ToggleType.Switch, isOn: this.withHeader })
                .onChange((v: boolean) => { this.withHeader = v; })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('同时生成 .bin (烧录 Flash 用)').fontSize(13).width(170)
              Toggle({ type: ToggleType.Switch, isOn: this.wantBin })
                .onChange((v: boolean) => { this.wantBin = v; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Button(this.busy ? '生成中...' : '生成数组')
            .width('100%')
            .enabled(!this.busy && this.pixelReady)
            .onClick(() => { this.generateArray(); })

          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(13)
              .fontColor(this.failed ? '#c0392b' : '#1e7f4f')
              .width('100%')
          }

          if (this.previewUri.length > 0) {
            Column({ space: 6 }) {
              Text('BMP 预览').fontSize(13).fontColor('#5b6472')
              Image(this.previewUri)
                .width('100%')
                .height(280)
                .objectFit(ImageFit.Contain)
                .backgroundColor('#202020')
                .borderRadius(8)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          if (this.arrayText.length > 0) {
            Column({ space: 6 }) {
              Text('C 数组: ' + this.arrayPath).fontSize(12).fontColor('#5b6472')
              Scroll() {
                Text(this.arrayText)
                  .fontSize(10)
                  .fontFamily('monospace')
                  .width('100%')
              }
              .width('100%')
              .height(220)
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
}
