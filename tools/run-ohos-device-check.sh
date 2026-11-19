#!/bin/bash
# Run the Media Studio engine self-check on a connected HarmonyOS device.
#
# The check installs the debug HAP, opens the "self check" page of the
# application, reads the probe log and pulls the produced media files so that
# they can be compared with the Windows build pixel by pixel.
#
# Usage: tools/run-ohos-device-check.sh [target] [out-dir]
#
#   target   hdc connect key of the device (default: the first USB target)
#   out-dir  where the artefacts are stored
#            (default: tmp/ohos-device-check/<target>)
#
# Environment:
#   HDC                hdc binary (default: the one in the OHOS SDK)
#   HAP                HAP to install (default: the debug build output)
#   PYTHON             python interpreter used to read the UI tree
#   MS_GOLD_KEY_GIF    Windows reference GIF for the keying pipeline
#   MS_GOLD_ROT90_GIF  Windows reference GIF for the rotated pipeline
set -e

# shellcheck source=tools/ohos-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ohos-env.sh"

BUNDLE="xyz.demonshir.mediastudio.hm"
HDC="${HDC:-$OHOS_SDK_ROOT/../toolchains/hdc.exe}"
HAP="${HAP:-$MS_HARMONY_APP/entry/build/default/outputs/default/entry-default-unsigned.hap}"
GOLD_KEY="${MS_GOLD_KEY_GIF:-$MS_ROOT/tmp/harmony-verify/key/win_gold_key.gif}"
GOLD_ROT90="${MS_GOLD_ROT90_GIF:-$MS_ROOT/tmp/harmony-verify/rot/win_gold_rot90.gif}"

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON=python
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "no python interpreter found (set PYTHON=...)" >&2
  exit 1
fi

# hdc is a native Windows program. MSYS would rewrite the POSIX looking device
# paths (/data/local/tmp/..., /data/app/...) into Windows paths, so the
# conversion is disabled for hdc only. Host paths are converted explicitly
# with cygpath.
hdc() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$HDC" "$@"
}

win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # The emulators show up as TCP, the real hardware as USB.
  TARGET="$(hdc list targets -v | awk '$2 == "USB" { print $1; exit }')"
fi
if [ -z "$TARGET" ]; then
  echo "no USB device found; pass the hdc connect key as the first argument" >&2
  exit 1
fi

# A TCP target carries a colon ("127.0.0.1:5557"), which cannot appear in a
# Windows path, so the target is sanitised before it becomes a directory name.
SAFE_TARGET="$(printf '%s' "$TARGET" | tr -c 'A-Za-z0-9._-' '_')"
OUT_DIR="${2:-$MS_ROOT/tmp/ohos-device-check/$SAFE_TARGET}"
mkdir -p "$OUT_DIR"

echo "=== target: $TARGET ==="
echo "=== install ==="
hdc -t "$TARGET" install -r "$(win_path "$HAP")"

echo "=== wake up and launch ==="
hdc -t "$TARGET" shell 'power-shell wakeup' >/dev/null 2>&1 || true
hdc -t "$TARGET" shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
hdc -t "$TARGET" shell "aa start -b $BUNDLE -a EntryAbility"
sleep 8

echo "=== open the self check page ==="
DUMP="$(hdc -t "$TARGET" shell "uitest dumpLayout -b $BUNDLE -i -m false" 2>&1)"
REMOTE="$(printf '%s\n' "$DUMP" | sed -n 's/.*saved to:\([^[:space:]]*\).*/\1/p')"
if [ -z "$REMOTE" ]; then
  echo "could not read the layout: $DUMP" >&2
  exit 1
fi
hdc -t "$TARGET" file recv "$REMOTE" "$(win_path "$OUT_DIR/layout.json")" >/dev/null

# The navigation entry is the only node with this label; its bounds give the
# tap position. The label is written as a code point escape so that this
# script stays pure ASCII.
XY="$("$PYTHON" - "$(win_path "$OUT_DIR/layout.json")" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    tree = json.load(handle)


def walk(node):
    if not isinstance(node, dict):
        return False
    attrs = node.get('attributes') or {}
    if attrs.get('text') == '\u81ea\u68c0':
        numbers = [int(v) for v in re.findall(r'-?\d+', attrs.get('bounds', ''))]
        if len(numbers) >= 4:
            print((numbers[0] + numbers[2]) // 2, (numbers[1] + numbers[3]) // 2)
            return True
    for child in node.get('children') or []:
        if walk(child):
            return True
    return False


roots = tree if isinstance(tree, list) else [tree]
for root in roots:
    if walk(root):
        break
PY
)"
if [ -z "$XY" ]; then
  echo "could not locate the self check entry in the layout" >&2
  exit 1
fi
echo "self check entry at: $XY"
hdc -t "$TARGET" shell "uitest uiInput click $XY"
sleep 20

echo "=== probe log ==="
hdc -t "$TARGET" shell 'hilog -x -T MsVerify' 2>&1 \
  | grep -E 'P([1-9]|1[0-5]) ' | tee "$OUT_DIR/probes.log"

echo "=== pull artefacts ==="
SANDBOX="/data/app/el2/100/base/$BUNDLE/haps/entry/files"
for f in out.gif out_rot90.gif out_key.gif app_out.gif app_key.gif app_crop.avi app_frame.png; do
  hdc -t "$TARGET" file recv "$SANDBOX/$f" "$(win_path "$OUT_DIR/$f")" >/dev/null 2>&1 || true
done
ls -l "$OUT_DIR"

echo "=== pixel comparison against the Windows build ==="
if [ -f "$GOLD_KEY" ] && [ -f "$OUT_DIR/out_key.gif" ]; then
  "$MS_ROOT/tools/compare-gif.sh" "$GOLD_KEY" "$OUT_DIR/out_key.gif"
else
  echo "skipped the keying comparison (golden file or output missing)"
fi
if [ -f "$GOLD_ROT90" ] && [ -f "$OUT_DIR/out_rot90.gif" ]; then
  "$MS_ROOT/tools/compare-gif.sh" "$GOLD_ROT90" "$OUT_DIR/out_rot90.gif"
else
  echo "skipped the rotation comparison (golden file or output missing)"
fi

echo "=== artefacts in $OUT_DIR ==="
