#!/usr/bin/env bash
# build-unix.sh - Build media_studio SDK on Linux or macOS

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk="$root/sdk"
build="$sdk/build"

rm -rf "$build"
mkdir -p "$build"
cd "$build"

FFMPEG_BIN="$(command -v ffmpeg || echo ffmpeg)"
FFPROBE_BIN="$(command -v ffprobe || echo ffprobe)"

cmake "$sdk" \
    -DCMAKE_BUILD_TYPE=Release \
    -DFFMPEG_EXECUTABLE="$FFMPEG_BIN" \
    -DFFPROBE_EXECUTABLE="$FFPROBE_BIN"

cmake --build . --parallel

echo ""
echo "Built artifacts:"
ls -la "$build"/libmedia_studio.* 2>/dev/null || ls -la "$build"/media_studio.* 2>/dev/null || true
if [[ "$(uname)" == "Darwin" ]]; then
    ls -la "$build"/libmedia_studio.dylib 2>/dev/null || true
else
    ls -la "$build"/libmedia_studio.so 2>/dev/null || true
fi
echo ""
echo "Demo binary:"
ls -la "$build"/ms_demo 2>/dev/null || true