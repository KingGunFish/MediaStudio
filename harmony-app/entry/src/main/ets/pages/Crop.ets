// pages/Crop.ets - 图片裁剪 (C5).
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Crop.tsx: the
// width / height define an output canvas, the image is a layer that can be
// panned and zoomed (drag / pinch / buttons, Photoshop style), and
// "开始裁剪" bakes the visible composition into a new image file.
//
// The geometry comes from the shared, unmodified
// electron-app/src/renderer/src/lib/cropMath.ts, ported to
// harmony-app/entry/src/main/ets/common/CropMath.ets. The Windows build draws
// with the browser canvas; here the same composition is resampled in ArkTS
// (bilinear on premultiplied pixels) and encoded by common/Png.ets or by the
// platform image packer for JPEG / WebP.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pickAndStage, outputPath } from '../common/FilePicker';
import {
  decodeImage,
  drawScaledRgba,
  encodeWithImageKit,
  parseHexColor,
  writeFileBytes
} from '../common/ImageIo';
import { encodePngRgb, encodePngRgba } from '../common/Png';
import { clampZoom, fitTransform, Transform, zoomAt } from '../common/CropMath';

const TAG: string = 'MsVerify';

const MAX_DIM: number = 8192;
// Logical viewport of the preview, in vp.
const VIEW_W: number = 640;
const VIEW_H: number = 400;

@Component
export struct CropPage {
  @State inputPath: string = '';
  @State srcName: string = '';
  @State origW: number = 0;
  @State origH: number = 0;

  @State wStr: string = '';
  @State hStr: string = '';
  @State outW: number = 0;
  @State outH: number = 0;

  // The transform. 'zoom' is canvas pixels per source pixel (1 = 100%).
  @State zoom: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;

  @State format: string = 'png';
  @State transparent: boolean = false;
  @State bgHex: string = '#ffffff';

  @State busy: boolean = false;
  @State failed: boolean = false;
  @State status: string = '';
  @State previewUri: string = '';

  private pixels: Uint8Array = new Uint8Array(0);
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  private pinchBaseZoom: number = 1;
  private pinchBaseX: number = 0;
  private pinchBaseY: number = 0;

  private formatOptions: SelectOption[] = [
    { value: 'PNG (支持透明)' },
    { value: 'JPG (体积小, 自动压平)' },
    { value: 'WebP (支持透明, 体积更小)' }
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
    const cut = path.lastIndexOf('/');
    const base = cut >= 0 ? path.substring(cut + 1) : path;
    this.srcName = base;
    try {
      const img = await decodeImage(path);
      this.pixels = img.data;
      this.origW = img.width;
      this.origH = img.height;
      this.wStr = img.width.toString();
      this.hStr = img.height.toString();
      this.outW = img.width;
      this.outH = img.height;
      this.fitToCanvas();
      // The format of the source is the default, gif/bmp have no encoder here.
      const dot = base.lastIndexOf('.');
      const ext = dot >= 0 ? base.substring(dot + 1).toLowerCase() : '';
      this.format = ext === 'jpg' || ext === 'jpeg' ? 'jpg' : (ext === 'webp' ? 'webp' : 'png');
      this.previewUri = 'file://' + path;
      this.status = '已加载 ' + img.width + ' x ' + img.height + ' — 拖拽移动图片, 双指缩放';
    } catch (e) {
      this.failed = true;
      this.status = '无法解码图片: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'crop decode failed: %{public}s', JSON.stringify(e));
    }
  }

  /** Reads the width / height inputs and rebuilds the canvas. */
  private applyCanvas(): void {
    const w = parseInt(this.wStr);
    const h = parseInt(this.hStr);
    if (isNaN(w) || isNaN(h) || w < 1 || h < 1) {
      this.failed = true;
      this.status = '请输入有效的宽度和高度 (>=1)';
      return;
    }
    if (w > MAX_DIM || h > MAX_DIM) {
      this.failed = true;
      this.status = '宽高不能超过 ' + MAX_DIM + 'px';
      return;
    }
    this.outW = w;
    this.outH = h;
    this.fitToCanvas();
    this.failed = false;
    this.status = '画布已调整为 ' + w + ' x ' + h;
  }

  /** Centres the image inside the canvas and fits it completely. */
  private fitToCanvas(): void {
    if (this.outW < 1 || this.outH < 1 || this.origW < 1 || this.origH < 1) {
      return;
    }
    const t: Transform = fitTransform(this.origW, this.origH, this.outW, this.outH, 'fit');
    this.zoom = t.scale;
    this.panX = t.x;
    this.panY = t.y;
  }

  private zoomCenter(factor: number): void {
    if (this.outW < 1 || this.outH < 1) {
      return;
    }
    const t: Transform = zoomAt(
      { scale: this.zoom, x: this.panX, y: this.panY }, this.outW / 2, this.outH / 2, factor);
    this.zoom = t.scale;
    this.panX = t.x;
    this.panY = t.y;
  }

  private async crop(): Promise<void> {
    const w = parseInt(this.wStr);
    const h = parseInt(this.hStr);
    if (isNaN(w) || isNaN(h) || w < 1 || h < 1) {
      this.failed = true;
      this.status = '请输入有效的宽度和高度 (>=1)';
      return;
    }
    if (w > MAX_DIM || h > MAX_DIM) {
      this.failed = true;
      this.status = '宽高不能超过 ' + MAX_DIM + 'px';
      return;
    }
    if (this.pixels.length === 0) {
      return;
    }
    this.busy = true;
    this.failed = false;
    this.status = '裁剪中...';
    try {
      const rgb = parseHexColor(this.bgHex);
      const keepAlpha = this.transparent && this.format !== 'jpg';
      const out = drawScaledRgba(w, h, this.pixels, this.origW, this.origH,
        this.zoom, this.panX, this.panY, rgb[0], rgb[1], rgb[2], keepAlpha ? 0 : 255);

      let bytes: Uint8Array;
      if (this.format === 'jpg') {
        bytes = await encodeWithImageKit(out, w, h, 'image/jpeg', 92);
      } else if (this.format === 'webp') {
        bytes = await encodeWithImageKit(out, w, h, 'image/webp', 92);
      } else {
        bytes = keepAlpha ? encodePngRgba(w, h, out) : encodePngRgb(w, h, out);
      }

      const dot = this.srcName.lastIndexOf('.');
      const stem = dot > 0 ? this.srcName.substring(0, dot) : (this.srcName.length > 0 ? this.srcName : 'image');
      const path = outputPath(this.ctx(), stem + '_crop_' + w + 'x' + h + '.' + this.format);
      if (!writeFileBytes(path, bytes)) {
        throw new Error('写入失败: ' + path);
      }
      this.outW = w;
      this.outH = h;
      this.status = '已裁剪: ' + path + ' (' + (bytes.length / 1024).toFixed(1) + 'KB)';
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'crop failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  // ---- preview geometry -------------------------------------------------

  /** Canvas pixels per preview vp. */
  private viewScale(): number {
    if (this.outW < 1 || this.outH < 1) {
      return 1;
    }
    return Math.min((VIEW_W - 24) / this.outW, (VIEW_H - 24) / this.outH);
  }

  /** Left edge of the crop rectangle inside the preview, in vp. */
  private originX(): number {
    return (VIEW_W - this.outW * this.viewScale()) / 2;
  }

  /** Top edge of the crop rectangle inside the preview, in vp. */
  private originY(): number {
    return (VIEW_H - this.outH * this.viewScale()) / 2;
  }

  /** Width of the crop rectangle inside the preview, in vp. */
  private cropW(): number {
    return this.outW * this.viewScale();
  }

  /** Height of the crop rectangle inside the preview, in vp. */
  private cropH(): number {
    return this.outH * this.viewScale();
  }

  /** Left edge of the image inside the preview, in vp. */
  private imageX(): number {
    return this.originX() + this.panX * this.viewScale();
  }

  /** Top edge of the image inside the preview, in vp. */
  private imageY(): number {
    return this.originY() + this.panY * this.viewScale();
  }

  /** Width of the image inside the preview, in vp. */
  private imageW(): number {
    return this.origW * this.zoom * this.viewScale();
  }

  /** Height of the image inside the preview, in vp. */
  private imageH(): number {
    return this.origH * this.zoom * this.viewScale();
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('图片裁剪').fontSize(22).fontWeight(FontWeight.Bold)
            Text('自定义画布裁剪：输入宽高建立画布，拖拽/缩放摆放图片，按当前画面输出新图')
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
            Text('支持 .png .jpg .bmp .gif（取首帧）· .webp')
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
              '　·　画布 ' + this.outW + ' × ' + this.outH)
              .fontSize(12).fontColor('#5b6472')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Row({ space: 8 }) {
            Text('宽').fontSize(13).width(22)
            TextInput({ text: this.wStr, placeholder: '宽度' })
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string) => { this.wStr = value; })
            Text('高').fontSize(13).width(22)
            TextInput({ text: this.hStr, placeholder: '高度' })
              .type(InputType.Number)
              .layoutWeight(1)
              .onChange((value: string) => { this.hStr = value; })
            Button('调整')
              .fontSize(13)
              .onClick(() => { this.applyCanvas(); })
              .enabled(!this.busy && this.origW > 0)
          }
          .width('100%')

          Row({ space: 8 }) {
            Button('⊕')
              .fontSize(15)
              .width(44)
              .onClick(() => { this.zoomCenter(1.25); })
              .enabled(this.outW > 0)
            Button('⊖')
              .fontSize(15)
              .width(44)
              .onClick(() => { this.zoomCenter(0.8); })
              .enabled(this.outW > 0)
            Text(Math.round(this.zoom * 100) + '%').fontSize(13).width(64)
            Button('适应')
              .fontSize(13)
              .layoutWeight(1)
              .onClick(() => { this.fitToCanvas(); })
              .enabled(this.outW > 0)
            Button(this.busy ? '裁剪中...' : '开始裁剪')
              .fontSize(13)
              .layoutWeight(1)
              .backgroundColor('#2f6fed')
              .onClick(() => { this.crop(); })
              .enabled(!this.busy && this.outW > 0)
          }
          .width('100%')

          Column({ space: 10 }) {
            Text('输出设置').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text('格式').fontSize(13).width(52)
              Select(this.formatOptions)
                .selected(this.format === 'jpg' ? 1 : (this.format === 'webp' ? 2 : 0))
                .value(this.formatLabel())
                .layoutWeight(1)
                .onSelect((index: number) => {
                  this.format = index === 1 ? 'jpg' : (index === 2 ? 'webp' : 'png');
                })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('透明背景').fontSize(13).width(70)
              Toggle({ type: ToggleType.Switch, isOn: this.transparent })
                .enabled(this.format !== 'jpg')
                .onChange((value: boolean) => { this.transparent = value; })
              Text('（仅 PNG / WebP）').fontSize(12).fontColor('#8a93a0')
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('背景色').fontSize(13).width(70)
              TextInput({ text: this.bgHex, placeholder: '#ffffff' })
                .layoutWeight(1)
                .enabled(!this.transparent || this.format === 'jpg')
                .onChange((value: string) => { this.bgHex = value; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Stack({ alignContent: Alignment.TopStart }) {
            // The crop canvas itself.
            Column()
              .width(this.cropW())
              .height(this.cropH())
              .position({ x: this.originX(), y: this.originY() })
              .backgroundColor(this.transparent && this.format !== 'jpg' ? '#141a22' : this.bgHex)

            // The image layer.
            if (this.previewUri.length > 0) {
              Image(this.previewUri)
                .width(this.imageW())
                .height(this.imageH())
                .objectFit(ImageFit.Fill)
                .position({ x: this.imageX(), y: this.imageY() })
            }

            // Everything outside the crop rectangle is dimmed.
            Column()
              .width(VIEW_W)
              .height(this.originY())
              .position({ x: 0, y: 0 })
              .backgroundColor('#9E080C12')
            Column()
              .width(VIEW_W)
              .height(Math.max(0, VIEW_H - this.originY() - this.cropH()))
              .position({ x: 0, y: this.originY() + this.cropH() })
              .backgroundColor('#9E080C12')
            Column()
              .width(Math.max(0, this.originX()))
              .height(this.cropH())
              .position({ x: 0, y: this.originY() })
              .backgroundColor('#9E080C12')
            Column()
              .width(Math.max(0, VIEW_W - this.originX() - this.cropW()))
              .height(this.cropH())
              .position({ x: this.originX() + this.cropW(), y: this.originY() })
              .backgroundColor('#9E080C12')

            // Rule of thirds guides.
            Column()
              .width(1)
              .height(this.cropH())
              .position({ x: this.originX() + this.cropW() / 3, y: this.originY() })
              .backgroundColor('#55FFFFFF')
            Column()
              .width(1)
              .height(this.cropH())
              .position({ x: this.originX() + this.cropW() * 2 / 3, y: this.originY() })
              .backgroundColor('#55FFFFFF')
            Column()
              .width(this.cropW())
              .height(1)
              .position({ x: this.originX(), y: this.originY() + this.cropH() / 3 })
              .backgroundColor('#55FFFFFF')
            Column()
              .width(this.cropW())
              .height(1)
              .position({ x: this.originX(), y: this.originY() + this.cropH() * 2 / 3 })
              .backgroundColor('#55FFFFFF')

            // The crop bounds.
            Column()
              .width(this.cropW())
              .height(this.cropH())
              .position({ x: this.originX(), y: this.originY() })
              .border({ width: 1, color: '#4d9fff' })
          }
          .width(VIEW_W)
          .height(VIEW_H)
          .backgroundColor('#0d1117')
          .borderRadius(8)
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PanGesture({ fingers: 1, direction: PanDirection.All })
                .onActionStart(() => {
                  this.panBaseX = this.panX;
                  this.panBaseY = this.panY;
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.panX = this.panBaseX + event.offsetX / this.viewScale();
                  this.panY = this.panBaseY + event.offsetY / this.viewScale();
                }),
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.pinchBaseZoom = this.zoom;
                  this.pinchBaseX = this.panX;
                  this.pinchBaseY = this.panY;
                })
                .onActionUpdate((event: PinchGestureEvent) => {
                  const next = clampZoom(this.pinchBaseZoom * event.scale);
                  const k = next / this.pinchBaseZoom;
                  const cx = (event.pinchCenterX - this.originX()) / this.viewScale();
                  const cy = (event.pinchCenterY - this.originY()) / this.viewScale();
                  this.zoom = next;
                  this.panX = cx - (cx - this.pinchBaseX) * k;
                  this.panY = cy - (cy - this.pinchBaseY) * k;
                })
            )
          )
          .align(Alignment.TopStart)

          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(13)
              .fontColor(this.failed ? '#c0392b' : '#1e7f4f')
              .width('100%')
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

  private formatLabel(): string {
    if (this.format === 'jpg') {
      return 'JPG (体积小, 自动压平)';
    }
    if (this.format === 'webp') {
      return 'WebP (支持透明, 体积更小)';
    }
    return 'PNG (支持透明)';
  }
}
