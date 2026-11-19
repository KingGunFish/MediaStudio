import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import msverify from 'libmsverify.so';

const TAG: string = 'MsVerify';

/**
 * Verification page for the Media Studio -> HarmonyOS PC port.
 *
 * Each probe answers one question that the port design depends on:
 *   P1  NAPI bridge works on a 2in1 device.
 *   P2  The device runtime is musl-based and sane.
 *   P3  Native zlib emits zlib (RFC1950) streams -> PNG IDAT is possible.
 *   P4  OH_Ability_StartNativeChildProcess is open to a third-party app.
 *   P5  ArkUI Canvas supports pixel read/write (getImageData/putImageData).
 */
@Entry
@Component
struct Index {
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
    Column({ space: 6 }) {
      Text('Media Studio → HarmonyOS PC 验证')
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

      Scroll() {
        Column({ space: 4 }) {
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
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }
}
