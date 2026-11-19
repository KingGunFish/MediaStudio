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
