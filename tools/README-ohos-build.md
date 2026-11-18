# OHOS (HarmonyOS) 构建说明

本文说明如何为 `media-studio` 的鸿蒙版本构建 ffmpeg、装配进 DevEco 工程，以及如何做端到端像素对拍。

> 面向 Windows 宿主 + Git Bash。macOS / Linux 宿主请把 `OHOS_SDK_ROOT` 指向对应平台的 SDK native 目录即可，
> 交叉工具链包装脚本需要改成直接调用 SDK 里的 `clang`（见 `tools/gen-ohos-toolchain.sh`）。

---

## 0. 前置条件

| 依赖 | 本机路径（可改） | 说明 |
|---|---|---|
| HarmonyOS SDK (native) | `D:\IDEs\command-line-tools\sdk\default\openharmony\native` | 提供 `llvm/bin/clang.exe` 与 `sysroot/` |
| DevEco Studio JBR | `D:\ProgramFiles\DevEco Studio\jbr` | 打包 HAP 用的 JDK |
| DevEco 命令行工具 | `D:\IDEs\command-line-tools` | `hvigorw.bat` / `ohpm.bat` / `hdc` |
| Git Bash | `D:\ProgramFiles\Git\bin\bash.exe` | 跑 `tools/*.sh` |
| ffmpeg 源码 | `tmp/harmony-verify/dl/ffmpeg-7.1.1` | **仓库不含**，需自行下载（见下） |

所有路径都可用环境变量覆盖，默认值集中在 `tools/ohos-env.sh`：

```bash
MS_ROOT            # 仓库根目录（自动推导）
MS_OHOS_WORK       # 交叉构建工作目录，默认 tmp/ohos-ffmpeg
FFMPEG_SRC_DIR     # ffmpeg 源码树，默认 $MS_OHOS_WORK/dl/ffmpeg-7.1.1
OHOS_SDK_ROOT      # HarmonyOS SDK native 目录
MS_OHOS_TOOLCHAIN  # 生成的工具链包装目录，默认 $MS_OHOS_WORK/toolchain/bin
MS_HARMONY_APP     # DevEco 工程目录，默认 $MS_ROOT/harmony-app
```

## 1. 取得 ffmpeg 源码

构建固定在 **FFmpeg 7.1.1**（`libavcodec` 61.x）。下载后解压到 `FFMPEG_SRC_DIR`：

```
https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz
```

> 源码体积大（约 100 MB / 1.1 万个文件），**不进 git**——`tmp/` 已被 `.gitignore` 忽略。

## 2. 生成交叉工具链包装

```bash
tools/gen-ohos-toolchain.sh
```

HarmonyOS SDK 自带的 wrapper 名为 `<triple>-unknown-linux-ohos-clang`，而 ffmpeg 的 `configure`
要找经典的 `<triple>-linux-ohos-` 前缀并在 PATH 上查找。这个脚本在
`$MS_OHOS_TOOLCHAIN` 下生成对应的 wrapper，并固定 SDK wrapper 使用的 `--sysroot` 与 `-D__MUSL__`。

## 3. 交叉编译 ffmpeg

```bash
# x86_64（2in1 模拟器用）
tools/build-ffmpeg-ohos.sh x86_64

# aarch64（真机用）
tools/build-ffmpeg-ohos.sh aarch64
```

产物落在 `$MS_OHOS_WORK/build-ohos-<arch>/`。

**许可**：`--disable-gpl --disable-nonfree --enable-version3` → 纯 **LGPL v3**，无 GPL 传染。
构建结束会打印 `License: LGPL version 3 or later`，可与 `config.h` 里的
`CONFIG_GPL 0 / CONFIG_NONFREE 0 / CONFIG_VERSION3 1 / CONFIG_LGPLV3 1` 交叉核对。

### 3.1 Windows 宿主的已知限制

| 限制 | 现象 | 处置 |
|---|---|---|
| `make` 解析不了 MSYS 路径 | `Makefile:42: /d/.../tools/Makefile: No such file` | 脚本已在 configure 之后用 `sed` 把 stub Makefile 的 include、`config.mak` 的 `SRC_PATH`/`SRC_LINK` 改写为 Windows 路径 |
| ARM 汇编 `.S`/`.s` 大小写在 MSYS 下不匹配 | aarch64 缺 `hscale.s` | `ASM_FLAG=--disable-asm tools/build-ffmpeg-ohos.sh aarch64`（**产物无 NEON 汇编**，生产构建建议换 Linux 宿主 + Linux 版 OHOS NDK） |
| ffmpeg 7.1 的选项名 | `Unknown option "--disable-drm"` | 应为 `--disable-libdrm` |

### 3.2 组件清单不能随便改

构建用 `--disable-everything` + 显式 `--enable-*`，**漏配任何一个组件都会静默降级、不报错**：

| 组件 | 漏配后果 |
|---|---|
| `--enable-decoder=ffv1` | 中间文件（ffv1）无法回读，流水线中断 |
| `--enable-parser=gif` | GIF 解复用器的 `AVSTREAM_PARSE_FULL_RAW` 退化，帧数统计恒为 0（**不报错**） |
| `--enable-filter=hflip,vflip` | CLI 的 180° 旋转分支失效，竖拍视频方向错误（**不报错**） |

改完构建参数后，请核对生成配置里的对应开关：

```bash
grep -E 'CONFIG_(GIF_PARSER|FFV1_DECODER|HFLIP_FILTER|VFLIP_FILTER) ' \
  "$MS_OHOS_WORK/build-ohos-<arch>/config_components.h"
```

应全部为 `1`。

## 4. 装配进 DevEco 工程

```bash
tools/stage-ffmpeg-ohos.sh x86_64      # 或 aarch64
```

产出：

- 头文件 → `harmony-app/entry/src/main/cpp/third_party/ffmpeg/include/`（约 919 个）
- 共享库 → `harmony-app/entry/libs/<x86_64|arm64-v8a>/`

两者都是**构建产物**，已被 `.gitignore` 忽略，新克隆需要重新执行本步骤。

## 5. 打包 HAP

```powershell
$env:DEVECO_SDK_HOME='D:\IDEs\command-line-tools\sdk'
$env:JAVA_HOME='D:\ProgramFiles\DevEco Studio\jbr'
$env:PATH="$env:JAVA_HOME\bin;$env:PATH"
Set-Location 'D:\Develop\media-studio\harmony-app'
& 'D:\IDEs\command-line-tools\bin\ohpm.bat' install --all
& 'D:\IDEs\command-line-tools\bin\hvigorw.bat' --mode module -p product=default `
    -p module=entry@default -p buildMode=debug assembleHap --no-daemon
```

产物：`harmony-app/entry/build/default/outputs/default/entry-default-unsigned.hap`

> **签名**：`harmony-app/build-profile.json5` 刻意**不含** `signingConfigs`，因此只能产出 unsigned 包，
> 安装到设备需要设备允许调试安装。正式上架需自备与 bundleName `xyz.demonshir.mediastudio.hm`
> 绑定的 profile/证书，**签名配置不入库**。
>
> **Windows 宿主提示**：不要在调用 `hvigorw.bat` 前设置 `$ErrorActionPreference='Stop'`。
> PowerShell 5.1 会把原生命令写到 stderr 的普通 WARN（`No signingConfig found`）升级成
> `NativeCommandError` 并终止脚本，尽管 `BUILD SUCCESSFUL` 已经打印。

## 6. 安装与运行

```powershell
$hdc='D:\IDEs\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'; $t='127.0.0.1:5555'
& $hdc tconn $t                                  # 模拟器走 TCP，不会自动枚举
& $hdc -t $t install -r '<...>/entry-default-unsigned.hap'
& $hdc -t $t shell 'hilog -r'
& $hdc -t $t shell 'aa force-stop xyz.demonshir.mediastudio.hm'
& $hdc -t $t shell 'aa start -b xyz.demonshir.mediastudio.hm -a EntryAbility'
& $hdc -t $t shell 'hilog -x -T MsVerify'
```

应用沙箱**不可写**：`hdc file send` / `hdc shell cp` 都会被拒；`hdc file recv` 读取可行。
需要外部素材时，把它作为 **rawfile** 打进 HAP（`harmony-app/entry/src/main/resources/rawfile/`）。

## 7. 像素级对拍

设备产物与 Windows 黄金件的比较**不能比压缩流**（两端 ffmpeg 版本不同，压缩字节必然有差异），
要比较**解码后的画面**：

```bash
tools/compare-gif.sh <参考.gif> <候选.gif>
```

脚本会打印两端的容器统计（宽高 / 帧率 / 帧数 / 时长），再把双方解码为 rawvideo rgb24 逐字节比对，
输出 `RESULT: PIXEL IDENTICAL (N raw bytes, 0 differences)` 或差异字节数。

参考件位置：

| 用例 | Windows 黄金件 |
|---|---|
| 普通样例 | `electron-app/_test/out.gif` |
| 竖拍旋转样例 | `tmp/harmony-verify/rot/win_gold_rot90.gif`（需按 §8 自行生成） |

## 8. 重新生成旋转黄金件

R-03（自动旋转）的黄金用例由带 90° display matrix 的 mp4 生成：

```bash
ffmpeg -display_rotation 90 -i harmony-app/entry/src/main/resources/rawfile/test.mp4 \
       -c copy tmp/harmony-verify/rot/test_rot90.mp4
```

`-display_rotation` 是 ffmpeg 的**输入侧**选项：它给输入流挂上 display matrix，
`-c copy` 时 mov 封装器会把它写进 `tkhd`，于是文件自带旋转元数据。

对应的设备端回归样例已随工程提交：
`harmony-app/entry/src/main/resources/rawfile/test_rot90.mp4`。
