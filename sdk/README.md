# media_studio SDK

视频转 GIF / GIF 抠图使背景透明的跨平台原生 SDK。

## 能力

| 能力 | 说明 |
|---|---|
| `ms_video_to_gif` | 视频 → 高质量 GIF(支持缩放、帧率调整、ping-pong 循环) |
| `ms_gif_keying` | GIF 抠图 → 透明背景 + 去除水印(支持 5 种算法) |

## 5 种抠图算法

| 算法 | 说明 | 适用 |
|---|---|---|
| `MS_KEYING_BRIGHTNESS` | 亮度阈值(深色背景) | `lum < 阈值` |
| `MS_KEYING_WHITE_PIXEL` | 白色像素(三通道阈值) | `R/G/B 都 > 阈值` |
| `MS_KEYING_CHROMA_KEY` | chroma key | 纯色背景 |
| `MS_KEYING_COLOR_DISTANCE` | 颜色欧几里得距离 + 通道兜底 | **推荐**:综合判断 |
| `MS_KEYING_RGB_MASK_SPLIT` | RGB + mask 拆分 + alphamerge | **最强**(本 SDK 创新)|

## 编译

### Windows (MSVC)
```cmd
mkdir build && cd build
cmake .. -DFFMPEG_EXECUTABLE="C:\path\to\ffmpeg.exe"
cmake --build . --config Release
```

### Windows (MinGW / clang)
```bash
cmake -G "Unix Makefiles" \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_MAKE_PROGRAM=path/to/mingw32-make.exe \
  -DFFMPEG_EXECUTABLE="C:/path/to/ffmpeg.exe" ..
make -j 4
```

### Linux / macOS
```bash
./tools/build/build-unix.sh
```

## 产物

- `libmedia_studio.so` / `.dylib` / `.dll` — 主 SDK
- `ms_demo` — CLI 演示

## CLI 用法

```bash
# 视频转 GIF
ms_demo video2gif input.mp4 output.gif

# GIF 抠图(默认 RGB_MASK_SPLIT 算法)
ms_demo keying input.gif output.gif

# GIF 抠图指定算法
ms_demo keying input.gif output.gif distance
```

## C API 摘要

```c
#include "media_studio.h"

// 初始化
MsVideoToGifOptions vopts;
ms_video_to_gif_options_init(&vopts);
vopts.width = 480;
vopts.fps = 12;
vopts.ping_pong = true;

MsVideoToGifResult vresult;
MsError code = ms_video_to_gif(
    "input.mp4", "out.gif", &vopts, &vresult, NULL, NULL);

// 抠图
MsKeyingOptions kopts;
ms_keying_options_init(&kopts);
kopts.algorithm = MS_KEYING_RGB_MASK_SPLIT;
kopts.use_channel_fallback = true;  // 自动处理帧间背景色变化

MsKeyingResult kresult;
code = ms_gif_keying("in.gif", "out.gif", &kopts, &kresult, NULL, NULL);

// 异步版本
MsTask* task = ms_video_to_gif_async(
    "input.mp4", "out.gif", &vopts, on_complete, NULL);
// ... 之后
float p = ms_task_progress(task);
MsError result = ... ;
ms_task_free(task);
```

## 关键设计

1. **ffmpeg 进程调用**(不用 libav)*,跨发行版兼容
2. **CreateProcessW**(Windows)* 直接支持 Unicode 路径(中文/日文等)
3. **RGB + mask 拆分 + alphamerge**:避开 ffmpeg 把"alpha=0 像素 RGB 改为 255"的陷阱
4. **颜色距离 + 通道阈值兜底**:处理豆包 AI 等视频的"白闪"问题
5. **静态链接 C++ runtime**:产物 .dll 不依赖 libc++.dll / libunwind.dll

## 依赖

- ffmpeg / ffprobe(系统 PATH 或自定义路径)
- C++17 编译器(MSVC 2019+, GCC 9+, Clang 10+)
- CMake 3.16+
- pthreads(Unix)

## License

MIT
