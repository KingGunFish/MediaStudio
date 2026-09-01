// Minimal C test to verify ffmpeg/ffprobe invocation works from popen.
// ffmpeg/ffprobe are resolved from PATH (override via FFMPEG / FFPROBE env vars).
// A sample video path may be passed as argv[1] (default: "input.mp4").
#include <cstdio>
#include <cstdlib>
#include <string>

#ifdef _WIN32
#include <io.h>
#define popen _popen
#define pclose _pclose
#endif

static std::string ffmpegBin() {
    const char* e = std::getenv("FFMPEG");
    return e ? e : "ffmpeg";
}

static std::string ffprobeBin() {
    const char* e = std::getenv("FFPROBE");
    return e ? e : "ffprobe";
}

// Run `cmd` via popen and print up to `maxLines` lines of output to stderr.
static int runAndPrint(const char* label, const std::string& cmd, int maxLines) {
    std::fprintf(stderr, "%s\n  $ %s\n", label, cmd.c_str());
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) { std::fprintf(stderr, "  popen failed\n"); return 1; }
    char buf[1024];
    int lines = 0;
    while (fgets(buf, sizeof(buf), p) && lines < maxLines) {
        std::fprintf(stderr, "  %s", buf);
        lines++;
    }
    pclose(p);
    return 0;
}

int main(int argc, char** argv) {
    std::string sample = (argc > 1) ? argv[1] : "input.mp4";

    // Test 1: popen with simple command (no shell features)
    runAndPrint("\nTest 1: direct ffmpeg -version",
                "\"" + ffmpegBin() + "\" -version", 3);

    // Test 2: popen with cmd.exe /c and quoted command
    runAndPrint("\nTest 2: cmd.exe /c with quoted path",
                "cmd.exe /c \"\"" + ffmpegBin() + "\" -version\"", 3);

    // Test 3: ASCII file path with -i
    runAndPrint("\nTest 3: probe ASCII file",
                "cmd.exe /c \"\"" + ffprobeBin() + "\" -v error -show_streams \"" + sample + "\"\"", 5);

    // Test 4: non-ASCII path (same sample; mainly verifies UTF-8 paths survive popen)
    runAndPrint("\nTest 4: probe non-ASCII path",
                "cmd.exe /c \"\"" + ffprobeBin() + "\" -v error -show_streams \"" + sample + "\"\"", 5);

    return 0;
}
