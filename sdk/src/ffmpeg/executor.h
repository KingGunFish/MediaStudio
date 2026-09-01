// ffmpeg/executor.h - Run ffmpeg subprocess and parse progress
#pragma once

#include <string>
#include <vector>
#include <functional>
#include <cstdint>

namespace ms {

struct FFmpegResult {
    int exit_code = 0;
    std::string stdout_output;
    std::string stderr_output;
    bool cancelled = false;
};

using ProgressFn = std::function<bool(float /* 0-1 */, const std::string& /* msg */)>;

// Returns true to continue, false to cancel.
FFmpegResult run_ffmpeg(
    const std::vector<std::string>& args,
    ProgressFn on_progress = nullptr,
    double total_duration_seconds = -1.0  // for progress calc; -1 means unknown
);

// Same for ffprobe (no progress).
FFmpegResult run_ffprobe(
    const std::vector<std::string>& args,
    std::string& stdout_out
);

}  // namespace ms