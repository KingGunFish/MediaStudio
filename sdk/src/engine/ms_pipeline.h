// sdk/src/engine/ms_pipeline.h
//
// In-process implementations of the Media Studio media pipelines.
//
// The Windows build drives the same pipelines through the ffmpeg CLI
// (sdk/src/video_to_gif/video_to_gif.cpp). HarmonyOS cannot spawn arbitrary
// executables, so the OHOS build runs the identical filter graphs inside the
// process through ms_inproc_exec.h.
//
// The filter strings, the intermediate file layout and the option defaults
// are kept identical to the Windows implementation so that both platforms
// produce the same output files.

#ifndef MS_PIPELINE_H
#define MS_PIPELINE_H

#include <cstdint>
#include <string>

namespace ms {

// Error codes, matching sdk/include/media_studio.h.
enum {
    MS_PIPE_OK = 0,
    MS_PIPE_ERR_INVALID_ARG = 1,
    MS_PIPE_ERR_FILE_NOT_FOUND = 2,
    MS_PIPE_ERR_FFMPEG_FAILED = 3,
    MS_PIPE_ERR_INVALID_FORMAT = 4,
    MS_PIPE_ERR_OUT_OF_MEMORY = 5,
    MS_PIPE_ERR_CANCELLED = 6,
    MS_PIPE_ERR_NOT_SUPPORTED = 7,
    MS_PIPE_ERR_INTERNAL = 99
};

struct VideoInfo {
    int width = 0;
    int height = 0;
    double fps = 0.0;
    int nb_frames = 0;
    double duration_seconds = 0.0;
    std::string codec_name;
    std::string pix_fmt;
    bool valid = false;
};

// Probes a media file. `count_frames` decodes the whole file to get the
// exact frame count; ffprobe's `nb_frames` field is only a container hint and
// is reported as 0 (N/A) for matroska.
bool probe_video(const std::string& path, VideoInfo& out, bool count_frames = false);

// Size of a file in bytes, 0 when it cannot be read.
int64_t file_size_of(const std::string& path);

struct VideoToGifOptions {
    int width = 0;
    int height = 0;
    int fps = 0;
    int max_colors = 255;
    bool ping_pong = true;
    int quality = 90;
    double start_seconds = 0.0;
    double end_seconds = -1.0;
    // Keep the intermediate files (tmp.mkv, tmp2.mkv, pal.png) next to the
    // output instead of deleting them. Used for byte-level comparison
    // against the Windows build.
    bool keep_intermediates = false;
};

struct VideoToGifResult {
    int frame_count = 0;
    int output_width = 0;
    int output_height = 0;
    int output_fps = 0;
    int64_t file_size = 0;
};

// Progress callback. Return false to cancel.
typedef bool (*PipelineProgressFn)(float progress, void* user_data);

// Video -> animated GIF, running entirely in-process.
//
// Pipeline (identical to sdk/src/video_to_gif/video_to_gif.cpp):
//   A  input  -> tmp.mkv    fps/scale/format=rgba, ffv1 level 3, yuva420p
//   B  tmp    -> tmp2.mkv   split/trim/reverse/concat (ping-pong)
//   C1 tmp2   -> pal.png    palettegen
//   C2 tmp2+pal -> out.gif  paletteuse, loop 0
int video_to_gif_inproc(const std::string& input_path,
                        const std::string& output_path,
                        const VideoToGifOptions& opts,
                        VideoToGifResult* result,
                        PipelineProgressFn progress, void* user_data);

}  // namespace ms

#endif  // MS_PIPELINE_H
