// gif_keying/mask_builder.h - Build ffmpeg filter for keying
#pragma once

#include "media_studio.h"

#include <string>

namespace ms {

// Build the geq alpha expression (returns alpha value for each pixel).
// e.g. "if(lt(dist_sq,1500)+gt(r,220)+gt(g,220)+gt(b,220),0,255)"
std::string build_alpha_expr(const MsKeyingOptions& opts);

// Build the complete filter_complex for keying.
// Returns false if invalid options.
bool build_keying_filter_complex(
    const MsKeyingOptions& opts,
    int width,
    int height,
    int frame_count,
    bool ping_pong,
    std::string& out_filter
);

}  // namespace ms