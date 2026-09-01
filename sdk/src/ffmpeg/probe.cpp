// ffmpeg/probe.cpp
#include "probe.h"
#include "executor.h"

#include <regex>
#include <sstream>
#include <string>

namespace ms {

namespace {

std::string exec_ffprobe(const std::string& path, const std::string& extra_args) {
    std::vector<std::string> args = {
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames,duration,codec_name,pix_fmt",
        "-of", "default=nw=1",
        extra_args,
        path
    };
    std::string output;
    auto r = run_ffprobe(args, output);
    return output;
}

// Parse r_frame_rate like "24/1" → 24.0
double parse_fractional_fps(const std::string& s) {
    auto pos = s.find('/');
    if (pos == std::string::npos) {
        try { return std::stod(s); } catch (...) { return 0.0; }
    }
    try {
        double num = std::stod(s.substr(0, pos));
        double den = std::stod(s.substr(pos + 1));
        if (den == 0) return 0.0;
        return num / den;
    } catch (...) {
        return 0.0;
    }
}

bool parse_basic(const std::string& output, MediaInfo& out) {
    std::istringstream iss(output);
    std::string line;
    while (std::getline(iss, line)) {
        if (line.find("width=") == 0) {
            out.width = std::atoi(line.c_str() + 6);
        } else if (line.find("height=") == 0) {
            out.height = std::atoi(line.c_str() + 7);
        } else if (line.find("r_frame_rate=") == 0) {
            out.fps = parse_fractional_fps(line.substr(13));
        } else if (line.find("nb_frames=") == 0) {
            out.nb_frames = std::atoi(line.c_str() + 10);
        } else if (line.find("duration=") == 0) {
            out.duration_seconds = std::atof(line.c_str() + 9);
        } else if (line.find("codec_name=") == 0) {
            out.codec_name = line.substr(11);
        } else if (line.find("pix_fmt=") == 0) {
            out.pix_fmt = line.substr(8);
        }
    }
    out.valid = (out.width > 0 && out.height > 0);
    return out.valid;
}

}  // namespace

bool probe_media(const std::string& path, MediaInfo& out) {
    out = MediaInfo{};
    // Note: ffprobe writes metadata to stdout, errors to stderr.
    std::vector<std::string> args = {
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames,duration,codec_name,pix_fmt",
        "-of", "default=nw=1",
        path
    };
    std::string s;
    run_ffprobe(args, s);
    if (s.empty()) return false;
    return parse_basic(s, out);
}

bool probe_gif(const std::string& path, MediaInfo& out) {
    out = MediaInfo{};
    // Use count_frames to get nb_frames for GIF.
    std::vector<std::string> args = {
        "-v", "error",
        "-count_frames",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames,codec_name,pix_fmt",
        "-of", "default=nw=1",
        path
    };
    std::string s;
    auto rr = run_ffprobe(args, s);
    (void)rr;

    std::istringstream iss(s);
    std::string line;
    while (std::getline(iss, line)) {
        if (line.find("width=") == 0) {
            out.width = std::atoi(line.c_str() + 6);
        } else if (line.find("height=") == 0) {
            out.height = std::atoi(line.c_str() + 7);
        } else if (line.find("r_frame_rate=") == 0) {
            out.fps = parse_fractional_fps(line.substr(13));
        } else if (line.find("nb_read_frames=") == 0) {
            out.nb_frames = std::atoi(line.c_str() + 15);
        } else if (line.find("codec_name=") == 0) {
            out.codec_name = line.substr(11);
        } else if (line.find("pix_fmt=") == 0) {
            out.pix_fmt = line.substr(8);
        }
    }
    out.valid = (out.width > 0 && out.height > 0);
    out.duration_seconds = (out.fps > 0) ? (out.nb_frames / out.fps) : 0.0;
    return out.valid;
}

}  // namespace ms