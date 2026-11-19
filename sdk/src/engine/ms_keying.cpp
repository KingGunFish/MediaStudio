// sdk/src/engine/ms_keying.cpp

#include "ms_keying.h"

#include "ms_inproc_exec.h"

#include "../gif_keying/mask_builder.h"

#include <cstdio>
#include <string>

namespace ms {
namespace {

// Mirrors ms::normalize_keying_options() in
// sdk/src/gif_keying/gif_keying.cpp.
//
// The Windows file cannot be compiled for HarmonyOS because it also contains
// the CLI driver, so the defaults are repeated here. Keep the two in sync:
// the filter string that mask_builder.cpp builds depends on every one of
// these values.
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

// Progress adapter: maps the progress of one stage onto a slice of the
// overall progress, the same way the Windows implementation does.
struct StageProgress {
    PipelineProgressFn fn = nullptr;
    void* user = nullptr;
    float base = 0.0f;
    float span = 1.0f;

    static bool call(float p, void* user) {
        StageProgress* self = static_cast<StageProgress*>(user);
        if (self->fn == nullptr) {
            return true;
        }
        float scaled = self->base + self->span * p;
        if (scaled < 0.0f) scaled = 0.0f;
        if (scaled > 1.0f) scaled = 1.0f;
        return self->fn(scaled, self->user);
    }
};

}  // namespace

void keying_options_init(MsKeyingOptions* opts) {
    if (opts == nullptr) return;
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

int gif_keying_inproc(const std::string& input_path,
                      const std::string& output_path,
                      const MsKeyingOptions& opts_in,
                      MsKeyingResult* result,
                      PipelineProgressFn progress, void* user_data) {
    if (input_path.empty() || output_path.empty()) {
        return MS_PIPE_ERR_INVALID_ARG;
    }
    MsKeyingOptions opts = opts_in;
    normalize_keying_options(opts);

    // 1. Probe the input GIF. The frame count decides the ping-pong window.
    VideoInfo info;
    if (!probe_video(input_path, info, true)) {
        return MS_PIPE_ERR_INVALID_FORMAT;
    }
    if (info.duration_seconds <= 0.0 && info.fps > 0.0 && info.nb_frames > 0) {
        // The GIF demuxer reports the duration per stream, not on the format
        // context; the Windows build derives it the same way.
        info.duration_seconds = static_cast<double>(info.nb_frames) / info.fps;
    }

    int frame_count = info.nb_frames;
    if (frame_count <= 0) frame_count = 76;  // fallback, same as Windows

    // 2. Build the filter with the shared mask_builder.cpp.
    std::string filter;
    if (!build_keying_filter_complex(opts, info.width, info.height, frame_count,
                                     opts.ping_pong, filter)) {
        return MS_PIPE_ERR_INVALID_ARG;
    }
    // Logged so that the filter string can be compared byte for byte with
    // the one the Windows build sends to the ffmpeg CLI.
    inproc_log(("keying: filter = " + filter).c_str());

    // 3. Intermediate files, next to the output just like the Windows build.
    const std::string tmp_mkv = output_path + ".tmp.mkv";
    const std::string tmp_pal = output_path + ".pal.png";
    std::remove(tmp_mkv.c_str());
    std::remove(tmp_pal.c_str());

    StageProgress sp;
    sp.fn = progress;
    sp.user = user_data;

    // 4. Stage A: the keying chain -> ffv1 intermediate.
    {
        InprocJob job;
        job.sources.push_back({input_path, nullptr});
        job.output_path = tmp_mkv;
        job.format = "matroska";
        job.video_codec = "ffv1";
        job.pix_fmt = "yuva420p";
        job.level = 3;
        job.filter = filter;
        job.map_label = "[v]";

        inproc_log("keying: stage A start (mask chain -> ffv1)");
        sp.base = 0.0f;
        sp.span = 0.7f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        if (ret != 0) {
            std::remove(tmp_mkv.c_str());
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 5. Stage C1: palettegen -> palette image.
    {
        std::string pf = "[0:v]palettegen=stats_mode=diff:max_colors=" +
                         std::to_string(opts.max_colors) + ":reserve_transparent=1[pal]";

        InprocJob job;
        job.sources.push_back({tmp_mkv, nullptr});
        job.output_path = tmp_pal;
        job.video_codec = "png";
        job.raw_image_output = true;
        job.filter = pf;
        job.map_label = "[pal]";

        inproc_log("keying: stage C1 start (palettegen)");
        sp.base = 0.7f;
        sp.span = 0.0f;
        int ret = run_inproc_job(job, nullptr, nullptr, nullptr, nullptr);
        if (ret != 0) {
            std::remove(tmp_mkv.c_str());
            std::remove(tmp_pal.c_str());
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 6. Stage C2: paletteuse -> animated GIF.
    {
        InprocJob job;
        job.sources.push_back({tmp_mkv, nullptr});
        job.sources.push_back({tmp_pal, nullptr});
        job.output_path = output_path;
        job.format = "gif";
        job.video_codec = "gif";
        job.loop0 = true;
        job.filter = "[0:v][1:v]paletteuse=dither=sierra2_4a[v]";
        job.map_label = "[v]";

        inproc_log("keying: stage C2 start (paletteuse)");
        sp.base = 0.7f;
        sp.span = 0.3f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        std::remove(tmp_mkv.c_str());
        std::remove(tmp_pal.c_str());
        if (ret != 0) {
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 7. Probe the output.
    VideoInfo out_info;
    if (probe_video(output_path, out_info, true)) {
        if (result != nullptr) {
            result->input_frame_count = info.nb_frames;
            result->output_frame_count = out_info.nb_frames;
            result->output_width = out_info.width;
            result->output_height = out_info.height;
        }
    }
    if (result != nullptr) {
        result->file_size = file_size_of(output_path);
        result->duration_ms = 0;
    }
    if (progress != nullptr) {
        progress(1.0f, user_data);
    }
    return MS_PIPE_OK;
}

}  // namespace ms
