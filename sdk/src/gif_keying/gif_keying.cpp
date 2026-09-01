// gif_keying/gif_keying.cpp
#include "mask_builder.h"
#include "media_studio.h"

#include "../ffmpeg/executor.h"
#include "../ffmpeg/probe.h"

using ms::MediaInfo;
using ms::probe_gif;

#include <algorithm>
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

namespace ms {

// Normalize keying options (defaults).
void normalize_keying_options(MsKeyingOptions& opts) {
    if (opts.brightness_threshold <= 0) opts.brightness_threshold = 55;
    if (opts.white_threshold <= 0) opts.white_threshold = 215;
    if (opts.distance_threshold <= 0) opts.distance_threshold = 1500;
    if (opts.bg_r <= 0 && opts.bg_g <= 0 && opts.bg_b <= 0) {
        opts.bg_r = 231;
        opts.bg_g = 225;
        opts.bg_b = 223;
    }
    if (opts.channel_threshold <= 0) opts.channel_threshold = 220;
    if (!opts.use_channel_fallback) {
        // Default behavior for COLOR_DISTANCE family: keep fallback on.
        if (opts.algorithm == MS_KEYING_COLOR_DISTANCE ||
            opts.algorithm == MS_KEYING_RGB_MASK_SPLIT) {
            opts.use_channel_fallback = true;
        }
    }
    if (opts.watermark_br_x_ratio <= 0) opts.watermark_br_x_ratio = 83;
    if (opts.watermark_br_y_ratio <= 0) opts.watermark_br_y_ratio = 75;
    if (opts.watermark_tl_x_ratio <= 0) opts.watermark_tl_x_ratio = 20;
    if (opts.watermark_tl_y_ratio <= 0) opts.watermark_tl_y_ratio = 15;
    if (opts.max_colors <= 0) opts.max_colors = 255;
    else if (opts.max_colors > 256) opts.max_colors = 256;
    if (opts.quality <= 0) opts.quality = 90;
    if (opts.log_level == 0) opts.log_level = 24;
}

}  // namespace ms


// === Public C API ===

extern "C" MS_API void ms_keying_options_init(MsKeyingOptions* opts) {
    if (!opts) return;
    opts->algorithm = MS_KEYING_RGB_MASK_SPLIT;  // best default
    opts->brightness_threshold = 55;
    opts->white_threshold = 215;
    opts->distance_threshold = 1500;
    opts->bg_r = 231;
    opts->bg_g = 225;
    opts->bg_b = 223;
    opts->use_channel_fallback = true;
    opts->channel_threshold = 220;
    opts->watermark_bottom_right = true;
    opts->watermark_top_left = true;
    opts->watermark_br_x_ratio = 83;
    opts->watermark_br_y_ratio = 75;
    opts->watermark_tl_x_ratio = 20;
    opts->watermark_tl_y_ratio = 15;
    opts->ping_pong = true;
    opts->max_colors = 255;
    opts->quality = 90;
    opts->log_level = 24;
}

extern "C" MS_API MsError ms_gif_keying(
    const char* input_path,
    const char* output_path,
    const MsKeyingOptions* options,
    MsKeyingResult* result,
    MsProgressCallback callback,
    void* user_data
) {
    if (!input_path || !output_path) return MS_ERR_INVALID_ARG;

    MsKeyingOptions opts;
    if (options) opts = *options;
    else ms_keying_options_init(&opts);

    ms::normalize_keying_options(opts);

    // 1. Probe input.
    MediaInfo info;
    if (!ms::probe_gif(input_path, info)) {
        return MS_ERR_INVALID_FORMAT;
    }

    int frame_count = info.nb_frames;
    if (frame_count <= 0) frame_count = 76;

    // 2. Build filter.
    std::string filter;
    if (!ms::build_keying_filter_complex(opts, info.width, info.height,
                                        frame_count, opts.ping_pong, filter)) {
        return MS_ERR_INVALID_ARG;
    }

    // 3. Run filter → mkv.
    std::string tmp_mkv = std::string(output_path) + ".tmp.mkv";
    std::remove(tmp_mkv.c_str());

    std::vector<std::string> args_a = {
        "-y", "-v", std::to_string(std::max(opts.log_level, 32)),
        "-i", input_path,
        "-filter_complex", filter,
        "-map", "[v]",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuva420p",
        tmp_mkv
    };

    auto progress_fn_a = [callback, user_data]
                          (float p, const std::string& msg) -> bool {
        if (callback) callback(p < 0 ? 0.6f : p * 0.7f, msg.c_str(), user_data);
        return true;
    };

    auto r = ms::run_ffmpeg(args_a, progress_fn_a, info.duration_seconds);
    if (r.exit_code != 0) {
        std::remove(tmp_mkv.c_str());
        return MS_ERR_FFMPEG_FAILED;
    }

    // 4. palettegen + paletteuse → gif.
    std::string tmp_pal = std::string(output_path) + ".pal.png";
    std::remove(tmp_pal.c_str());

    std::ostringstream pgvf;
    pgvf << "palettegen=stats_mode=diff:max_colors=" << opts.max_colors
         << ":reserve_transparent=1";
    std::vector<std::string> args_c1 = {
        "-y", "-v", std::to_string(opts.log_level),
        "-i", tmp_mkv, "-vf", pgvf.str(), tmp_pal
    };
    r = ms::run_ffmpeg(args_c1, nullptr, -1.0);
    if (r.exit_code != 0) {
        std::remove(tmp_mkv.c_str());
        std::remove(tmp_pal.c_str());
        return MS_ERR_FFMPEG_FAILED;
    }

    std::vector<std::string> args_c2 = {
        "-y", "-v", std::to_string(opts.log_level),
        "-i", tmp_mkv, "-i", tmp_pal,
        "-lavfi", "paletteuse=dither=sierra2_4a",
        "-loop", "0",
        output_path
    };

    auto progress_fn_c = [callback, user_data]
                          (float p, const std::string& msg) -> bool {
        if (callback) callback(p < 0 ? 0.9f : 0.7f + p * 0.3f, msg.c_str(), user_data);
        return true;
    };

    r = ms::run_ffmpeg(args_c2, progress_fn_c, -1.0);

    std::remove(tmp_mkv.c_str());
    std::remove(tmp_pal.c_str());

    if (r.exit_code != 0) {
        return MS_ERR_FFMPEG_FAILED;
    }

    // 5. Probe output.
    MediaInfo out_info;
    if (ms::probe_gif(output_path, out_info) && result) {
        result->input_frame_count = info.nb_frames;
        result->output_frame_count = out_info.nb_frames;
        result->output_width = out_info.width;
        result->output_height = out_info.height;
        // file size:
        FILE* f = std::fopen(output_path, "rb");
        if (f) {
            std::fseek(f, 0, SEEK_END);
            result->file_size = static_cast<int64_t>(std::ftell(f));
            std::fclose(f);
        } else {
            result->file_size = 0;
        }
        result->duration_ms = 0;
    }

    if (callback) callback(1.0f, "done", user_data);

    return MS_OK;
}