// pages/Keying.ets - GIF 抠图.
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Keying.tsx:
// pick an animated GIF, choose the keying algorithm, then remove the
// background (and the watermark) from every frame.

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  KeyingOptions,
  KeyingAlgorithm,
  probeMedia,
  convertGifKeying,
  formatSize
} from '../common/MediaApi';
import { pickAndStage, outputPath } from '../common/FilePicker';

const TAG: string = 'MsVerify';

interface AlgorithmEntry {
  id: KeyingAlgorithm;
  label: string;
}

@Component
export struct KeyingPage {
  private algorithms: AlgorithmEntry[] = [
    { id: 'rgbSplit', label: 'RGB+Mask 拆分' },
    { id: 'distance', label: '颜色距离' },
    { id: 'brightness', label: '亮度阈值' },
    { id: 'white', label: '白色像素' },
    { id: 'chroma', label: 'Chroma Key' }
  ];

  @State inputPath: string = '';
  @State outputPath: string = '';
  @State algorithm: KeyingAlgorithm = 'rgbSplit';
  @State useChannelFallback: boolean = true;
  @State watermarkBR: boolean = true;
  @State watermarkTL: boolean = true;
  @State pingPong: boolean = true;
  @State bgR: number = 231;
  @State bgG: number = 225;
  @State bgB: number = 223;
  @State previewBg: string = '#3a4250';
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
    const path = await pickAndStage(this.ctx(), ['.gif']);
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
        return;
      }
      this.status = info.width + ' × ' + info.height + '　·　' + info.nbFrames +
        ' 帧　·　' + formatSize(info.fileSize);
      this.outputPath = outputPath(this.ctx(), 'media_studio_keyed.gif');
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
    this.previewUri = '';

    const options: KeyingOptions = {
      algorithm: this.algorithm,
      useChannelFallback: this.useChannelFallback,
      watermarkBottomRight: this.watermarkBR,
      watermarkTopLeft: this.watermarkTL,
      pingPong: this.pingPong,
      bgR: this.bgR,
      bgG: this.bgG,
      bgB: this.bgB
    };
    try {
      const result = await convertGifKeying(this.inputPath, this.outputPath, options,
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
      this.status = '完成: ' + result.frameCount + ' 帧, ' +
        result.outputWidth + 'x' + result.outputHeight + ', ' + formatSize(result.fileSize);
      this.previewUri = 'file://' + this.outputPath;
    } catch (e) {
      this.failed = true;
      this.status = '失败: ' + JSON.stringify(e);
      hilog.error(0x3200, TAG, 'gifKeying failed: %{public}s', JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  @Builder
  private algorithmRow() {
    Row({ space: 8 }) {
      ForEach(this.algorithms, (item: AlgorithmEntry) => {
        Button(item.label)
          .fontSize(12)
          .layoutWeight(1)
          .backgroundColor(this.algorithm === item.id ? '#2f6fed' : '#e8ebf0')
          .fontColor(this.algorithm === item.id ? '#ffffff' : '#1c2430')
          .onClick(() => { this.algorithm = item.id; })
      }, (item: AlgorithmEntry) => item.id)
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('GIF 抠图').fontSize(22).fontWeight(FontWeight.Bold)
            Text('把 GIF 背景变为透明，同时去除水印（豆包 AI 等）')
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
            Text('尚未选择 GIF').fontSize(15).fontColor('#5b6472')
            Text('支持 .gif 格式的动画图片').fontSize(12).fontColor('#8a93a0')
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
            if (this.status.length > 0 && !this.failed) {
              Text(this.status).fontSize(12).fontColor('#5b6472')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor('#f7f8fa')
          .borderRadius(10)

          Column({ space: 10 }) {
            Text('算法设置').fontSize(15).fontWeight(FontWeight.Medium)
            this.algorithmRow()
            Row({ space: 12 }) {
              Text('通道阈值兜底').fontSize(13).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.useChannelFallback })
                .onChange((v: boolean) => { this.useChannelFallback = v; })
            }
            .width('100%')
            Row({ space: 12 }) {
              Text('去水印（右下）').fontSize(13).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.watermarkBR })
                .onChange((v: boolean) => { this.watermarkBR = v; })
            }
            .width('100%')
            Row({ space: 12 }) {
              Text('去水印（左上）').fontSize(13).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.watermarkTL })
                .onChange((v: boolean) => { this.watermarkTL = v; })
            }
            .width('100%')
            Row({ space: 12 }) {
              Text('Ping-pong').fontSize(13).layoutWeight(1)
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

          if (this.algorithm === 'distance' || this.algorithm === 'rgbSplit') {
            Column({ space: 10 }) {
              Text('背景色 (RGB)').fontSize(15).fontWeight(FontWeight.Medium)
              Text('填入原始 GIF 背景区域的 RGB 值，抠像算法据此判断哪些像素属于背景')
                .fontSize(11).fontColor('#8a93a0')
              Row({ space: 10 }) {
                Text('R').fontSize(13).width(20)
                TextInput({ text: this.bgR.toString() })
                  .type(InputType.Number).layoutWeight(1)
                  .onChange((v: string) => { const n = parseInt(v); if (!isNaN(n)) { this.bgR = n; } })
                Text('G').fontSize(13).width(20)
                TextInput({ text: this.bgG.toString() })
                  .type(InputType.Number).layoutWeight(1)
                  .onChange((v: string) => { const n = parseInt(v); if (!isNaN(n)) { this.bgG = n; } })
                Text('B').fontSize(13).width(20)
                TextInput({ text: this.bgB.toString() })
                  .type(InputType.Number).layoutWeight(1)
                  .onChange((v: string) => { const n = parseInt(v); if (!isNaN(n)) { this.bgB = n; } })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .backgroundColor('#f7f8fa')
            .borderRadius(10)
          }

          Button(this.busy ? '处理中...' : '开始抠图')
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
                .backgroundColor(this.previewBg)
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
