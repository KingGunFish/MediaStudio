# Media Studio

一个桌面端视频 / 动图处理工具（Electron + C++ SDK），可把视频、GIF 转换为**透明背景 GIF**。

## 功能

- **视频 → GIF**：把本地视频片段转换为 GIF，支持分辨率锁定（保持宽高比）。
- **GIF 抠图（去背景）**：5 种抠图算法，把背景变成透明：
  - `rgbSplit`：按 R/G/B 阈值拆分为「前景 / 背景 / 边缘」三色遮罩。
  - `distance`（颜色距离）：与指定背景色做颜色距离判断透明。
  - `brightness`（亮度）：按亮度阈值。
  - `white`（白底）：接近白色的像素变透明。
  - `chroma`（色度键）：类绿幕 / 蓝幕抠像。
- **跨平台 C++ SDK**：`media_studio` 核心库 + `ms_demo` 命令行示例，可独立在 CLI 中使用。

## 目录结构

```
electron-app/    Electron 桌面前端（React 渲染进程 + TypeScript 主进程）
sdk/             C++ SDK：视频转 GIF、GIF 抠图、ffmpeg 执行封装
  src/           核心库源码
  examples/      ms_demo 命令行示例
  tests/         单元测试 / 示例
docs/            文档（待补充）
tools/           辅助脚本
resources/sdk/   预编译的 Windows SDK 二进制（ms_demo.exe / libmedia_studio.dll）
```

## 依赖

- **Node.js** ≥ 18（用于 Electron 应用与构建）
- **ffmpeg / ffprobe**：打包的 SDK 二进制会从系统 `PATH` 解析 `ffmpeg` / `ffprobe`。
  请自行安装并将其加入 `PATH`；也可用环境变量 `FFMPEG` / `FFPROBE` 覆盖路径（仅对从源码构建的 SDK 生效）。
- **CMake** + C++ 编译器（仅当你需要从源码重新构建 SDK）

## 使用（开箱即用 Windows 版）

下载 Release 中的安装包 `Media Studio-1.0.0-setup.exe` 安装，或解压 `win-unpacked/` 直接运行 `Media Studio.exe`。
应用内置预编译 SDK，只要本机 `PATH` 中能找到 `ffmpeg` 即可工作。

## 从源码构建

### 1. 构建 SDK（可选，Windows 示例）

```bash
cd sdk
cmake -B build -DFFMPEG_EXECUTABLE=ffmpeg -DFFPROBE_EXECUTABLE=ffprobe
cmake --build build
# 产物：build/ms_demo.exe、build/libmedia_studio.dll
# 如需打包进桌面应用，复制到 electron-app/resources/sdk/
```

> 注意：`CMakeLists.txt` 会把 `FFMPEG_EXECUTABLE` / `FFPROBE_EXECUTABLE` 编译进二进制。
> 开源构建请使用 `ffmpeg` / `ffprobe`（从 `PATH` 解析）或绝对路径，勿提交含个人路径的缓存。

### 2. 构建桌面应用

```bash
cd electron-app
npm install
npm run build          # 构建渲染进程 + 主进程
npm run package:win    # 打包 Windows 安装包（输出 release/）
```

## 命令行示例（SDK）

```bash
# 视频转 GIF
ms_demo video2gif input.mp4 output.gif

# GIF 抠图（颜色距离算法，背景色 RGB 78 146 226，阈值 60）
ms_demo keying --algo distance --bg-r 78 --bg-g 146 --bg-b 226 --threshold 60 input.gif output.gif
```

## 许可证

[MIT](./LICENSE) © KingGunFish
