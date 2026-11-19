// pages/Converter.ets - 视频转 GIF.
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Converter.tsx:
// pick a video, review its geometry, set the output width / height / frame
// rate / ping-pong, then convert.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  MediaInfo,
  VideoToGifOptions,
  probeMedia,
  convertVideoToGif,
  formatDuration,
  formatSize
} from '../common/MediaApi';
import { pickAndStage, outputPath } from '../common/FilePicker';

const TAG: string = 'MsVerify';

@Component
export struct ConverterPage {
  @State inputPath: string = '';
  @State outputPath: string = '';
  @State info: MediaInfo | null = null;
  @State outWidth: number = 480;
  @State outHeight: number = 270;
  @State fps: number = 12;
  @State pingPong: boolean = true;
  @State busy: boolean = false;
  @State progress: number = 0;
  @State message: string = '';
  @State status: string = '';
  @State failed: boolean = false;
  @State previewUri: string = '';

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async pick(): Promise<void> {
    const path = await pickAndStage(this.ctx(), ['.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v']);
    if (!path) {
      return;
    }
    this.inputPath = path;
    this.status = '';
    this.failed = false;
    this.previewUri = '';
    try {
      const info = await probeMedia(path);
      if (!info.ok) {
        this.failed = true;
        this.status = '探测失败: ' + info.message;
        this.info = null;
        return;
      }
      this.info = info;
      const defW = Math.min(480, info.width);
      this.outWidth = defW;
      this.outHeight = Math.max(2, Math.round(defW * info.height / info.width));
      this.outputPath = outputPath(this.ctx(), 'media_studio.gif');
      this.status = '';
    } catch (e) {
      this.failed = true;
      this.status = '探测异常: ' + JSON.stringify(e);
    }
  }

  private onWidthChanged(text: string): void {
    const w = parseInt(text);
    if (isNaN(w) || w <= 0) {
      return;
    }
    this.outWidth = w;
    if (this.info && this.info.width > 0) {
      this.outHeight = Math.max(2, Math.round(w * this.info.height / this.info.width));
    }
  }

  private onHeightChanged(text: string): void {
    const h = parseInt(text);
    if (isNaN(h) || h <= 0) {
      return;
    }
    this.outHeight = h;
    if (this.info && this.info.height > 0) {
      this.outWidth = Math.max(2, Math.round(h * this.info.width / this.info.height));
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
    this.previewUri = '';

    const options: VideoToGifOptions = {
      width: this.outWidth,
      height: this.outHeight,
      fps: this.fps,
      pingPong: this.pingPong
    };
    try {
      const result = await convertVideoToGif(this.inputPath, this.outputPath, options,
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
      this.outWidth = result.outputWidth;
      this.outHeight = result.outputHeight;
      this.status = '完成: ' + result.frameCount + ' 帧, ' +
        result.outputWidth + 'x' + result.outputHeight + ', ' +
        formatSize(result.fileSize);
      this.previewUri = 'file://' + this.outputPath;
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'videoToGif failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('视频 → GIF').fontSize(22).fontWeight(FontWeight.Bold)
            Text('把视频转换为高质量 GIF，支持缩放、调整帧率、ping-pong 循环')
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
            Text('支持 MP4 / MOV / MKV / AVI / WebM')
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
            if (this.info) {
              Text(this.info.width + ' × ' + this.info.height + '　·　时长 ' +
                formatDuration(this.info.duration) + '　·　大小 ' +
                formatSize(this.info.fileSize) + '　·　' + this.info.codec)
                .fontSize(12).fontColor('#5b6472')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Column({ space: 10 }) {
            Text('输出设置').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 10 }) {
              Text('宽度').fontSize(13).width(52)
              TextInput({ text: this.outWidth.toString(), placeholder: '480' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.onWidthChanged(v); })
              Text('高度').fontSize(13).width(52)
              TextInput({ text: this.outHeight.toString(), placeholder: '270' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.onHeightChanged(v); })
            }
            .width('100%')
            Text('宽高按原始比例联动').fontSize(11).fontColor('#8a93a0')
            Row({ space: 10 }) {
              Text('帧率').fontSize(13).width(52)
              TextInput({ text: this.fps.toString(), placeholder: '12' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => {
                  const f = parseInt(v);
                  if (!isNaN(f) && f > 0) {
                    this.fps = f;
                  }
                })
              Text('Ping-pong').fontSize(13).width(70)
              Toggle({ type: ToggleType.Switch, isOn: this.pingPong })
                .onChange((v: boolean) => { this.pingPong = v; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Button(this.busy ? '处理中...' : '开始转换')
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

          if (this.previewUri.length > 0) {
            Column({ space: 6 }) {
              Text('预览').fontSize(13).fontColor('#5b6472')
              Image(this.previewUri)
                .width('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor('#202020')
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
