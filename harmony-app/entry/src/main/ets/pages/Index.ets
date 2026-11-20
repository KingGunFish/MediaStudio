// pages/Index.ets - the application shell.
//
// A left navigation column (the Windows build uses the same layout) and a
// content area that hosts one feature page at a time. Every page drives the
// native in-process engine through ../common/MediaApi.

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ConverterPage } from './Converter';
import { KeyingPage } from './Keying';
import { VideoCropPage } from './VideoCrop';
import { MonoPage } from './Mono';
import { CropPage } from './Crop';
import { IconsPage } from './Icons';
import { SettingsPage } from './Settings';
import { DiagnosticsPage } from './Diagnostics';
import { accept, isAccepted, revoke } from '../common/Privacy';

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
    { id: 'mono', label: '图片转黑白', hint: '1 位黑白 BMP 与墨水屏数组' },
    { id: 'crop', label: '图片裁剪', hint: '自定义画布裁剪与缩放' },
    { id: 'icons', label: '图标生成', hint: '一键产出上架全套图标' },
    { id: 'settings', label: '设置', hint: '关于与说明' },
    { id: 'diagnostics', label: '自检', hint: '引擎与平台能力探针' }
  ];

  /**
   * 隐私同意状态。
   * pending = 还没读出结果；needed = 需要征求同意；granted = 已同意；
   * declined = 用户明确拒绝了。
   */
  @State consent: string = 'pending';

  aboutToAppear(): void {
    this.refreshConsent();
  }

  // 从「数据和隐私」页撤回同意后回到这里时，重新读一次同意状态。
  onPageShow(): void {
    this.refreshConsent();
  }

  private async refreshConsent(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const ok = await isAccepted(ctx);
    this.consent = ok ? 'granted' : 'needed';
  }

  /** 用户同意：记录下来之后才允许使用应用。 */
  private async grant(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await accept(ctx);
    this.consent = 'granted';
  }

  /** 用户拒绝：清掉同意记录，应用进入不可用状态。 */
  private async decline(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await revoke(ctx);
    this.consent = 'declined';
  }

  private async exitApp(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await ctx.terminateSelf();
  }

  /**
   * 首启隐私弹窗。
   * 未取得同意时盖住整个应用：底下不构建任何功能页，
   * 因此在用户同意之前不会有任何业务代码被执行。
   */
  @Builder
  private privacyGate() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：挡住底下的一切交互。
      // 8 位色是 AARRGGBB（alpha 在前），#66000000 = 40% 黑。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .hitTestBehavior(HitTestMode.Block)

      Column({ space: 14 }) {
        if (this.consent === 'declined') {
          Text('未同意隐私政策')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .width('100%')
          Text('您已选择不同意本应用的隐私政策。按照应用市场的要求，未取得同意前无法使用本应用的任何功能。')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Button('退出应用')
            .width('100%')
            .backgroundColor('#d93025')
            .fontColor('#ffffff')
            .onClick(() => {
              this.exitApp();
            })
        } else {
          Text('隐私政策')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .width('100%')
          Text('欢迎使用 Media Studio。本应用是一款纯本地的视频 / 图片处理工具，所有处理都在您的设备上完成。')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('· 不收集任何个人信息（无账号、无设备标识、无位置 / 通讯录 / 相机 / 麦克风）')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('· 不申请任何系统权限')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('· 不联网，不上传任何数据')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('· 未接入任何第三方 SDK')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('点击「同意并继续」表示您已阅读并同意《隐私政策》；如需先看全文，可点击下方链接。')
            .fontSize(13)
            .fontColor('#5b6472')
            .width('100%')
          Text('《隐私政策》全文')
            .fontSize(14)
            .fontColor('#2f6fed')
            .width('100%')
            .onClick(() => {
              router.pushUrl({ url: 'pages/Privacy' });
            })
          Row({ space: 12 }) {
            Button('不同意并退出')
              .layoutWeight(1)
              .backgroundColor('#e5e8ee')
              .fontColor('#1d2430')
              .onClick(() => {
                this.decline();
              })
            Button('同意并继续')
              .layoutWeight(1)
              .backgroundColor('#2f6fed')
              .fontColor('#ffffff')
              .onClick(() => {
                this.grant();
              })
          }
          .width('100%')
        }
      }
      .width(520)
      .padding(20)
      .backgroundColor('#ffffff')
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
  }

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
        ForEach(this.nav.slice(1), (entry: NavEntry) => {
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
    Stack() {
      // 只有拿到隐私同意才构建应用本体；没拿到之前下面一行代码都不会执行。
      if (this.consent === 'granted') {
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
            } else if (this.tab === 'mono') {
              MonoPage()
            } else if (this.tab === 'crop') {
              CropPage()
            } else if (this.tab === 'icons') {
              IconsPage()
            } else if (this.tab === 'settings') {
              SettingsPage()
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

      if (this.consent === 'needed' || this.consent === 'declined') {
        this.privacyGate()
      }
    }
    .width('100%')
    .height('100%')
  }
}
