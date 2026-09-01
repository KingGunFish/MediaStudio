// examples/cli_demo.cpp - Command-line demo
//
// Usage:
//   ms_demo video2gif <input.mp4> <output.gif> [--width W] [--height H] [--fps F] [--ping-pong|--no-ping-pong]
//   ms_demo keying <input.gif> <output.gif> [algorithm] [--ping-pong|--no-ping-pong]
//
// Example:
//   ms_demo video2gif ../tests/data/tortoise.mp4 out.gif --width 480 --fps 12
//   ms_demo keying out.gif clear.gif rgb_split --no-ping-pong
//
// Note: --width / --height / --fps / --ping-pong were previously ignored by
// this CLI (width was hard-coded to 480). They are now parsed and forwarded
// to the SDK so the UI can actually control output geometry.

#include "media_studio.h"

#include <cstdio>
#include <cstdlib>
#include <string>

static int usage() {
    std::fprintf(stderr,
        "Usage:\n"
        "  ms_demo video2gif <input> <output> [--width W] [--height H] [--fps F] [--ping-pong|--no-ping-pong]\n"
        "  ms_demo keying <input> <output> [algorithm] [--ping-pong|--no-ping-pong]\n"
        "    algorithm: brightness|white|chroma|distance|rgb_split (default)\n"
    );
    return 1;
}

static bool on_progress(float p, const char* msg, void* /*ud*/) {
    if (msg && *msg) {
        std::fprintf(stderr, "  [%.0f%%] %s\n", p * 100.0f, msg);
    }
    return true;  // continue
}

// Optional flags that follow the three positional args (input/output).
struct CliFlags {
    int width = 0;       // 0 = SDK default (480, aspect-preserving)
    int height = 0;      // 0 = derive from width/aspect
    int fps = 0;         // 0 = source fps
    int ping_pong = -1;  // -1 = not specified (use SDK default)
};

static CliFlags parse_flags(int argc, char** argv) {
    CliFlags f;
    for (int i = 4; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--width" && i + 1 < argc) {
            f.width = std::atoi(argv[++i]);
        } else if (a == "--height" && i + 1 < argc) {
            f.height = std::atoi(argv[++i]);
        } else if (a == "--fps" && i + 1 < argc) {
            f.fps = std::atoi(argv[++i]);
        } else if (a == "--ping-pong") {
            f.ping_pong = 1;
        } else if (a == "--no-ping-pong") {
            f.ping_pong = 0;
        }
        // Any other token (e.g. the keying algorithm at argv[4]) is ignored here.
    }
    return f;
}

int main(int argc, char** argv) {
    if (argc < 4) return usage();

    std::string cmd = argv[1];
    std::string input = argv[2];
    std::string output = argv[3];
    CliFlags flags = parse_flags(argc, argv);

    std::fprintf(stderr, "media_studio %s\n", ms_version());

    if (cmd == "video2gif") {
        MsVideoToGifOptions opts;
        ms_video_to_gif_options_init(&opts);
        if (flags.width > 0) opts.width = flags.width;
        if (flags.height > 0) opts.height = flags.height;
        if (flags.fps > 0) opts.fps = flags.fps;
        if (flags.ping_pong >= 0) opts.ping_pong = (flags.ping_pong != 0);
        MsVideoToGifResult result;
        MsError code = ms_video_to_gif(
            input.c_str(), output.c_str(), &opts, &result, on_progress, nullptr);
        if (code != MS_OK) {
            std::fprintf(stderr, "video_to_gif failed: %s\n", ms_error_string(code));
            return 1;
        }
        std::fprintf(stderr,
            "OK: %d frames, %dx%d, %lld bytes\n",
            result.frame_count, result.output_width, result.output_height,
            (long long)result.file_size);
        return 0;
    }

    if (cmd == "keying") {
        MsKeyingOptions opts;
        ms_keying_options_init(&opts);
        if (argc >= 5) {
            std::string a = argv[4];
            if (a == "brightness") opts.algorithm = MS_KEYING_BRIGHTNESS;
            else if (a == "white") opts.algorithm = MS_KEYING_WHITE_PIXEL;
            else if (a == "chroma") opts.algorithm = MS_KEYING_CHROMA_KEY;
            else if (a == "distance") opts.algorithm = MS_KEYING_COLOR_DISTANCE;
            else opts.algorithm = MS_KEYING_RGB_MASK_SPLIT;
        }
        if (flags.ping_pong >= 0) opts.ping_pong = (flags.ping_pong != 0);
        MsKeyingResult result;
        MsError code = ms_gif_keying(
            input.c_str(), output.c_str(), &opts, &result, on_progress, nullptr);
        if (code != MS_OK) {
            std::fprintf(stderr, "gif_keying failed: %s\n", ms_error_string(code));
            return 1;
        }
        std::fprintf(stderr,
            "OK: %d -> %d frames, %dx%d, %lld bytes\n",
            result.input_frame_count, result.output_frame_count,
            result.output_width, result.output_height,
            (long long)result.file_size);
        return 0;
    }

    return usage();
}
