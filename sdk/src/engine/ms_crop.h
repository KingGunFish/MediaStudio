// sdk/src/engine/ms_crop.h
//
// In-process implementation of the video crop pipeline.
//
// The Windows build renders the crop in the Electron main process
// (electron-app/src/main/videoCrop.ts): it turns the semantic pan/zoom
// transform of the preview into an ffmpeg filter chain and drives the CLI.
// HarmonyOS cannot spawn ffmpeg.exe, so the OHOS build performs the same work
// inside the process through ms_inproc_exec.h.
//
// The geometry is a direct port of buildFilterChain() from videoCrop.ts, so
// both platforms cut the very same rectangle and place it on the canvas at
// the very same spot.

#ifndef MS_CROP_H
#define MS_CROP_H

#include <cstdint>
#include <string>

#include "ms_pipeline.h"

namespace ms {

struct VideoCropOptions {
    // Size of the output canvas.
    int output_width = 0;
    int output_height = 0;
    // Source pixels per canvas pixel.
    double scale = 1.0;
    // Top-left corner of the video, in canvas coordinates.
    double offset_x = 0.0;
    double offset_y = 0.0;
    // '#rrggbb' - fills the area the video does not cover.
    std::string background = "#000000";
    // 0 (lossless) .. 51 (worst). Interpreted by the encoder.
    int crf = 23;
    // The OHOS engine is video only; the audio track is not carried over.
    bool keep_audio = false;
    // Size of the source frame the transform refers to. 0 falls back to the
    // probed size (rotation aware).
    int source_width = 0;
    int source_height = 0;
};

struct VideoCropResult {
    int output_width = 0;
    int output_height = 0;
    int frame_count = 0;
    int64_t file_size = 0;
    int64_t duration_ms = 0;
};

// Builds the three stage filter chain (crop -> scale -> pad) that reproduces
// the pan/zoom transform of the preview.
std::string build_crop_filter_chain(const VideoCropOptions& opts, int src_w, int src_h);

// Re-encodes a video into a fixed size canvas, in-process.
int video_crop_inproc(const std::string& input_path,
                      const std::string& output_path,
                      const VideoCropOptions& opts,
                      VideoCropResult* result,
                      PipelineProgressFn progress, void* user_data);

}  // namespace ms

#endif  // MS_CROP_H
