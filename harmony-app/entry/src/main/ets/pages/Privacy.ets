// pages/Privacy.ets - 隐私政策全文（本机预置的 H5，不需要联网）。
//
// 页面用 ArkWeb 加载 resources/rawfile/privacy.html。那是一份纯静态的单文件
// 页面，没有外部依赖、没有脚本，因此可以原样部署到公网，作为应用市场上架
// 时要填写的隐私政策地址。
//
// 权限说明：加载 resource://rawfile 属于本地资源访问，不涉及网络，
// 因此本应用不需要 ohos.permission.INTERNET。

import { webview } from '@kit.ArkWeb';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { isAccepted, revoke, PRIVACY_VERSION } from '../common/Privacy';

@Entry
@Component
struct PrivacyPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 当前是否已经取得同意（决定是否显示「撤回同意」）。 */
  @State granted: boolean = false;
  /** 页面还在加载（ArkWeb 首次起渲染进程时会有白屏）。 */
  @State loading: boolean = true;
  /** 本地页面加载失败时的兜底提示。 */
  @State loadFailed: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    isAccepted(ctx).then((ok: boolean) => {
      this.granted = ok;
    });
  }

  /**
   * 撤回同意：删掉同意记录后回到首页。首页在每次显示时会重新读取同意状态，
   * 于是首启隐私弹窗会再次出现 —— 未同意就不能继续使用应用。
   */
  private async withdraw(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await revoke(ctx);
    this.granted = false;
    promptAction.showToast({ message: '已撤回隐私同意' });
    router.back();
  }

  build() {
    Column() {
      // Header
      Row({ space: 12 }) {
        Button('‹ 返回')
          .type(ButtonType.Normal)
          .backgroundColor('#ffffff')
          .fontColor('#1d2430')
          .onClick(() => {
            router.back();
          })
        Text('隐私政策').fontSize(18).fontWeight(FontWeight.Bold)
        Text(PRIVACY_VERSION).fontSize(12).fontColor('#5b6472')
        Blank()
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#f4f6f9')

      // Web 视图常驻在下面，加载提示与失败提示都盖在上面。
      // 第一次拉起 ArkWeb 要起渲染进程，这段时间是白屏，给个提示更稳妥。
      Stack() {
        Web({ src: 'resource://rawfile/privacy.html', controller: this.controller })
          .width('100%')
          .height('100%')
          // 隐私页面是纯静态文档，关掉脚本与存储能力，进一步缩小攻击面。
          .javaScriptAccess(false)
          .domStorageAccess(false)
          .fileAccess(false)
          .onPageEnd(() => {
            this.loading = false;
          })
          .onErrorReceive(() => {
            this.loading = false;
            this.loadFailed = true;
          })

        if (this.loading) {
          Column({ space: 12 }) {
            LoadingProgress().width(40).height(40).color('#2f6fed')
            Text('正在加载隐私政策…').fontSize(13).fontColor('#5b6472')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#ffffff')
        }

        if (this.loadFailed) {
          Column({ space: 10 }) {
            Text('隐私政策页面加载失败')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
            Text('本地预置的 privacy.html 未能打开，请重新安装应用后重试。')
              .fontSize(13)
              .fontColor('#5b6472')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#ffffff')
        }
      }
      .width('100%')
      .layoutWeight(1)

      if (this.granted) {
        Row() {
          Blank()
          Button('撤回隐私同意')
            .type(ButtonType.Normal)
            .backgroundColor('#ffffff')
            .fontColor('#d93025')
            .onClick(() => {
              this.withdraw();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#f4f6f9')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
