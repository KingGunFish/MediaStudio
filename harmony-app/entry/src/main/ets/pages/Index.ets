// pages/Index.ets - the application shell.
//
// A left navigation column (the Windows build uses the same layout) and a
// content area that hosts one feature page at a time. Every page drives the
// native in-process engine through ../common/MediaApi.

import { ConverterPage } from './Converter';
import { KeyingPage } from './Keying';
import { VideoCropPage } from './VideoCrop';
import { DiagnosticsPage } from './Diagnostics';

interface NavEntry {
  id: string;
  label: string;
  hint: string;
}

@Entry
@Component
struct Index {
  @State tab: string = 'home';
  private nav: NavEntry[] = [
    { id: 'home', label: '首页', hint: '选择要使用的功能' },
    { id: 'converter', label: '视频转GIF', hint: '把视频转换为高质量 GIF' },
    { id: 'keying', label: 'GIF抠图', hint: '去掉 GIF 背景与水印' },
    { id: 'videocrop', label: '视频裁剪', hint: '重新构图到固定画布' },
    { id: 'diagnostics', label: '自检', hint: '引擎与平台能力探针' }
  ];

  @Builder
  private navItem(entry: NavEntry) {
    Column({ space: 2 }) {
      Text(entry.label)
        .fontSize(14)
        .fontWeight(this.tab === entry.id ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === entry.id ? '#ffffff' : '#c9d1de')
      if (this.tab === entry.id) {
        Text(entry.hint).fontSize(10).fontColor('#9fb4d8')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .borderRadius(8)
    .backgroundColor(this.tab === entry.id ? '#2f6fed' : '#00000000')
    .onClick(() => { this.tab = entry.id; })
  }

  @Builder
  private home() {
    Column({ space: 14 }) {
      Column({ space: 4 }) {
        Text('Media Studio').fontSize(26).fontWeight(FontWeight.Bold)
        Text('鸿蒙 PC 版 · 全部处理在本机完成，不上传任何数据')
          .fontSize(12).fontColor('#5b6472')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Grid() {
        ForEach(this.nav.slice(1, 4), (entry: NavEntry) => {
          GridItem() {
            Column({ space: 6 }) {
              Text(entry.label).fontSize(17).fontWeight(FontWeight.Medium)
              Text(entry.hint).fontSize(12).fontColor('#5b6472')
              Text('开始 →').fontSize(12).fontColor('#2f6fed')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(16)
            .backgroundColor('#f7f8fa')
            .borderRadius(12)
          }
          .onClick(() => { this.tab = entry.id; })
        }, (entry: NavEntry) => entry.id)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(12)
      .rowsGap(12)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
  }

  build() {
    Row() {
      // Sidebar
      Column({ space: 4 }) {
        Text('🎬 Media Studio')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .margin({ bottom: 12, left: 14 })
        ForEach(this.nav, (entry: NavEntry) => {
          this.navItem(entry)
        }, (entry: NavEntry) => entry.id)
        Blank()
        Text('HarmonyOS PC · 2in1')
          .fontSize(10)
          .fontColor('#7d8899')
          .margin({ left: 14, bottom: 8 })
      }
      .width(190)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#1d2430')
      .padding({ top: 16 })

      // Content
      Column() {
        if (this.tab === 'home') {
          this.home()
        } else if (this.tab === 'converter') {
          ConverterPage()
        } else if (this.tab === 'keying') {
          KeyingPage()
        } else if (this.tab === 'videocrop') {
          VideoCropPage()
        } else {
          DiagnosticsPage()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
