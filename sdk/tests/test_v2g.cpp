// tests/test_v2g.cpp - Direct test of video_to_gif with stderr capture
#include "media_studio.h"
#include "../src/ffmpeg/executor.h"

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "Usage: %s <input> <output>\n", argv[0]);
        return 1;
    }
    std::string input = argv[1];
    std::string output = argv[2];
    std::fprintf(stderr, "Input bytes:");
    for (char c : input) {
        std::fprintf(stderr, " %02x", (unsigned char)c);
    }
    std::fprintf(stderr, "\n");
    std::fprintf(stderr, "Input: %s\n", input.c_str());

    // First: probe
    std::vector<std::string> probe_args = {
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames",
        "-of", "default=nw=1",
        input
    };
    std::string probe_out;
    auto pr = ms::run_ffprobe(probe_args, probe_out);
    std::fprintf(stderr, "Probe exit: %d\n", pr.exit_code);
    std::fprintf(stderr, "Probe stdout size: %zu\n", pr.stdout_output.size());
    std::fprintf(stderr, "Probe stderr size: %zu\n", pr.stderr_output.size());
    std::fprintf(stderr, "Probe output size: %zu\n", probe_out.size());
    std::fprintf(stderr, "Probe output (escaped):\n");
    for (char c : probe_out) {
        if (c == '\n') std::fprintf(stderr, "\\n\n");
        else if (c == '\r') std::fprintf(stderr, "\\r");
        else if (c < 32) std::fprintf(stderr, "\\x%02x", (unsigned char)c);
        else std::fputc(c, stderr);
    }
    std::fprintf(stderr, "\n---\n");

    // Now: run a real ffmpeg command (simple version of video_to_gif step 1)
    std::string tmp_mkv = output + ".tmp.mkv";
    std::vector<std::string> ffmpeg_args = {
        "-y", "-v", "24",
        "-i", input,
        "-vf", "fps=12,scale=400:-2,format=rgba",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuva420p",
        tmp_mkv
    };
    auto fr = ms::run_ffmpeg(ffmpeg_args, nullptr, -1.0);
    std::fprintf(stderr, "\nffmpeg exit: %d\n", fr.exit_code);
    std::fprintf(stderr, "ffmpeg stderr:\n%.*s\n",
        (int)fr.stderr_output.size() > 2000 ? 2000 : (int)fr.stderr_output.size(),
        fr.stderr_output.c_str());

    return 0;
}