#!/bin/bash
# Compare two GIF files pixel by pixel.
#
# The compressed streams of two GIFs can differ in size while showing exactly
# the same pictures (different encoder settings, different palette packing).
# This tool decodes both files to raw RGB24 and compares the raw bytes, which
# is the comparison that actually matters for a port: "does the HarmonyOS
# build produce the same pictures as the Windows build?".
#
# Usage: tools/compare-gif.sh <reference.gif> <candidate.gif> [ffmpeg-binary]
#
# Environment:
#   MS_FFMPEG  ffmpeg binary used for the decode (default: the Windows SDK
#               copy that ships with the Electron app)
set -e

if [ $# -lt 2 ]; then
  echo "usage: $0 <reference.gif> <candidate.gif> [ffmpeg-binary]" >&2
  exit 2
fi

MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$1"
CAND="$2"
FFMPEG="${3:-${MS_FFMPEG:-$MS_ROOT/electron-app/resources/sdk/ffmpeg.exe}}"
FFPROBE="${4:-${FFMPEG%ffmpeg.exe}ffprobe.exe}"

for f in "$REF" "$CAND"; do
  if [ ! -f "$f" ]; then
    echo "missing file: $f" >&2
    exit 2
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== container stats ==="
for f in "$REF" "$CAND"; do
  echo "--- $f"
  "$FFPROBE" -v error -select_streams v:0 \
    -show_entries 'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration' \
    -of default=nw=1 "$f"
  echo "bytes=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
done

echo "=== decode to raw rgb24 ==="
"$FFMPEG" -v error -y -i "$REF" -f rawvideo -pix_fmt rgb24 "$TMP/ref.raw"
"$FFMPEG" -v error -y -i "$CAND" -f rawvideo -pix_fmt rgb24 "$TMP/cand.raw"
REF_SIZE=$(stat -c%s "$TMP/ref.raw" 2>/dev/null || stat -f%z "$TMP/ref.raw")
CAND_SIZE=$(stat -c%s "$TMP/cand.raw" 2>/dev/null || stat -f%z "$TMP/cand.raw")
echo "raw ref=$REF_SIZE cand=$CAND_SIZE"

if [ "$REF_SIZE" != "$CAND_SIZE" ]; then
  echo "RESULT: DIFFER (decoded frame count or geometry differs)"
  exit 1
fi

if cmp -s "$TMP/ref.raw" "$TMP/cand.raw"; then
  echo "RESULT: PIXEL IDENTICAL ($REF_SIZE raw bytes, 0 differences)"
  exit 0
fi

DIFFS=$(cmp -l "$TMP/ref.raw" "$TMP/cand.raw" | wc -l)
echo "RESULT: DIFFER ($DIFFS differing bytes out of $REF_SIZE)"
exit 1
