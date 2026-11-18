/*
 * P8 - end-to-end video -> GIF probe.
 *
 * This is the probe that closes the loop: it runs the *production* C1
 * pipeline (fps/scale -> ping-pong -> palettegen -> paletteuse) inside the
 * device process, on a real video file, and reports the result.
 *
 * It exercises sdk/src/engine/ms_inproc_exec.cpp (the in-process replacement
 * for the ffmpeg CLI) and sdk/src/engine/ms_pipeline.cpp (the pipeline
 * itself), which is the code the HarmonyOS port will ship.
 */

#include "verify_common.h"

#include "ms_pipeline.h"
#include "ms_inproc_exec.h"

extern "C" {
#include <libavutil/avutil.h>
}

#include <string>

namespace {

/* Routes FFmpeg's own diagnostics into hilog. */
void LogBridge(int level, const char* message, void* user)
{
    (void)user;
    (void)level;
    LOGI("%{public}s", message);
}

bool GetStringArg(napi_env env, napi_value value, std::string &out)
{
    size_t need = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &need) != napi_ok) {
        return false;
    }
    std::string buf(need + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, &buf[0], need + 1, &written) != napi_ok) {
        return false;
    }
    buf.resize(written);
    out = buf;
    return true;
}

}  // namespace

/**
 * videoToGif(inputPath, outputPath, keepIntermediates?)
 *
 * Returns a single line summary:
 *   rc=<code> frames=<n> size=<w>x<h> fps=<n> bytes=<n> elapsedMs=<n>
 */
napi_value VideoToGifProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string input;
    std::string output;
    if (argc < 2 || !GetStringArg(env, argv[0], input) || !GetStringArg(env, argv[1], output)) {
        napi_throw_type_error(env, nullptr, "expected (inputPath, outputPath)");
        return nullptr;
    }
    bool keep = false;
    if (argc >= 3) {
        napi_get_value_bool(env, argv[2], &keep);
    }

    ms::VideoToGifOptions opts;
    // Same defaults the Windows build resolves to for a 16:9-ish clip:
    // width 480, fps taken from the source, ping-pong on, 255 colours.
    opts.width = 0;
    opts.height = 0;
    opts.fps = 0;
    opts.max_colors = 255;
    opts.ping_pong = true;
    opts.keep_intermediates = keep;

    ms::set_inproc_log(LogBridge, nullptr);
    // Warnings and errors only; the stage markers below come through the
    // same sink and are unaffected by this level.
    av_log_set_level(AV_LOG_WARNING);

    ms::VideoToGifResult res;
    int64_t start = 0;
    int rc = ms::video_to_gif_inproc(input, output, opts, &res, nullptr, nullptr);

    std::string out = "rc=" + std::to_string(rc) +
                      " frames=" + std::to_string(res.frame_count) +
                      " size=" + std::to_string(res.output_width) + "x" +
                      std::to_string(res.output_height) +
                      " fps=" + std::to_string(res.output_fps) +
                      " bytes=" + std::to_string(res.file_size) +
                      " elapsedMs=" + std::to_string(start);
    LOGI("videoToGif %s", out.c_str());
    return MakeString(env, out);
}
