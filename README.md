# Media Studio

一个桌面端视频 / GIF 处理工具（Electron + C++ SDK），把视频或 GIF 转成**去背景透明 GIF**，自带 5 种抠图算法。

## 功能

- 视频转GIF（可锁定宽高比、限制时长/体积）
- GIF抠图（5 种算法，输出透明 GIF）
- 图片转黑白（1 位 BMP + C 数组 / BIN，用于墨水屏等单色屏开发，Img2Lcd 风格）
- 应用图标生成（Android / iOS / HarmonyOS 上架图标一键全量输出，iOS 自动去 alpha 通道）

## 下载与安装（开箱即用）

GitHub Releases 提供两种开箱即用包，均**已内置 ffmpeg / ffprobe（默认 LGPL 版，MIT 兼容）**，
程序优先从自身目录 `resources/sdk/` 调用，无需在系统 PATH 安装 ffmpeg，也无需任何额外下载：

- **安装版** `Media Studio-1.0.0-setup.exe`：双击一键安装（默认装到用户目录，无需管理员），
  自动创建开始菜单 / 桌面快捷方式，装完即用。
- **绿色版**（任选其一，免安装）：
  - `Media Studio-1.0.0-portable.exe`：单文件，双击自解压运行。
  - `Media Studio-1.0.0-win.zip`：解压后双击 `Media Studio.exe` 即可直接使用。

## 从源码开发

```bash
git clone https://github.com/KingGunFish/MediaStudio.git
cd MediaStudio
cd electron-app
npm install
npm run fetch:ffmpeg   # 把 ffmpeg/ffprobe 下载进 resources/sdk（默认 LGPL 版，MIT 兼容）
npm run package        # 构建并打包（会自动执行 fetch:ffmpeg）
```

- `npm run fetch:ffmpeg` 默认拉取 **LGPL** 构建（与本项目 MIT 许可兼容）；
  设 `FFMPEG_BUILD=gpl` 可改用完整 GPL 构建；也可手动把 `ffmpeg(.exe)` / `ffprobe(.exe)` 放进
  `electron-app/resources/sdk/`。
- 若 `resources/sdk/` 已存在 **LGPL 兼容**的 ffmpeg，脚本会跳过下载（离线可用）；
  若检测到已存在的是 **GPL** 构建，则会自动重新拉取 LGPL 版以替换，保证发布产物与 MIT 兼容。
- 设 `FORCE_FETCH=1` 可强制重新下载（忽略本地已有文件）。
- **一条命令出全部发布包（Windows，需联网拉取 LGPL ffmpeg）**：`npm run release:win`
  （= `npm install` + 构建 + `fetch:ffmpeg` + 打包安装版 `setup.exe` / 绿色版 `portable.exe` / `win.zip`）。

### ffmpeg / ffprobe 的查找顺序（运行时）

1. 环境变量 `FFMPEG` / `FFPROBE`（仅源码构建时用于指定自定义路径）
2. 与 `ms_demo` 同目录的 `resources/sdk/ffmpeg(.exe)` / `ffprobe(.exe)`（打包后默认命中）
3. 系统 PATH 中的 `ffmpeg` / `ffprobe`

## 构建 C++ SDK（可选）

```bash
cd sdk
cmake -B build -DFFMPEG_EXECUTABLE=ffmpeg -DFFPROBE_EXECUTABLE=ffprobe
cmake --build build
```

或使用辅助脚本：`tools/build/build-windows.ps1`、`tools/build/build-unix.sh`。

## CLI 用法（ms_demo）

```bash
# 视频转 GIF
ms_demo video2gif input.mp4 output.gif

# 抠图（色度/绿幕）
ms_demo keying --algorithm chroma --color 0,255,0 input.gif output.gif
```

## 许可

- 本项目源码：MIT（见 `LICENSE`）
- ffmpeg / ffprobe：随二进制构建而定。默认 `fetch:ffmpeg` 拉取 LGPL 构建；
  若使用 GPL 构建，请遵循 GPL 条款。
