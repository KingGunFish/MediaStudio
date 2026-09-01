// gif_keying/mask_builder.cpp
#include "mask_builder.h"

#include <sstream>
#include <string>
#include <vector>

namespace ms {

namespace {

std::string int_str(int v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%d", v);
    return buf;
}

std::string append_or(std::vector<std::string>& parts, const std::string& s) {
    parts.push_back(s);
    return "";
}

// Build subject-identification condition (a sum of boolean expressions that
// becomes 0/1+).
std::string build_subject_condition(const MsKeyingOptions& opts) {
    std::vector<std::string> parts;

    switch (opts.algorithm) {
        case MS_KEYING_BRIGHTNESS:
            parts.push_back(
                "lt(0.299*r(X,Y)+0.587*g(X,Y)+0.114*b(X,Y)," +
                int_str(opts.brightness_threshold) + ")");
            break;

        case MS_KEYING_WHITE_PIXEL:
            parts.push_back(
                "gte(r(X,Y)," + int_str(opts.white_threshold) + ")" +
                "*gte(g(X,Y)," + int_str(opts.white_threshold) + ")" +
                "*gte(b(X,Y)," + int_str(opts.white_threshold) + ")");
            break;

        case MS_KEYING_CHROMA_KEY:
        case MS_KEYING_COLOR_DISTANCE:
        case MS_KEYING_RGB_MASK_SPLIT:
        case MS_KEYING_AUTO:
        default: {
            // Color distance
            std::ostringstream dist;
            dist << "(r(X,Y)-" << opts.bg_r << ")"
                 << "*(r(X,Y)-" << opts.bg_r << ")"
                 << "+(g(X,Y)-" << opts.bg_g << ")"
                 << "*(g(X,Y)-" << opts.bg_g << ")"
                 << "+(b(X,Y)-" << opts.bg_b << ")"
                 << "*(b(X,Y)-" << opts.bg_b << ")";
            parts.push_back("lt(" + dist.str() + "," + int_str(opts.distance_threshold) + ")");
            // Channel fallback (cover per-frame background color drift)
            if (opts.use_channel_fallback) {
                std::ostringstream ch;
                ch << "gt(r(X,Y)," << opts.channel_threshold << ")"
                   << "+gt(g(X,Y)," << opts.channel_threshold << ")"
                   << "+gt(b(X,Y)," << opts.channel_threshold << ")";
                parts.push_back(ch.str());
            }
            break;
        }
    }

    // Join with + (logical OR via sum > 0)
    std::string result;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i > 0) result += "+";
        result += parts[i];
    }
    return result;
}

std::string build_watermark_condition(const MsKeyingOptions& opts, int w, int h) {
    std::vector<std::string> parts;

    if (opts.watermark_bottom_right) {
        int x_min = (w * opts.watermark_br_x_ratio) / 100;
        int y_min = (h * opts.watermark_br_y_ratio) / 100;
        parts.push_back(
            "gt(X," + int_str(x_min) + ")*gt(Y," + int_str(y_min) + ")");
    }
    if (opts.watermark_top_left) {
        int x_max = (w * opts.watermark_tl_x_ratio) / 100;
        int y_max = (h * opts.watermark_tl_y_ratio) / 100;
        parts.push_back(
            "lt(X," + int_str(x_max) + ")*lt(Y," + int_str(y_max) + ")");
    }

    std::string result;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i > 0) result += "+";
        result += parts[i];
    }
    return result;
}

}  // namespace

std::string build_alpha_expr(const MsKeyingOptions& opts) {
    // Caller passes a combined expression; we don't split subject/watermark here.
    // (See gif_keying.cpp for combining.)
    return "";
}

bool build_keying_filter_complex(
    const MsKeyingOptions& opts,
    int width,
    int height,
    int frame_count,
    bool ping_pong,
    std::string& out_filter
) {
    if (width <= 0 || height <= 0) return false;

    int w_even = (width / 2) * 2;
    int h_even = (height / 2) * 2;
    if (w_even < 2) w_even = 2;
    if (h_even < 2) h_even = 2;

    std::string subject = build_subject_condition(opts);
    std::string watermark = build_watermark_condition(opts, w_even, h_even);

    // Combine: alpha = 0 if any condition, else 255.
    std::ostringstream alpha;
    alpha << "if(" << subject;
    if (!watermark.empty()) alpha << "+" << watermark;
    alpha << ",0,255)";
    std::string alpha_expr = alpha.str();

    std::ostringstream fc;
    // Always use RGB + mask split for correctness (handles alpha=0 RGB=255 quirk).
    fc << "[0:v]fps=15,scale=" << w_even << ":-2,format=rgb24[rgb];"
       << "[0:v]fps=15,scale=" << w_even << ":-2,format=rgba,"
       << "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='" << alpha_expr << "',"
       << "format=rgba,alphaextract,format=gray[mask_a];"
       << "[rgb][mask_a]alphamerge,format=rgba";

    if (ping_pong && frame_count > 1) {
        fc << "[m];[m]split=2[fwd_src][rev_src];"
           << "[fwd_src]trim=0:" << frame_count
           << ",setpts=PTS-STARTPTS[fwd];"
           << "[rev_src]trim=0:" << (frame_count - 1)
           << ",setpts=PTS-STARTPTS,reverse[rev];"
           << "[fwd][rev]concat=n=2:v=1[v]";
    } else {
        fc << "[v]";
    }

    out_filter = fc.str();
    return true;
}

}  // namespace ms