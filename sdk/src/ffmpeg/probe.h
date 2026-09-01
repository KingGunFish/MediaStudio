// ffmpeg/probe.h - Read media metadata
#pragma once

#include <cstdint>
#include <string>

namespace ms {

struct MediaInfo {
    int width = 0;
    int height = 0;
    double fps = 0.0;
    int nb_frames = 0;
    double duration_seconds = 0.0;
    std::string codec_name;
    std::string pix_fmt;
    bool valid = false;
};

// Probe a media file. Returns false on error.
bool probe_media(const std::string& path, MediaInfo& out);

// Probe a GIF specifically: read frame count, width, height, fps.
bool probe_gif(const std::string& path, MediaInfo& out);

}  // namespace ms