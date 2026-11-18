#!/bin/bash
# Generate OHOS cross-toolchain wrapper scripts for Git Bash / MSYS.
#
# The HarmonyOS SDK ships POSIX wrapper scripts named
#   <triple>-unknown-linux-ohos-clang
# but FFmpeg's configure expects the classic cross prefix
#   <triple>-linux-ohos-
# and looks the tools up on PATH. This script bridges the two and pins the
# sysroot / musl flags that the SDK wrappers use.
#
# Usage: tools/gen-ohos-toolchain.sh
set -e

# shellcheck source=tools/ohos-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ohos-env.sh"

SDK_WIN="$(cygpath -m "$OHOS_SDK_ROOT")"

mkdir -p "$MS_OHOS_TOOLCHAIN"

for TRIPLE in aarch64 x86_64; do
  case "$TRIPLE" in
    aarch64) TARGET=aarch64-linux-ohos ;;
    x86_64)  TARGET=x86_64-linux-ohos ;;
  esac
  PFX="${TRIPLE}-linux-ohos-"

  cat > "$MS_OHOS_TOOLCHAIN/${PFX}clang" <<EOF
#!/bin/sh
exec "$SDK_WIN/llvm/bin/clang.exe" -target $TARGET --sysroot=$SDK_WIN/sysroot -D__MUSL__ "\$@"
EOF

  cat > "$MS_OHOS_TOOLCHAIN/${PFX}clang++" <<EOF
#!/bin/sh
exec "$SDK_WIN/llvm/bin/clang++.exe" -target $TARGET --sysroot=$SDK_WIN/sysroot -D__MUSL__ "\$@"
EOF

  cat > "$MS_OHOS_TOOLCHAIN/${PFX}ld" <<EOF
#!/bin/sh
exec "$SDK_WIN/llvm/bin/ld.lld.exe" "\$@"
EOF

  for T in ar nm ranlib strip objcopy; do
    case $T in
      ar)      BIN=llvm-ar ;;
      nm)      BIN=llvm-nm ;;
      ranlib)  BIN=llvm-ranlib ;;
      strip)   BIN=llvm-strip ;;
      objcopy) BIN=llvm-objcopy ;;
    esac
    cat > "$MS_OHOS_TOOLCHAIN/${PFX}${T}" <<EOF
#!/bin/sh
exec "$SDK_WIN/llvm/bin/${BIN}.exe" "\$@"
EOF
  done

  chmod +x "$MS_OHOS_TOOLCHAIN/${PFX}"*
done

echo "generated wrappers in $MS_OHOS_TOOLCHAIN"
ls -1 "$MS_OHOS_TOOLCHAIN"
