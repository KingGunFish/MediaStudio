// tests/test_executor.cpp - Test CreateProcessW path
#include "media_studio.h"
#include "../src/ffmpeg/executor.h"

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
    // Test via the public API: probe a video. Pass the path as argv[1],
    // or drop a sample next to the binary named input.mp4.
    std::string input = (argc > 1) ? argv[1] : "input.mp4";
    std::fprintf(stderr, "Probing: %s\n", input.c_str());

    // Use the internal probe function via run_ffprobe
    std::vector<std::string> args = {
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames",
        "-of", "default=nw=1",
        input
    };
    std::string output;
    auto r = ms::run_ffprobe(args, output);
    std::fprintf(stderr, "exit_code: %d\n", r.exit_code);
    std::fprintf(stderr, "stderr_output (len=%zu):\n%.*s\n", r.stderr_output.size(), (int)r.stderr_output.size(), r.stderr_output.c_str());
    if (!output.empty()) {
        std::fprintf(stderr, "output:\n%s\n", output.c_str());
    } else {
        std::fprintf(stderr, "no output\n");
    }
    return r.exit_code;
}