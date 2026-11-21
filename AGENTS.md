# AGENTS.md — Agent 工程约定（长期有效）

给在本仓库工作的 AI 编码代理（ZCode / Codex / Claude Code 等）的长期约束。
优先级高于任何单次任务的"顺手优化"冲动。

## 核心设计原则

### 1. 最小改动原则（Minimize）
- 只改任务要求改的东西。禁止顺手重构、禁止"捎带"修复无关问题、禁止调整无关格式。
- 每一次 diff 都应能逐行回答"这是哪个需求要求的"。

### 2. 开闭原则（OCP：对扩展开放，对修改封闭）
- 新功能优先用**新文件 / 新模块 / 新增参数**实现，而不是改写已有模块的既有行为。
- 已经过验证的底层工具、脚本、配置（如 `tools/fetch-ffmpeg.mjs`、
  `electron-builder.yml`、`resources/sdk/*` 二进制）视为"修改封闭"区：
  要扩展行为时新增旁路，不要原地改写。

### 3. 底层工具与二进制不可擅自替换
- `electron-app/resources/sdk/` 下的 ffmpeg/ffprobe/ms_demo 是**用户管理的资产**
  （gitignore 掉的大体积二进制、含既定许可状态）。任何替换/升级/重下载
  必须先征得用户明确同意。
- 已知既定状态（2026-09-02 起，见 .workbuddy/memory）：sdk 内是 **GPL 版
  ffmpeg**；`npm run package:win` 会经 `fetch:ffmpeg` 自动尝试替换为 LGPL。
  若本次任务**不涉及**许可替换，打包时绕过它：
  `npm run version && npx electron-builder --win`（不跑 fetch:ffmpeg）。

### 4. 先闭环，再继续
- 发现自己做出了超出授权的改动，**先恢复原状**（从 git、旧构建产物、
  缓存副本恢复），再完成任务；恢复后必须校验（字节数 / 版本横幅 / 行为）。
- 交付前自查：git diff 里有没有与需求无关的行。

### 5. 外部资源：先找本地缓存，再考虑下载
- 长时间下载前先查：临时目录（%TEMP%）、旧构建产物（dist*/、release/）、
  .workbuddy/memory 是否已有现成副本。（例：LGPL ffmpeg zip 在
  %TEMP%/ffmpeg-lgpl-win32.zip 早有完整缓存。）
- 网络受限（本机代理 127.0.0.1:35290 时开时关）时，避免把任务押在
  大体积下载上。

### 6. 版本号规范
- 格式 `<年度>.<周>.<编译时间戳>`，如 `1.1.202609141506`：
  - 第 1 位：跨年 +1（此时周位归零，1.1.x -> 2.0.x）
  - 第 2 位：跨 ISO 周（周一为一周之始）+1
  - 第 3 位：每次打包自动取 YYYYMMDDHHMM，由 `tools/update-version.mjs`
    在 `npm run package` / `package:win` 链中自动写入。
- 不要手工改 package.json 的 version 来发版。

## 工程事实速查

- 打包产物：`electron-app/release/`（NSIS setup / portable / win.zip）。
- 打包后必须冒烟：启动 `release/win-unpacked/Media Studio.exe`，检查
  `%TEMP%\media-studio.log` 出现 `SDK worker present`。
- 应用日志：`%TEMP%\media-studio.log`。
- 提交遵循 conventional commits（feat/fix/chore/build），不强推，
  远端 https://github.com/KingGunFish/MediaStudio 。

### 鸿蒙移植的两端 ffmpeg 不是同一个版本

- 宿主（Windows 黄金件的来源）：`electron-app/resources/sdk/ffmpeg.exe` =
  nightly `N-126303-g9f35e220ff-20260827`（libavcodec 63.8.101）。
- 鸿蒙侧：`tools/build-ffmpeg-ohos.sh` 固定 **FFmpeg 7.1.1**。
- **已确认的语义差异**：`setpts` 在 7.1.1 会把输出链接的帧率标成未知
  （`libavfilter/setpts.c: config_output_video` → `{1,0}`），nightly 则**保留**
  输入帧率。凡是滤镜链末端带 `setpts=PTS-STARTPTS`（C1 的 ping-pong 段、
  C2 抠像链）都会命中，表现为图输出帧率 `1/0`。
- 处理方式在 `sdk/src/engine/ms_inproc_exec.cpp` 的 `effective_output_rate()`：
  沿链回溯到最近一个仍带帧率的链接。**改这条兜底逻辑前先读
  `docs/harmonyos-pc-port-architecture.md` §10.9**（含完整根因链与踩坑）。
- 验收口径是**解码后逐字节比对**（`tools/compare-gif.sh`），不是压缩流字节：
  两端 GIF 字节必然不同（调色板透明槽位索引、palettegen 落点都不同），
  但 rgba 画面逐字节一致即算通过。

### 鸿蒙工程是双 ABI 的：ffmpeg 头文件必须按架构隔离

- `harmony-app/entry/build-profile.json5` 的 `abiFilters` 是
  `["arm64-v8a","x86_64"]`（模拟器 x86_64 + 真机 aarch64），一次构建产出两套。
- FFmpeg 的 `config.h` 与 `libavutil/avconfig.h` 是**按架构生成**的，两架构
  相差 166 行（全为 SIMD/汇编特性宏）。它们放在
  `harmony-app/entry/src/main/cpp/third_party/ffmpeg/include/<abi>/` 覆盖层里；
  `CMakeLists.txt` 用 `${OHOS_ARCH}` 选路径，**覆盖层目录排在共享 include
  目录之前**，覆盖层缺失直接 `FATAL_ERROR`。
- **不要**把这两份头文件"顺手"合并回共享 include 目录 —— 那样 arm64 编译会
  静默使用 x86_64 的特性宏。`tools/stage-ffmpeg-ohos.sh` 按 ABI 产出覆盖层
  （该目录被 gitignore，只能靠脚本重建）。
- 实测澄清：aarch64 侧 `config.h` 的 `ARCH_AARCH64` 也是 **0**（该构建带
  `--disable-asm`，未启用任何架构特例路径），与 x86_64 版在 `ARCH_*` 上一致；
  真正分叉的只有 SIMD 特性宏。

### 鸿蒙设备验证：走 tools/run-ohos-device-check.sh

- 真机/模拟机验证不要手敲一串 hdc 命令，直接跑
  `tools/run-ohos-device-check.sh [target]`：装包 → 唤醒 → 拉起应用 →
  抓 UI 树定位「自检」→ 点击 → 收探针日志 → 拉沙箱产物 → 与 Windows
  黄金件对拍。
- 在 Git Bash 里跑时有个坑：hdc 是 Windows 原生程序，**MSYS 会把设备端路径
  （`/data/...`）改写成 Windows 路径**，必须对 hdc 单独关掉转换
  （`MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`），主机端路径用
  `cygpath -w` 转换。这个开关是全局的，关掉后 `compare-gif.sh` 调
  `ffmpeg.exe` 也会拿不到路径，所以必须按命令作用域设置。
  详见 `docs/harmonyos-pc-port-architecture.md` §10.5 #22。

### 鸿蒙图片类页面：走 ImageKit，不走 ArkUI Canvas

- C5 图片裁剪 / C6 图标生成 / C7 图片转黑白三张页**零新增 C++**，共用同一套
  基础设施：`common/ImageIo.ets`（ImageKit 解码与缩放 + 像素运算 + 文件读写）、
  `common/Png.ets`（PNG 色型 2/6，压缩复用原生 `zlibDeflate`）。
- **不要用 ArkUI Canvas 2D 搬像素** —— PC/2in1 上整幅 `getImageData` 不可信
  （v1.1 的 P5 只验证了单点读写）。改用
  `image.createImageSource()` → `createPixelMap({desiredPixelFormat: RGBA_8888})`
  → `readPixelsToBuffer()`，得到的是**行填充（stride）**且可能是 **PREMUL** 的
  数据，`ImageIo.ets` 里已统一归一成紧凑的直通 alpha RGBA。
- **ImageKit 的 `desiredSize` 是强制拉伸到目标尺寸、不保比例**。`cover`（填满并
  居中裁）/ `safe`（缩进中央安全区）两种适配必须自己算出保持比例的目标尺寸，
  否则图标会被拉变形。
- **ImageKit 的 JPEG 打包器不支持 alpha**，透明像素会被按黑色写出 —— 走 JPG
  前先用 `flattenRgba()` 按背景色压平。
- **C6 的分层图标背景层是纯色**：鸿蒙 `media/background.png` 与 Android 的
  `ic_launcher_background.png` 走 `IconJob.fit === 'solid'`，**只填背景色、不含
  图像**（审核要求）。Windows 侧 `renderJob()` 是「填底色再 cover 源图」，
  两端在这一项上**故意不一致**，Windows 侧本轮不动。
- 缩放重采样用**预乘 alpha 上的双线性**（`drawScaledRgba`），与浏览器 canvas
  的结果构图一致、边缘锐度略有差别，这是刻意取舍。
- 详细踩坑见 `docs/harmonyos-pc-port-architecture.md` §10.5 #25–#30、§10.12。

### ArkUI 写页面的高频坑（本项目已踩）

- `@State` 变量名**不能与 `CommonAttribute` 的方法同名**：`width` / `height` /
  `scale` / `background` 都是方法名。本项目用 `zoom`（缩放）、`outWidth` /
  `outHeight`、`bgColor`。
- `Scroll` 默认对齐是 `Alignment.Center`，内容比视口矮时会整体沉到窗口中部
  → 必须显式 `.align(Alignment.TopStart)`。
- `SelectOption.value` 的类型是 `ResourceStr`，`ForEach` 的 key 生成器要返回
  `string` → 用 `option.value.toString()`。`Select` 必须显式 `.value(...)` 才
  显示当前项。
- `PinchGesture` 的回调要标成 `PinchGestureEvent`（`GestureEvent` 基类上没有
  `focalPoint`），焦点坐标取 `pinchCenterX` / `pinchCenterY`。
- 2in1 模拟器**没有可用 IME**：`uitest uiInput text` 打不进 `TextInput`
  （按键事件如 Backspace 却能生效）。自动化验证走按钮路径，别把交互验证押在
  文本输入上。**注意**：首次拉起输入法会有「小艺输入法」隐私协议弹窗，没点
  「同意」就没有 IME；同意之后文本能进去，但 `onChange` 要等**焦点离开**
  （IME 提交）才触发 —— 输入后点一下别的控件再读状态。颜色类输入用纯数字
  （`336699`，`parseHexColor` 接受不带 `#`）可避开拼音组字。
- **ArkUI 的 8 位色是 `#AARRGGBB`（alpha 在前）**，不是 CSS 的 `#RRGGBBAA`。
  半透明黑要写 `#66000000`；写 `#00000066` 会得到「全透明 + 深蓝」，遮罩等于
  没画（点击却仍被 `hitTestBehavior` 挡住，极难自查）。

### 鸿蒙侧边栏：自绘 SVG 图标 + 可收起

- **不要用 `$r('sys.symbol.*')`**：本机 `command-line-tools/sdk` 与 DevEco Studio
  安装里都**搜不到 `sys.symbol.` 资源清单**（API 12 的 OpenHarmony SDK 不带这套
  东西），符号名只能靠猜。**自绘 SVG** 放 `entry/src/main/resources/base/media/`，
  24×24、白色描边、`round` 线帽，运行时 `Image($r('app.media.nav_xxx'))` 引用。
  现成 10 个：`nav_home` / `nav_video_gif` / `nav_keying` / `nav_video_crop` /
  `nav_mono` / `nav_image_crop` / `nav_icons` / `nav_settings` / `nav_diagnostics` /
  `nav_menu`。
- **小尺寸图标优先用实心**：20px 下 8 齿描边齿轮会糊成「太阳」，要改成
  `fill` + `fill-rule="evenodd"` 镂空中心的实心齿轮。
- **溢出到兄弟容器的内容会被盖住**：侧边栏里 `position()` 做的悬停气泡
  **画不过右侧内容区**（后画的兄弟节点在上）。气泡要放到**外壳根 Stack 的最外层**。
- **绝对定位的气泡位置靠版式常量算**：`Index.ets` 顶部的 `NAV_TOP` /
  `NAV_ROW_H` / `NAV_ROW_GAP` 描述收起态侧边栏的固定版式；
  **改了侧边栏的 padding 或行高必须同步改这三个常量**。
- **收起/展开的默认态**在 `Index.ets` 的 `@State navCollapsed`（当前默认收起，
  对齐剪映/美图的图标栏）。
- **2in1 模拟器被关掉后用 CLI 重启**：
  `Emulator.bat -start "<实例名>" -instancePath "<deployed 目录>" -imageRoot "<Sdk 目录>" -noWindow`。
  实例名带空格时**必须整条命令行传**（`Start-Process -ArgumentList` 传数组会被拆词）；
  `-instancePath` 给**父目录**，不是实例目录。

### 鸿蒙上架隐私合规：首启闸门 + 本地 H5 政策

- **首启弹窗要做成「状态机闸门」，不是「盖一层遮罩」**：
  `Index.ets` 用 `consent`（`pending` / `needed` / `granted` / `declined`）驱动，
  **只有 `granted` 才构建应用本体**。ArkUI 的 `if` 分支为假时组件根本不构造，
  于是用户同意前业务代码一次都没跑过 —— 这才是审核要的「未同意不得初始化」。
  遮罩只是视觉层，拦不住已经在后台跑起来的页面。
- **弹窗要素**：无勾选框、无默认勾选、必须有「同意」与「不同意」两条明确路径；
  不同意要给出可退出的落点（锁定状态 + 「退出应用」），不能把用户困住。
- **同意状态落盘**：`common/Privacy.ets` 用 `preferences` 存「同意 + 政策版本号」。
  版本号与当前 `PRIVACY_VERSION` 不一致即视为未同意 —— 政策改版会自动重新征求，
  不用改代码。
- **撤回同意**：隐私政策页底部「撤回隐私同意」→ 删记录 → `router.back()` →
  首页 `onPageShow` 重读 → 首启弹窗重新出现。别在撤回后直接杀进程。
- **本地 H5 政策放 `resources/rawfile/`**，用 ArkWeb 以
  `resource://rawfile/xxx.html` 加载。**加载本地 rawfile 不需要
  `ohos.permission.INTERNET`**（该权限只在加载网络地址时才需要；实测
  `OnPageEnd httpStatusCode:200` / `net_error=0`）。所以本应用保持**零权限**：
  HAP 内 `module.json` 无 `requestPermissions`，系统 `bm dump` 为 `reqPermissions: []`。
  **一旦加联网能力，必须同步补权限声明 + 同步改 `privacy.html` 的权限表格**，
  两边不一致就是「过度申请」或「漏报」驳回点。
- **ArkWeb 首帧延迟 ≠ 加载失败**：第一次拉起 ArkWeb 要另起渲染进程，模拟器上
  首帧可能等几十秒。判断方法：`uitest dumpLayout` 看无障碍树 —— **DOM 在且坐标对**
  就是渲染慢，不是加载失败。页面要加 `LoadingProgress`，`onPageEnd` 再撤掉。
- **API 12 的 `WebviewController` 没有 `destroy()`**（那是更晚版本才加的）；
  页面销毁时框架自动解绑控制器、销毁 JS 运行环境。别照抄新版本文章。
- **AGC 后台要填的隐私政策 URL 必须公网可访问（HTTPS）**，应用内的
  `resource://rawfile` 只是兜底。把同一份 `privacy.html`（零依赖单文件）
  原样部署到静态托管即可。
- **上架应用名统一为「Media Studio」**：脚手架占位 `MS Verify` 已清除 ——
  `AppScope/resources/base/element/string.json` 的 `app_name` 是唯一真源
  （`AppScope/app.json5` 的 `label` 指向它），桌面图标名 / 窗口标题栏 /
  任务管理器标题三处一起变。改名字时**同步检查** `privacy.html` 正文与
  README 标题，审核会核对「政策指向的应用」与「应用市场条目」是否同一个。
  NAPI 类型包名 `libmsverify` 是纯内部命名，与上架条目无关，**不要跟着改**。
- 详见 `docs/harmonyos-pc-port-architecture.md` §0.8、§10.13、§10.5 #32–#36。
