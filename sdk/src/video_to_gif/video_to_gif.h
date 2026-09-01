// video_to_gif/video_to_gif.h - Internal helper
#pragma once

#include "media_studio.h"
#include "../ffmpeg/executor.h"
#include "../ffmpeg/probe.h"

#include <string>

namespace ms {

// Apply defaults to options.
void normalize_video_options(MsVideoToGifOptions& opts, const MediaInfo& info);

}  // namespace ms