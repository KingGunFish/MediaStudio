#include "media_studio.h"

namespace {
const char* kVersion = "0.1.0";
}

extern "C" MS_API const char* ms_version(void) {
    return kVersion;
}