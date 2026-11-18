#!/bin/bash
# Common environment for the HarmonyOS (OHOS) cross-build scripts.
#
# Sourced by the other scripts in this directory; not meant to be run
# directly.
#
# Everything is overridable from the environment so that the scripts work on
# a different machine / SDK location without editing them.

# Repository root (this file lives in <repo>/tools).
MS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where the OHOS cross-build artefacts live. Not tracked by git.
MS_OHOS_WORK="${MS_OHOS_WORK:-$MS_ROOT/tmp/ohos-ffmpeg}"

# Extracted FFmpeg source tree. The build script does not download anything;
# see tools/README-ohos-build.md for how to obtain it.
FFMPEG_SRC_DIR="${FFMPEG_SRC_DIR:-$MS_OHOS_WORK/dl/ffmpeg-7.1.1}"

# HarmonyOS SDK "native" directory (contains llvm/ and sysroot/).
OHOS_SDK_ROOT="${OHOS_SDK_ROOT:-/d/IDEs/command-line-tools/sdk/default/openharmony/native}"

# Generated cross-toolchain wrappers.
MS_OHOS_TOOLCHAIN="${MS_OHOS_TOOLCHAIN:-$MS_OHOS_WORK/toolchain/bin}"

# The DevEco project that consumes the produced shared libraries.
MS_HARMONY_APP="${MS_HARMONY_APP:-$MS_ROOT/harmony-app}"
