// pages/VideoCrop.ets - 视频裁剪.
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/VideoCrop.tsx:
// the user drags and zooms the video inside a fixed size canvas and the
// export reproduces exactly that framing.
//
// The transform model is the one of cropMath.ts:
//   scale   source pixels per canvas pixel
//   x, y    the video's top-left corner, in canvas coordinates
// so a zoom of 100% means one source pixel covers one canvas pixel.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  MediaInfo,
  VideoCropOptions,
  probeMedia,
  convertVideoCrop,
  formatDuration
} from '../common/MediaApi';
import { pickAndStage, outputPath } from '../common/FilePicker';
import msverify from 'libmsverify.so';

const TAG: string = 'MsVerify';

interface RatioPreset {
  id: string;
  label: string;
  /** width / height, 0 = keep the source ratio */
  ratio: number;
}

@Component
export struct VideoCropPage {
  private presets: RatioPreset[] = [
    { id: 'source', label: '原始', ratio: 0 },
    { id: '1:1', label: '1:1', ratio: 1 },
    { id: '16:9', label: '16:9', ratio: 16 / 9 },
    { id: '9:16', label: '9:16', ratio: 9 / 16 },
    { id: '4:3', label: '4:3', ratio: 4 / 3 },
    { id: '3:4', label: '3:4', ratio: 3 / 4 }
  ];
  private swatches: string[] = ['#000000', '#ffffff', '#3a4250', '#c0392b', '#2f6fed'];

  @State inputPath: string = '';
  @State outputPath: string = '';
  @State info: MediaInfo | null = null;
  @State framePath: string = '';
  @State srcW: number = 0;
  @State srcH: number = 0;
  @State outW: number = 640;
  @State outH: number = 360;
  @State zoom: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State bgColor: string = '#000000';
  @State crf: number = 23;
  @State busy: boolean = false;
  @State progress: number = 0;
  @State message: string = '';
  @State status: string = '';
  @State failed: boolean = false;
  @State resultPath: string = '';

  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  private gestureStartScale: number = 1;

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** The preview box, in canvas pixels. */
  private canvasWidth(): number {
    return this.outW;
  }

  private canvasHeight(): number {
    return this.outH;
  }

  /** Display scale of the preview box on screen. */
  private viewScale(): number {
    const maxW = 420;
    const maxH = 260;
    return Math.min(maxW / this.outW, maxH / this.outH);
  }

  private clampTransform(): void {
    const vw = this.srcW * this.zoom;
    const vh = this.srcH * this.zoom;
    const visX = Math.min(2, vw, this.outW);
    const visY = Math.min(2, vh, this.outH);
    const xMin = Math.min(visX - vw, this.outW - visX);
    const xMax = Math.max(visX - vw, this.outW - visX);
    const yMin = Math.min(visY - vh, this.outH - visY);
    const yMax = Math.max(visY - vh, this.outH - visY);
    this.offsetX = Math.min(Math.max(this.offsetX, xMin), xMax);
    this.offsetY = Math.min(Math.max(this.offsetY, yMin), yMax);
  }

  /** fit: the whole video stays visible; fill: the video covers the canvas. */
  private applyFit(mode: string): void {
    if (this.srcW <= 0 || this.srcH <= 0) {
      return;
    }
    const sx = this.outW / this.srcW;
    const sy = this.outH / this.srcH;
    this.zoom = mode === 'fill' ? Math.max(sx, sy) : Math.min(sx, sy);
    this.offsetX = (this.outW - this.srcW * this.zoom) / 2;
    this.offsetY = (this.outH - this.srcH * this.zoom) / 2;
  }

  private applyPreset(preset: RatioPreset): void {
    if (this.srcW <= 0 || this.srcH <= 0) {
      return;
    }
    if (preset.ratio === 0) {
      this.outW = Math.max(2, Math.floor(this.srcW / 2) * 2);
      this.outH = Math.max(2, Math.floor(this.srcH / 2) * 2);
    } else {
      const srcRatio = this.srcW / this.srcH;
      if (srcRatio > preset.ratio) {
        this.outH = Math.max(2, Math.floor(this.srcH / 2) * 2);
        this.outW = Math.max(2, Math.floor(Math.round(this.srcH * preset.ratio) / 2) * 2);
      } else {
        this.outW = Math.max(2, Math.floor(this.srcW / 2) * 2);
        this.outH = Math.max(2, Math.floor(Math.round(this.srcW / preset.ratio) / 2) * 2);
      }
    }
    this.applyFit('fill');
  }

  private async pick(): Promise<void> {
    const path = await pickAndStage(this.ctx(), ['.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v']);
    if (!path) {
      return;
    }
    this.inputPath = path;
    this.status = '';
    this.failed = false;
    this.resultPath = '';
    try {
      const info = await probeMedia(path);
      if (!info.ok) {
        this.failed = true;
        this.status = '探测失败: ' + info.message;
        return;
      }
      this.info = info;
      this.srcW = info.width;
      this.srcH = info.height;
      this.outW = Math.max(2, Math.floor(info.width / 2) * 2);
      this.outH = Math.max(2, Math.floor(info.height / 2) * 2);

      const frame = msverify.decodeFirstFrame(path, outputPath(this.ctx(), 'preview_frame.png'));
      if (!frame.ok) {
        this.failed = true;
        this.status = '首帧解码失败: ' + frame.message;
        return;
      }
      this.framePath = 'file://' + frame.path;
      this.srcW = frame.width;
      this.srcH = frame.height;
      this.applyFit('fill');
      this.outputPath = outputPath(this.ctx(), 'media_studio_crop.avi');
      this.status = info.width + ' × ' + info.height + '　·　时长 ' +
        formatDuration(info.duration);
    } catch (e) {
      this.failed = true;
      this.status = '探测异常: ' + JSON.stringify(e);
    }
  }

  private async convert(): Promise<void> {
    if (!this.inputPath || this.busy) {
      return;
    }
    this.busy = true;
    this.progress = 0;
    this.failed = false;
    this.status = '处理中...';
    this.resultPath = '';

    const options: VideoCropOptions = {
      outputWidth: this.outW,
      outputHeight: this.outH,
      scale: this.zoom,
      offsetX: this.offsetX,
      offsetY: this.offsetY,
      background: this.bgColor,
      crf: this.crf,
      keepAudio: false,
      sourceWidth: this.srcW,
      sourceHeight: this.srcH
    };
    try {
      const result = await convertVideoCrop(this.inputPath, this.outputPath, options,
        (value: number, msg: string) => {
          this.progress = value;
          this.message = msg;
        });
      this.progress = 1;
      if (!result.ok) {
        this.failed = true;
        this.status = '失败: ' + result.message;
        return;
      }
      this.status = '完成: ' + result.outputWidth + 'x' + result.outputHeight +
        ', ' + result.frameCount + ' 帧';
      this.resultPath = 'file://' + this.outputPath;
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'videoCrop failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private preview() {
    Stack() {
      Column() {
        if (this.framePath.length > 0) {
          Image(this.framePath)
            .width(this.srcW * this.zoom * this.viewScale())
            .height(this.srcH * this.zoom * this.viewScale())
            .objectFit(ImageFit.Fill)
            .position({ x: this.offsetX * this.viewScale(), y: this.offsetY * this.viewScale() })
        }
      }
      .width(this.outW * this.viewScale())
      .height(this.outH * this.viewScale())
      .backgroundColor(this.bgColor)
      .clip(true)
    }
    .width(this.outW * this.viewScale())
    .height(this.outH * this.viewScale())
    .border({ width: 1, color: '#c8ccd4' })
    .gesture(
      PanGesture({ direction: PanDirection.All })
        .onActionStart(() => {
          this.gestureStartX = this.offsetX;
          this.gestureStartY = this.offsetY;
        })
        .onActionUpdate((event: GestureEvent) => {
          this.offsetX = this.gestureStartX + event.offsetX / this.viewScale();
          this.offsetY = this.gestureStartY + event.offsetY / this.viewScale();
          this.clampTransform();
        })
    )
    .parallelGesture(
      PinchGesture({})
        .onActionStart(() => { this.gestureStartScale = this.zoom; })
        .onActionUpdate((event: GestureEvent) => {
          this.zoom = Math.min(64, Math.max(0.02, this.gestureStartScale * event.scale));
          this.clampTransform();
        })
    )
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('视频裁剪').fontSize(22).fontWeight(FontWeight.Bold)
            Text('把视频重新构图到固定画布，拖动与缩放所见即所得')
              .fontSize(12).fontColor('#5b6472')
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Button(this.inputPath ? '重选' : '选择文件')
            .onClick(() => { this.pick(); })
            .enabled(!this.busy)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (!this.inputPath) {
          Column({ space: 6 }) {
            Text('尚未选择视频').fontSize(15).fontColor('#5b6472')
            Text('支持 MP4 / MOV / MKV / AVI / WebM').fontSize(12).fontColor('#8a93a0')
          }
          .width('100%')
          .padding(28)
          .backgroundColor('#f2f4f7')
          .borderRadius(12)
        } else {
          this.preview()

          Row({ space: 8 }) {
            Button('适应').fontSize(12).layoutWeight(1)
              .onClick(() => { this.applyFit('fit'); })
            Button('填满').fontSize(12).layoutWeight(1)
              .onClick(() => { this.applyFit('fill'); })
            Button('重置').fontSize(12).layoutWeight(1)
              .onClick(() => { this.applyFit('fill'); })
          }
          .width('100%')

          Column({ space: 10 }) {
            Text('输出画布').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 6 }) {
              ForEach(this.presets, (preset: RatioPreset) => {
                Button(preset.label)
                  .fontSize(11)
                  .layoutWeight(1)
                  .backgroundColor('#e8ebf0')
                  .fontColor('#1c2430')
                  .onClick(() => { this.applyPreset(preset); })
              }, (preset: RatioPreset) => preset.id)
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('宽').fontSize(13).width(28)
              TextInput({ text: this.outW.toString() })
                .type(InputType.Number).layoutWeight(1)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  if (!isNaN(n) && n > 0) { this.outW = n; this.clampTransform(); }
                })
              Text('高').fontSize(13).width(28)
              TextInput({ text: this.outH.toString() })
                .type(InputType.Number).layoutWeight(1)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  if (!isNaN(n) && n > 0) { this.outH = n; this.clampTransform(); }
                })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('缩放').fontSize(13).width(28)
              Text(this.zoom.toFixed(3)).fontSize(13).layoutWeight(1)
              Text('质量').fontSize(13).width(40)
              TextInput({ text: this.crf.toString() })
                .type(InputType.Number).width(80)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  if (!isNaN(n) && n >= 0 && n <= 51) { this.crf = n; }
                })
            }
            .width('100%')
            Row({ space: 8 }) {
              Text('背景').fontSize(13).width(28)
              ForEach(this.swatches, (color: string) => {
                Button()
                  .width(26).height(26)
                  .backgroundColor(color)
                  .border({ width: this.bgColor === color ? 2 : 0, color: '#2f6fed' })
                  .onClick(() => { this.bgColor = color; })
              }, (color: string) => color)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Button(this.busy ? '处理中...' : '开始裁剪')
            .width('100%')
            .enabled(!this.busy && this.inputPath.length > 0)
            .onClick(() => { this.convert(); })

          if (this.busy) {
            Progress({ value: this.progress, total: 1, type: ProgressType.Linear })
              .width('100%')
            Text(this.message).fontSize(11).fontColor('#5b6472')
          }

          if (this.status.length > 0) {
            Text(this.status)
              .fontSize(13)
              .fontColor(this.failed ? '#c0392b' : '#1e7f4f')
              .width('100%')
          }

          if (this.resultPath.length > 0) {
            Column({ space: 6 }) {
              Text('结果').fontSize(13).fontColor('#5b6472')
              Text(this.outputPath).fontSize(11).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
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
