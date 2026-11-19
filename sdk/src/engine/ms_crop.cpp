// sdk/src/engine/ms_crop.cpp

#include "ms_crop.h"

#include "ms_inproc_exec.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/mathematics.h>
}

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

namespace ms {
namespace {

double clampd(double v, double lo, double hi) {
    if (hi < lo) {
        return lo;
    }
    return std::min(hi, std::max(lo, v));
}

// Round down to an even number (yuv420p chroma alignment). Mirrors the
// even() helper of videoCrop.ts, which allows 0.
int even_down(int n) {
    return std::max(0, (n / 2) * 2);
}

// '#rrggbb' -> '0xrrggbb'. Anything else falls back to black, like the
// Windows implementation.
std::string to_ffmpeg_color(const std::string& hex) {
    std::string s = hex;
    if (!s.empty() && s[0] == '#') {
        s = s.substr(1);
    }
    if (s.size() != 6) {
        return "black";
    }
    for (size_t i = 0; i < s.size(); i++) {
        char c = s[i];
        bool hex_digit = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!hex_digit) {
            return "black";
        }
    }
    for (size_t i = 0; i < s.size(); i++) {
        s[i] = static_cast<char>(std::tolower(static_cast<unsigned char>(s[i])));
    }
    return "0x" + s;
}

// Rotation of the source, normalised the way fftools/cmdutils.c:get_rotation()
// does it: 0 or 90 (the CLI transposes the frame for 90 and 270).

struct ProgressBridge {
    PipelineProgressFn fn = nullptr;
    void* user = nullptr;
};

bool progress_bridge(float p, void* user) {
    ProgressBridge* bridge = static_cast<ProgressBridge*>(user);
    if (bridge == nullptr || bridge->fn == nullptr) {
        return true;
    }
    return bridge->fn(p, bridge->user);
}

}  // namespace

std::string build_crop_filter_chain(const VideoCropOptions& opts, int src_w, int src_h) {
    if (src_w <= 0 || src_h <= 0) {
        return "";
    }
    const int W = std::max(2, static_cast<int>(std::lround(opts.output_width)));
    const int H = std::max(2, static_cast<int>(std::lround(opts.output_height)));
    const double s = opts.scale > 0 ? opts.scale : 1.0;

    // The video rectangle expressed in canvas coordinates.
    const double v_left = opts.offset_x;
    const double v_top = opts.offset_y;
    const double v_right = v_left + src_w * s;
    const double v_bottom = v_top + src_h * s;

    // The part of that rectangle that is actually visible on the canvas.
    const double ax = std::max(0.0, v_left);
    const double ay = std::max(0.0, v_top);
    const double bx = std::min(static_cast<double>(W), v_right);
    const double by = std::min(static_cast<double>(H), v_bottom);
    const double cw = std::max(1.0, bx - ax);
    const double ch = std::max(1.0, by - ay);

    // The same region expressed in source pixels.
    int vx0 = even_down(static_cast<int>(clampd((ax - v_left) / s, 0, src_w)));
    int vy0 = even_down(static_cast<int>(clampd((ay - v_top) / s, 0, src_h)));
    int vw = even_down(static_cast<int>(clampd(cw / s, 2, src_w)));
    int vh = even_down(static_cast<int>(clampd(ch / s, 2, src_h)));
    // Never read past the end of the frame.
    if (vx0 + vw > src_w) {
        vw = even_down(src_w - vx0);
    }
    if (vy0 + vh > src_h) {
        vh = even_down(src_h - vy0);
    }
    vw = std::max(2, std::min(vw, src_w - vx0));
    vh = std::max(2, std::min(vh, src_h - vy0));
    if (vx0 + vw > src_w) {
        vx0 = std::max(0, even_down(src_w - vw));
    }
    if (vy0 + vh > src_h) {
        vy0 = std::max(0, even_down(src_h - vh));
    }

    // Size of the cropped block once it is placed on the canvas.
    const int out_w = std::max(1, static_cast<int>(std::lround(vw * s)));
    const int out_h = std::max(1, static_cast<int>(std::lround(vh * s)));

    // Where that block sits on the canvas.
    const int pad_x = static_cast<int>(clampd(std::lround(v_left + vx0 * s), 0,
                                              std::max(0, W - out_w)));
    const int pad_y = static_cast<int>(clampd(std::lround(v_top + vy0 * s), 0,
                                              std::max(0, H - out_h)));

    const std::string bg = to_ffmpeg_color(opts.background);

    char buf[192];
    std::snprintf(buf, sizeof(buf), "crop=%d:%d:%d:%d:exact=1,scale=%d:%d:flags=lanczos,pad=%d:%d:%d:%d:%s",
                  vw, vh, vx0, vy0, out_w, out_h, W, H, pad_x, pad_y, bg.c_str());
    return std::string(buf);
}

int video_crop_inproc(const std::string& input_path,
                      const std::string& output_path,
                      const VideoCropOptions& opts,
                      VideoCropResult* result,
                      PipelineProgressFn progress, void* user_data) {
    if (input_path.empty() || output_path.empty()) {
        return MS_PIPE_ERR_INVALID_ARG;
    }
    if (opts.output_width <= 0 || opts.output_height <= 0) {
        return MS_PIPE_ERR_INVALID_ARG;
    }

    VideoInfo info;
    if (!probe_video(input_path, info, true)) {
        return MS_PIPE_ERR_INVALID_FORMAT;
    }

    // The preview shows the rotated frame, and ffmpeg auto-rotates before the
    // crop filter runs - so prefer the rotated size over the coded one.
    int src_w = opts.source_width > 0 ? opts.source_width : info.width;
    int src_h = opts.source_height > 0 ? opts.source_height : info.height;
    if (opts.source_width <= 0 && probe_source_rotation(input_path) == 90) {
        std::swap(src_w, src_h);
    }
    if (src_w <= 0 || src_h <= 0) {
        return MS_PIPE_ERR_INVALID_FORMAT;
    }

    // h264/yuv420p needs even dimensions.
    VideoCropOptions effective = opts;
    effective.output_width = std::max(2, even_down(opts.output_width));
    effective.output_height = std::max(2, even_down(opts.output_height));

    const std::string chain = build_crop_filter_chain(effective, src_w, src_h);
    if (chain.empty()) {
        return MS_PIPE_ERR_INVALID_ARG;
    }
    inproc_log(("crop: filter = " + chain).c_str());

    InprocJob job;
    job.sources.push_back({input_path, nullptr});
    job.output_path = output_path;
    // The OHOS ffmpeg build carries no H.264 encoder (libx264 is GPL and
    // libopenh264 is not bundled yet), so the crop is delivered as MJPEG in
    // an AVI container until the H.264 encoder lands.
    job.format = "avi";
    job.video_codec = "mjpeg";
    job.pix_fmt = "yuvj420p";
    job.filter = chain;

    ProgressBridge bridge;
    bridge.fn = progress;
    bridge.user = user_data;

    const int rc = run_inproc_job(job, progress_bridge, &bridge, nullptr, nullptr);
    if (rc != 0) {
        return MS_PIPE_ERR_FFMPEG_FAILED;
    }

    if (result != nullptr) {
        result->output_width = effective.output_width;
        result->output_height = effective.output_height;
        result->frame_count = info.nb_frames;
        result->file_size = file_size_of(output_path);
        result->duration_ms = static_cast<int64_t>(info.duration_seconds * 1000.0);
    }
    return MS_PIPE_OK;
}

}  // namespace ms
