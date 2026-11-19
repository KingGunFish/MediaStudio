// pages/Diagnostics.ets - engine and platform probes.
//
// This page keeps the M1/M2 verification harness reachable from the app: it
// answers "does the engine still work on this device" with the same probes
// that closed the port milestones.
//
//   P1  NAPI bridge works on a 2in1 device.
//   P2  The device runtime is musl-based and sane.
//   P3  Native zlib emits zlib (RFC1950) streams -> PNG IDAT is possible.
//   P4  OH_Ability_StartNativeChildProcess is open to a third-party app.
//   P5  ArkUI Canvas supports pixel read/write (getImageData/putImageData).
//   P6  The real keying filter chain evaluates the real alpha expression.
//   P7  A real animated GIF is encoded by the OHOS built libavcodec.
//   P8  The C1 video -> GIF pipeline end to end.
//   P9  The same pipeline on a clip with a 90 degree display matrix.
//   P10 The C2 keying pipeline on an animated GIF.
//   P11 The production probe API on a real clip.
//   P12 The production video -> GIF API (async work + progress callback).
//   P13 The production keying API.
//   P14 The production crop API.
//   P15 The first frame decoder that feeds the crop preview.

import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import msverify from 'libmsverify.so';
import {
  VideoToGifOptions,
  KeyingOptions,
  VideoCropOptions,
  probeMedia,
  convertVideoToGif,
  convertGifKeying,
  convertVideoCrop
} from '../common/MediaApi';

const TAG: string = 'MsVerify';

@Component
export struct DiagnosticsPage {
  @State lines: string[] = [];
  @State done: boolean = false;

  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  private add(line: string): void {
    hilog.info(0x3200, TAG, '%{public}s', line);
    this.lines = this.lines.concat([line]);
  }

  aboutToAppear(): void {
    this.runNativeProbes();
  }

  /**
   * Copies a bundled rawfile into the app sandbox and returns its path.
   *
   * The clips ship as rawfiles so that the probe needs no file permission
   * and no user interaction; the app sandbox itself is not writable from
   * adb/hdc.
   */
  private stageRawFile(ctx: common.UIAbilityContext, rawName: string): string {
    const buf: Uint8Array = ctx.resourceManager.getRawFileContentSync(rawName);
    const target = ctx.filesDir + '/' + rawName;
    const file = fileIo.openSync(target,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, buf.buffer);
    fileIo.closeSync(file);
    return target;
  }

  private stageSampleVideo(ctx: common.UIAbilityContext, label: string,
    rawName: string, outName: string): void {
    try {
      const target = this.stageRawFile(ctx, rawName);
      const output = ctx.filesDir + '/' + outName;
      this.add(label + ' videoToGif  = ' + msverify.videoToGif(target, output, true));
    } catch (e) {
      this.add(label + ' videoToGif  FAILED ' + JSON.stringify(e));
    }
  }

  private stageKeying(ctx: common.UIAbilityContext, label: string,
    rawName: string, outName: string): void {
    try {
      const target = this.stageRawFile(ctx, rawName);
      const output = ctx.filesDir + '/' + outName;
      this.add(label + ' gifKeying   = ' + msverify.gifKeying(target, output));
    } catch (e) {
      this.add(label + ' gifKeying   FAILED ' + JSON.stringify(e));
    }
  }

  private runNativeProbes(): void {
    // P1 - NAPI bridge
    try {
      this.add('P1 napi.ping      = ' + msverify.ping());
    } catch (e) {
      this.add('P1 napi.ping      FAILED ' + JSON.stringify(e));
    }

    // P2 - runtime info
    try {
      this.add('P2 sysInfo        = ' + msverify.sysInfo());
    } catch (e) {
      this.add('P2 sysInfo        FAILED ' + JSON.stringify(e));
    }

    // P3 - native zlib format
    try {
      this.add('P3 zlibProbe      = ' + msverify.zlibProbe());
      const probe = new ArrayBuffer(256);
      const view = new Uint8Array(probe);
      for (let i = 0; i < 64; i++) {
        view[i] = i;
      }
      const packed = msverify.zlibDeflate(probe);
      const pv = new Uint8Array(packed);
      let head = '';
      for (let i = 0; i < 4 && i < pv.length; i++) {
        head += pv[i].toString(16).padStart(2, '0') + ' ';
      }
      this.add('P3 zlibDeflate    = len=' + pv.length + ' head=' + head.trim() +
        ' zlibMagic=' + (pv[0] === 0x78 ? 'YES' : 'NO'));
    } catch (e) {
      this.add('P3 zlibDeflate    FAILED ' + JSON.stringify(e));
    }

    // P6 - the real keying filter chain + P7 - real GIF encoding
    try {
      this.add('P6 avfilterProbe  = ' + msverify.avfilterProbe());
    } catch (e) {
      this.add('P6 avfilterProbe  FAILED ' + JSON.stringify(e));
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const gifPath = ctx.filesDir + '/probe.gif';
      this.add('P7 gifEncodeProbe = ' + msverify.gifEncodeProbe(gifPath));
    } catch (e) {
      this.add('P7 gifEncodeProbe FAILED ' + JSON.stringify(e));
    }

    // P8 - end-to-end video -> GIF through the production pipeline.
    // P9 - the same pipeline on a clip that carries a 90 degree display
    //      matrix, i.e. the vertical-shot case that relies on the CLI's
    //      auto-rotation being reproduced inside the process.
    // P10 - the C2 keying pipeline on an animated GIF, which needs the
    //       shared mask_builder filter chain (two parallel chains that
    //       share one input).
    const ctx8 = getContext(this) as common.UIAbilityContext;
    this.stageSampleVideo(ctx8, 'P8', 'test.mp4', 'out.gif');
    this.stageSampleVideo(ctx8, 'P9', 'test_rot90.mp4', 'out_rot90.gif');
    this.stageKeying(ctx8, 'P10', 'test_key.gif', 'out_key.gif');

    // P11 - P15: the API the real pages call.
    this.runProductionProbes();

    // P4 - native child process
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const marker = ctx.filesDir + '/child_marker.txt';
      this.add('P4 childProcess   = ' + msverify.childProcessProbe(marker));
      // The child writes the marker asynchronously; give it a moment.
      setTimeout(() => {
        let markerState = 'missing';
        try {
          const f = fileIo.openSync(marker, fileIo.OpenMode.READ_ONLY);
          const buf = new ArrayBuffer(64);
          const n = fileIo.readSync(f.fd, buf);
          fileIo.closeSync(f);
          const bytes = new Uint8Array(buf, 0, n);
          let text = '';
          for (let i = 0; i < bytes.length; i++) {
            text += String.fromCharCode(bytes[i]);
          }
          markerState = 'read ' + n + ' bytes: ' + text;
        } catch (e) {
          markerState = 'not found (' + JSON.stringify(e) + ')';
        }
        this.add('P4 marker file    = ' + markerState);
        this.done = true;
      }, 2500);
    } catch (e) {
      this.add('P4 childProcess   FAILED ' + JSON.stringify(e));
      this.done = true;
    }
  }

  /**
   * Exercises the production API the application pages use.
   *
   * These calls go through the same promise + progress callback path as the
   * real pages, so they prove that the async worker, the thread safe progress
   * bridge and the option contract all work on the device.
   */
  private async runProductionProbes(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const target = this.stageRawFile(ctx, 'test.mp4');

      const info = await probeMedia(target);
      this.add('P11 probeMedia    = ok=' + info.ok + ' ' + info.width + 'x' + info.height +
        ' fps=' + info.fps + ' dur=' + info.duration.toFixed(2) +
        ' frames=' + info.nbFrames + ' codec=' + info.codec + ' size=' + info.fileSize);

      const gifOptions: VideoToGifOptions = {
        width: 240, height: 135, fps: 12, pingPong: true
      };
      const gifRes = await convertVideoToGif(target, ctx.filesDir + '/app_out.gif', gifOptions,
        (value: number, message: string) => {
          this.add('P12 progress      = ' + value.toFixed(2) + ' ' + message);
        });
      this.add('P12 convertVideo  = ok=' + gifRes.ok + ' frames=' + gifRes.frameCount +
        ' ' + gifRes.outputWidth + 'x' + gifRes.outputHeight + ' size=' + gifRes.fileSize +
        ' msg=' + gifRes.message);

      const keyOptions: KeyingOptions = {
        algorithm: 'rgbSplit', pingPong: true, useChannelFallback: true,
        watermarkBottomRight: true, watermarkTopLeft: true
      };
      const keyRes = await convertGifKeying(this.stageRawFile(ctx, 'test_key.gif'),
        ctx.filesDir + '/app_key.gif', keyOptions);
      this.add('P13 convertKeying = ok=' + keyRes.ok + ' frames=' + keyRes.frameCount +
        ' ' + keyRes.outputWidth + 'x' + keyRes.outputHeight + ' size=' + keyRes.fileSize +
        ' msg=' + keyRes.message);

      const cropOptions: VideoCropOptions = {
        outputWidth: 320, outputHeight: 240, scale: 1, offsetX: 0, offsetY: 0,
        background: '#000000', crf: 23, keepAudio: false,
        sourceWidth: info.width, sourceHeight: info.height
      };
      const cropRes = await convertVideoCrop(target, ctx.filesDir + '/app_crop.avi', cropOptions);
      this.add('P14 convertCrop   = ok=' + cropRes.ok + ' frames=' + cropRes.frameCount +
        ' ' + cropRes.outputWidth + 'x' + cropRes.outputHeight + ' size=' + cropRes.fileSize +
        ' msg=' + cropRes.message);

      const frame = msverify.decodeFirstFrame(target, ctx.filesDir + '/app_frame.png');
      this.add('P15 decodeFrame   = ok=' + frame.ok + ' ' + frame.width + 'x' + frame.height +
        ' msg=' + frame.message);
    } catch (e) {
      this.add('P11..P15          FAILED ' + JSON.stringify(e));
    }
  }

  private runCanvasProbe(): void {
    // P5 - Canvas pixel read/write
    try {
      const c = this.ctx;
      c.fillStyle = '#FF0000';
      c.fillRect(0, 0, 20, 20);
      const d1 = c.getImageData(5, 5, 1, 1);
      const p1 = d1.data;
      this.add('P5 getImageData   = rgba(' + p1[0] + ',' + p1[1] + ',' + p1[2] + ',' + p1[3] + ')');

      const img = c.createImageData(2, 2);
      img.data[0] = 0;
      img.data[1] = 0;
      img.data[2] = 255;
      img.data[3] = 255;
      img.data[4] = 0;
      img.data[5] = 255;
      img.data[6] = 0;
      img.data[7] = 255;
      c.putImageData(img, 40, 40);
      const d2 = c.getImageData(40, 40, 1, 1);
      const p2 = d2.data;
      this.add('P5 putImageData   = rgba(' + p2[0] + ',' + p2[1] + ',' + p2[2] + ',' + p2[3] + ')');
      this.add('P5 canvas verdict = ' +
        ((p1[0] === 255 && p1[1] === 0 && p1[3] === 255 && p2[2] === 255 && p2[3] === 255)
          ? 'PASS' : 'FAIL'));
    } catch (e) {
      this.add('P5 canvas         FAILED ' + JSON.stringify(e));
    }
  }

  build() {
    Scroll() {
      Column({ space: 6 }) {
        Text('引擎自检探针')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })

        Canvas(this.ctx)
          .width(120)
          .height(120)
          .backgroundColor('#202020')
          .onReady(() => {
            this.runCanvasProbe();
          })

        ForEach(this.lines, (line: string) => {
          Text(line)
            .fontSize(12)
            .fontFamily('monospace')
            .width('100%')
        }, (line: string) => line)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }
}
