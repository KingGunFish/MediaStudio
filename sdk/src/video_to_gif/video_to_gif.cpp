// video_to_gif/video_to_gif.cpp
#include "video_to_gif.h"
#include "media_studio.h"

#include "../ffmpeg/executor.h"
#include "../ffmpeg/probe.h"

using ms::MediaInfo;
using ms::probe_media;

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>

namespace ms {

void normalize_video_options(MsVideoToGifOptions& opts, const MediaInfo& info) {
    if (opts.fps <= 0) {
        opts.fps = static_cast<int>(info.fps + 0.5);
        if (opts.fps <= 0) opts.fps = 15;
    }
    if (opts.max_colors <= 0) opts.max_colors = 255;
    else if (opts.max_colors < 16) opts.max_colors = 16;
    else if (opts.max_colors > 256) opts.max_colors = 256;
    if (opts.log_level == 0) opts.log_level = 24;

    if (opts.width <= 0 && opts.height <= 0) {
        // Default to width 480 preserving aspect.
        opts.width = 480;
    } else if (opts.width > 0 && opts.height <= 0) {
        // Compute height from width preserving aspect.
        if (info.width > 0 && info.height > 0) {
            opts.height = static_cast<int>(
                static_cast<double>(opts.width) * info.height / info.width);
            opts.height = (opts.height / 2) * 2;  // make even
            if (opts.height < 2) opts.height = 2;
        } else {
            opts.height = 480;
        }
    } else if (opts.height > 0 && opts.width <= 0) {
        if (info.width > 0 && info.height > 0) {
            opts.width = static_cast<int>(
                static_cast<double>(opts.height) * info.width / info.height);
            opts.width = (opts.width / 2) * 2;
            if (opts.width < 2) opts.width = 2;
        } else {
            opts.width = 480;
        }
    } else {
        // Both specified: force even
        opts.width = (opts.width / 2) * 2;
        opts.height = (opts.height / 2) * 2;
    }

    if (opts.quality <= 0) opts.quality = 90;
    if (opts.quality > 100) opts.quality = 100;
}

}  // namespace ms


// === Public C API ===

extern "C" MS_API void ms_video_to_gif_options_init(MsVideoToGifOptions* opts) {
    if (!opts) return;
    opts->width = 0;
    opts->height = 0;
    opts->fps = 0;
    opts->max_colors = 255;
    opts->ping_pong = true;
    opts->quality = 90;
    opts->start_seconds = 0.0;
    opts->end_seconds = -1.0;
    opts->log_level = 24;
}

extern "C" MS_API MsError ms_video_to_gif(
    const char* input_path,
    const char* output_path,
    const MsVideoToGifOptions* options,
    MsVideoToGifResult* result,
    MsProgressCallback callback,
    void* user_data
) {
    if (!input_path || !output_path) return MS_ERR_INVALID_ARG;

    MsVideoToGifOptions opts;
    if (options) opts = *options;
    else ms_video_to_gif_options_init(&opts);

    // 1. Probe input.
    MediaInfo info;
    if (!ms::probe_media(input_path, info)) {
        return MS_ERR_INVALID_FORMAT;
    }

    ms::normalize_video_options(opts, info);

    // 2. Compute trim args.
    std::vector<std::string> pre_args;
    if (opts.start_seconds > 0.0) {
        pre_args.push_back("-ss");
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.3f", opts.start_seconds);
        pre_args.push_back(buf);
    }
    if (opts.end_seconds > 0.0) {
        pre_args.push_back("-to");
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.3f", opts.end_seconds);
        pre_args.push_back(buf);
    }

    // 3. Two-step: forward → ping-pong → palette → gif.
    // Step A: scale + fps normalize to intermediate mkv.
    std::string tmp_mkv = std::string(output_path) + ".tmp.mkv";
    std::remove(tmp_mkv.c_str());

    std::ostringstream vf_a;
    vf_a << "fps=" << opts.fps
         << ",scale=" << opts.width << ":-2,format=rgba";

    std::vector<std::string> args_a;
    args_a.insert(args_a.end(), pre_args.begin(), pre_args.end());
    args_a.push_back("-y");
    args_a.push_back("-v");
    // Use at least "info" verbosity so ffmpeg emits its "time=" progress
    // stats (suppressed at warning level) — needed for real-time progress.
    args_a.push_back(std::to_string(std::max(opts.log_level, 32)));
    args_a.push_back("-i");
    args_a.push_back(input_path);
    args_a.push_back("-vf");
    args_a.push_back(vf_a.str());
    args_a.push_back("-c:v");
    args_a.push_back("ffv1");
    args_a.push_back("-level");
    args_a.push_back("3");
    args_a.push_back("-pix_fmt");
    args_a.push_back("yuva420p");
    args_a.push_back(tmp_mkv);

    double total_sec = (opts.end_seconds > 0.0)
        ? (opts.end_seconds - opts.start_seconds)
        : info.duration_seconds;

    auto progress_fn = [callback, user_data, total_sec]
                       (float p, const std::string& msg) -> bool {
        if (callback) {
            callback(p < 0 ? 0.0f : p * 0.6f, msg.c_str(), user_data);
        }
        return true;
    };

    auto r = ms::run_ffmpeg(args_a, progress_fn, total_sec);
    if (r.exit_code != 0) {
        std::remove(tmp_mkv.c_str());
        return MS_ERR_FFMPEG_FAILED;
    }

    // Step B: optional ping-pong.
    std::string tmp_mkv2 = tmp_mkv;
    if (opts.ping_pong) {
        tmp_mkv2 = std::string(output_path) + ".tmp2.mkv";
        std::remove(tmp_mkv2.c_str());

        // Re-probe frame count.
        MediaInfo tmp_info;
        if (!ms::probe_media(tmp_mkv, tmp_info)) {
            std::remove(tmp_mkv.c_str());
            return MS_ERR_FFMPEG_FAILED;
        }
        int n = tmp_info.nb_frames;
        if (n <= 0) n = 76;  // fallback

        std::ostringstream fc;
        fc << "[0:v]split=2[main][rev];"
           << "[main]trim=0:" << n << ",setpts=PTS-STARTPTS[main2];"
           << "[rev]trim=0:" << (n - 1) << ",setpts=PTS-STARTPTS,reverse[rev2];"
           << "[main2][rev2]concat=n=2:v=1[v]";

        std::vector<std::string> args_b = {
            "-y", "-v", std::to_string(std::max(opts.log_level, 32)),
            "-i", tmp_mkv,
            "-filter_complex", fc.str(),
            "-map", "[v]",
            "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuva420p",
            tmp_mkv2
        };

        auto progress_fn_b = [callback, user_data]
                              (float p, const std::string& msg) -> bool {
            if (callback) {
                callback(p < 0 ? 0.6f : 0.6f + p * 0.2f, msg.c_str(), user_data);
            }
            return true;
        };

        r = ms::run_ffmpeg(args_b, progress_fn_b, total_sec);
        if (r.exit_code != 0) {
            std::remove(tmp_mkv.c_str());
            std::remove(tmp_mkv2.c_str());
            return MS_ERR_FFMPEG_FAILED;
        }
        std::remove(tmp_mkv.c_str());
    }

    // Step C: palettegen + paletteuse.
    std::string tmp_pal = std::string(output_path) + ".pal.png";
    std::remove(tmp_pal.c_str());

    std::ostringstream pgvf;
    pgvf << "palettegen=stats_mode=diff:max_colors=" << opts.max_colors
         << ":reserve_transparent=1";

    std::vector<std::string> args_c1 = {
        "-y", "-v", std::to_string(opts.log_level),
        "-i", tmp_mkv2,
        "-vf", pgvf.str(),
        tmp_pal
    };
    r = ms::run_ffmpeg(args_c1, nullptr, -1.0);
    if (r.exit_code != 0) {
        std::remove(tmp_mkv2.c_str());
        std::remove(tmp_pal.c_str());
        return MS_ERR_FFMPEG_FAILED;
    }

    std::ostringstream puvf;
    puvf << "paletteuse=dither=sierra2_4a";

    std::vector<std::string> args_c2 = {
        "-y", "-v", std::to_string(opts.log_level),
        "-i", tmp_mkv2, "-i", tmp_pal,
        "-lavfi", puvf.str(),
        "-loop", "0",
        output_path
    };

    auto progress_fn_c = [callback, user_data]
                           (float p, const std::string& msg) -> bool {
        if (callback) {
            callback(p < 0 ? 0.9f : 0.8f + p * 0.2f, msg.c_str(), user_data);
        }
        return true;
    };

    r = ms::run_ffmpeg(args_c2, progress_fn_c, -1.0);

    std::remove(tmp_mkv2.c_str());
    std::remove(tmp_pal.c_str());

    if (r.exit_code != 0) {
        return MS_ERR_FFMPEG_FAILED;
    }

    // 4. Probe output for stats.
    MediaInfo out_info;
    if (ms::probe_media(output_path, out_info)) {
        if (result) {
            result->frame_count = out_info.nb_frames;
            result->output_width = out_info.width;
            result->output_height = out_info.height;
            result->output_fps = static_cast<int>(out_info.fps + 0.5);
        }
    }
    if (result) {
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