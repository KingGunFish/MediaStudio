// sdk/src/engine/ms_inproc_exec.h
//
// In-process replacement for a single `ffmpeg` CLI invocation.
//
// The Windows build drives ffmpeg.exe as a child process
// (sdk/src/ffmpeg/executor.cpp). HarmonyOS does not allow an application to
// execute arbitrary binaries that ship with it, so the OHOS build performs
// the very same work inside the process through libavfilter / libavcodec /
// libavformat.
//
// The filter graph is expressed with the CLI's -filter_complex syntax,
// including the "[0:v]" input labels, so the filter strings that
// sdk/src/video_to_gif/video_to_gif.cpp and
// sdk/src/gif_keying/mask_builder.cpp already produce can be reused
// byte-for-byte.
//
// This header is intentionally free of FFmpeg types so that the pipeline
// layer can stay plain C++.

#ifndef MS_INPROC_EXEC_H
#define MS_INPROC_EXEC_H

#include <string>
#include <vector>

struct AVFrame;

namespace ms {

// A frame source: either a media file or an in-memory frame.
struct InprocSource {
    // File to demux and decode.
    std::string path;
    // In-memory frame. When set it takes precedence over `path`.
    AVFrame* frame = nullptr;
};

// One in-process job, equivalent to a single ffmpeg CLI invocation.
//
// Only the first source may be a stream (file); additional sources must be
// single in-memory frames. That covers every shape the Media Studio
// pipelines need: the palette image handed to `paletteuse` is the only
// second input in use.
struct InprocJob {
    std::vector<InprocSource> sources;

    // Output. Leave `output_path` empty to capture the graph output through
    // `on_frame` instead of encoding it.
    std::string output_path;
    // Output container, e.g. "matroska" or "gif".
    std::string format;
    // Encoder name, e.g. "ffv1" or "gif".
    std::string video_codec;
    // Encoder pixel format, e.g. "yuva420p". Empty keeps the encoder default.
    std::string pix_fmt;
    // Encoder level, e.g. ffv1 level 3. Negative keeps the default.
    int level = -1;
    // gif muxer: write an infinite loop.
    bool loop0 = false;
    // Write the encoded packets straight to the output file instead of
    // going through a muxer. Used for single image outputs such as the
    // palette PNG, where the encoder already emits a complete file.
    bool raw_image_output = false;

    // Filter graph in CLI -filter_complex syntax, e.g.
    //   "[0:v]fps=15,scale=480:-2,format=rgba[v]"
    std::string filter;

    // Label of the graph output to use, e.g. "[v]". Empty picks the first
    // output of the graph.
    std::string map_label;
};

// Progress callback. Return false to cancel the job.
typedef bool (*InprocProgressFn)(float progress, void* user_data);

// Frame sink used in capture mode. Return 0 to continue, negative to abort.
typedef int (*InprocFrameFn)(AVFrame* frame, void* user_data);

// Log sink for FFmpeg's own diagnostics. `level` is an AV_LOG_* constant and
// `message` is already formatted.
typedef void (*InprocLogFn)(int level, const char* message, void* user_data);

// Installs a sink for FFmpeg's log output. Passing nullptr restores the
// default behaviour (messages are discarded).
void set_inproc_log(InprocLogFn fn, void* user_data);

// Emits one line through the installed log sink. Used by the pipeline
// layer for stage markers.
void inproc_log(const char* message);

// Runs one job to completion.
// Returns 0 on success or a negative AVERROR code on failure.
int run_inproc_job(const InprocJob& job,
                   InprocProgressFn progress, void* progress_user,
                   InprocFrameFn on_frame, void* frame_user);

}  // namespace ms

#endif  // MS_INPROC_EXEC_H
