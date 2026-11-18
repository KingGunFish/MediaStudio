#!/bin/bash
# Cross-compile FFmpeg 7.1.1 for HarmonyOS with the OHOS NDK.
#
# Deliberately trimmed to exactly the components Media Studio needs, which
# keeps the build fast and proves the *specific* capability set the port
# depends on (geq / alphamerge / palettegen / paletteuse + gif/ffv1/png).
#
#   --disable-gpl --disable-nonfree --enable-version3   LGPL v3, no GPL taint
#   --disable-programs                                   HarmonyOS may not run
#                                                       bundled executables
#   --disable-everything + explicit --enable-*           minimum filter set
#
# Usage: tools/build-ffmpeg-ohos.sh <x86_64|aarch64>
#
# Environment:
#   FFMPEG_SRC_DIR   extracted FFmpeg source tree (default: tmp/ohos-ffmpeg/dl/ffmpeg-7.1.1)
#   MS_OHOS_WORK     work directory for build outputs
#   ASM_FLAG         extra configure flags, e.g. ASM_FLAG=--disable-asm
set -e

ARCH="${1:-x86_64}"

# shellcheck source=tools/ohos-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ohos-env.sh"

SRC="$FFMPEG_SRC_DIR"
BUILD="$MS_OHOS_WORK/build-ohos-$ARCH"
TOOLBIN="$MS_OHOS_TOOLCHAIN"

case "$ARCH" in
  x86_64)  TARGET=x86_64-linux-ohos ;;
  aarch64) TARGET=aarch64-linux-ohos ;;
  *) echo "unknown arch: $ARCH"; exit 1 ;;
esac

if [ ! -d "$SRC" ]; then
  echo "FFmpeg source tree not found: $SRC" >&2
  echo "Set FFMPEG_SRC_DIR to an extracted ffmpeg-7.1.1 tree." >&2
  exit 1
fi

# Git Bash supplies sh/sed/awk/grep/perl; native (mingw32) make needs a
# Windows-style SHELL path, otherwise it would try to exec "/bin/sh".
export SHELL="D:\\ProgramFiles\\Git\\usr\\bin\\sh.exe"
export PATH="$TOOLBIN:$PATH"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# --- configure -------------------------------------------------------------
"$SRC/configure" \
  --target-os=linux \
  --arch="$ARCH" \
  --cross-prefix="${ARCH}-linux-ohos-" \
  --enable-cross-compile \
  --cc="${ARCH}-linux-ohos-clang" \
  --cxx="${ARCH}-linux-ohos-clang++" \
  --ar="${ARCH}-linux-ohos-ar" \
  --nm="${ARCH}-linux-ohos-nm" \
  --ranlib="${ARCH}-linux-ohos-ranlib" \
  --strip="${ARCH}-linux-ohos-strip" \
  --extra-cflags="-D__MUSL__ -fPIC" \
  --extra-ldflags="-fuse-ld=lld" \
  --enable-shared --disable-static \
  --disable-programs --disable-doc --disable-debug \
  --disable-gpl --disable-nonfree --enable-version3 \
  --disable-network --disable-avdevice \
  --disable-vulkan --disable-libdrm --disable-vaapi --disable-vdpau \
  --disable-sdl2 --disable-xlib --disable-libxcb --disable-iconv \
  ${ASM_FLAG:-} \
  --disable-everything \
  --enable-protocol=file \
  --enable-demuxer=mov,matroska,webm,avi,image2,gif,flv,mpegts,rawvideo \
  --enable-muxer=mov,matroska,webm,avi,image2,gif,null,rawvideo \
  --enable-decoder=h264,hevc,vp8,vp9,av1,mjpeg,png,gif,rawvideo,ffv1 \
  --enable-parser=h264,hevc,vp8,vp9,av1,mjpeg,png,gif \
  --enable-encoder=gif,ffv1,png,mjpeg,rawvideo \
  --enable-bsf=h264_mp4toannexb \
  --enable-swscale --enable-avfilter \
  --enable-filter=fps,scale,format,split,trim,setpts,reverse,concat,geq,alphaextract,alphamerge,palettegen,paletteuse,crop,pad,color,overlay,rotate,transpose,hflip,vflip,copy,null \
  2>&1 | tail -40

echo "=== configure done, fixing makefile include path ==="
# configure writes MSYS-style paths (/d/...) into ffbuild/config.mak and a stub
# Makefile that includes the source Makefile. Native (mingw32) make cannot
# resolve /d/..., so rewrite them to Windows-style paths that both make and
# clang.exe understand.
WIN_SRC="$(cygpath -m "$SRC")"
sed -i "s|^SRC_PATH=.*|SRC_PATH=$WIN_SRC|" ffbuild/config.mak
sed -i "s|^SRC_LINK=.*|SRC_LINK=$WIN_SRC|" ffbuild/config.mak
sed -i "1s|.*|include $WIN_SRC/Makefile|" Makefile
echo "  SRC_PATH -> $(grep '^SRC_PATH=' ffbuild/config.mak)"
echo "  Makefile -> $(cat Makefile)"

echo "=== building ==="
make -j4 2>&1 | tail -30

echo "=== artifacts ==="
ls -lh "$BUILD"/libav*/*.so 2>/dev/null || true
