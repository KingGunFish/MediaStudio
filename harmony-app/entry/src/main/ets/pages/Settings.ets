// pages/Settings.ets - 关于与说明.
//
// Mirrors the Windows page electron-app/src/renderer/src/pages/Settings.tsx,
// which is a static "about" block, plus the information that only matters on
// the HarmonyOS build.

@Component
export struct SettingsPage {
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('设置').fontSize(22).fontWeight(FontWeight.Bold)
        Text('关于 Media Studio').fontSize(12).fontColor('#5b6472')

        Column({ space: 8 }) {
          Text('关于').fontSize(15).fontWeight(FontWeight.Medium)
          Text('Media Studio v1.0.0 — 把视频/GIF 转为透明背景 GIF。')
            .fontSize(13).fontColor('#5b6472')
          Text('基于 ffmpeg + 颜色/亮度边界识别算法。')
            .fontSize(13).fontColor('#5b6472')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor('#f7f8fa')
        .borderRadius(10)

        Column({ space: 8 }) {
          Text('5 种抠图算法').fontSize(15).fontWeight(FontWeight.Medium)
          Text('· RGB + Mask 拆分（推荐，本工具创新）')
            .fontSize(13).fontColor('#5b6472')
          Text('· 颜色距离 + 通道阈值兜底')
            .fontSize(13).fontColor('#5b6472')
          Text('· 亮度阈值 / 白色像素 / Chroma Key')
            .fontSize(13).fontColor('#5b6472')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor('#f7f8fa')
        .borderRadius(10)

        Column({ space: 8 }) {
          Text('HarmonyOS PC 版').fontSize(15).fontWeight(FontWeight.Medium)
          Text('· 全部处理在本机完成，不上传任何数据')
            .fontSize(13).fontColor('#5b6472')
          Text('· ffmpeg 以 LGPL v3 授权随包分发（动态库，可替换）')
            .fontSize(13).fontColor('#5b6472')
          Text('· 引擎在应用进程内运行，不启动外部可执行文件')
            .fontSize(13).fontColor('#5b6472')
          Text('· 支持 arm64-v8a 与 x86_64 双架构')
            .fontSize(13).fontColor('#5b6472')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor('#f7f8fa')
        .borderRadius(10)
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
