#!/bin/bash
# Stage the cross-compiled FFmpeg into the HarmonyOS DevEco project:
#   - headers    -> harmony-app/entry/src/main/cpp/third_party/ffmpeg/include
#   - shared libs -> harmony-app/entry/libs/<abi>
#
# Both are build artefacts and are not tracked by git.
#
# Usage: tools/stage-ffmpeg-ohos.sh [x86_64|aarch64 ...]
#        (no argument = every architecture that has a build directory)
set -e

# shellcheck source=tools/ohos-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ohos-env.sh"

INC="$MS_HARMONY_APP/entry/src/main/cpp/third_party/ffmpeg/include"
LIBS="$MS_HARMONY_APP/entry/libs"

ARCHES=("$@")
if [ ${#ARCHES[@]} -eq 0 ]; then
  ARCHES=()
  for d in "$MS_OHOS_WORK"/build-ohos-*; do
    [ -d "$d" ] || continue
    ARCHES+=("$(basename "$d" | sed 's/^build-ohos-//')")
  done
fi

if [ ${#ARCHES[@]} -eq 0 ]; then
  echo "no build directories found under $MS_OHOS_WORK" >&2
  exit 1
fi

# The public headers are copied from the FFmpeg source tree. They are the same
# for every architecture, so they are staged once. Bail out before touching
# $INC if that tree is gone, otherwise the include directory would be wiped and
# left empty.
if [ ! -d "$FFMPEG_SRC_DIR/libavutil" ]; then
  echo "FFmpeg source tree not found: $FFMPEG_SRC_DIR" >&2
  echo "Re-extract the FFmpeg 7.1.1 source before staging." >&2
  exit 1
fi

rm -rf "$INC"
mkdir -p "$INC"
for L in libavutil libavcodec libavformat libavfilter libswscale libswresample; do
  mkdir -p "$INC/$L"
  cp "$FFMPEG_SRC_DIR/$L"/*.h "$INC/$L/"
done
echo "shared headers: $(find "$INC" -name '*.h' | wc -l)"

for ARCH in "${ARCHES[@]}"; do
  BUILD="$MS_OHOS_WORK/build-ohos-$ARCH"
  [ -d "$BUILD" ] || { echo "skip $ARCH (no build dir)"; continue; }

  case "$ARCH" in
    x86_64)  ABI=x86_64 ;;
    aarch64) ABI=arm64-v8a ;;
    *) echo "unknown arch mapping: $ARCH"; exit 1 ;;
  esac

  # Headers that encode the architecture. config.h and libavutil/avconfig.h
  # differ between x86_64 and aarch64, so they live in an ABI overlay
  # directory that the CMake include path picks up first; see
  # harmony-app/entry/src/main/cpp/CMakeLists.txt.
  mkdir -p "$INC/$ABI/libavutil"
  cp "$BUILD/config.h" "$INC/$ABI/"
  cp "$BUILD/libavutil/avconfig.h" "$INC/$ABI/libavutil/"
  cp "$BUILD/libavutil/ffversion.h" "$INC/$ABI/libavutil/"
  echo "$ABI headers: $(find "$INC/$ABI" -name '*.h' | wc -l)"

  # Shared libraries.
  mkdir -p "$LIBS/$ABI"
  for L in avutil avcodec avformat avfilter swscale swresample; do
    if [ -f "$BUILD/lib$L/lib$L.so" ]; then
      cp "$BUILD/lib$L/lib$L.so" "$LIBS/$ABI/"
      cp "$BUILD/lib$L/lib$L.so."* "$LIBS/$ABI/" 2>/dev/null || true
    fi
  done
  echo "$ABI libs:"; ls -lh "$LIBS/$ABI" | tail -n +2
done
