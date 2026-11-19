/*
 * Production NAPI surface for the HarmonyOS application.
 *
 * The verification probes in pipeline_probe.cpp answer "does the platform
 * work"; this file is the API the real pages call:
 *
 *   probeMedia(path)                       -> Promise<MediaInfo>
 *   convertVideoToGif(in, out, opts, cb)  -> Promise<MediaResult>
 *   convertGifKeying(in, out, opts, cb)   -> Promise<MediaResult>
 *   convertVideoCrop(in, out, opts, cb)   -> Promise<MediaResult>
 *
 * The option objects use the same field names as the Windows renderer
 * (electron-app/src/renderer/src/types.ts), so both platforms speak one
 * contract.
 *
 * Every call runs on a worker thread through napi_async_work: a conversion
 * takes seconds and must not block the ArkUI event loop. Progress is pushed
 * to the ArkTS callback through a thread safe function.
 */

#include "verify_common.h"

#include "ms_crop.h"
#include "ms_inproc_exec.h"
#include "ms_keying.h"
#include "ms_pipeline.h"

extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/error.h>
}

#include <cstdlib>
#include <string>
#include <vector>

namespace {

// ---------------------------------------------------------------- arguments

bool HasProperty(napi_env env, napi_value obj, const char* name, napi_value* out)
{
    if (obj == nullptr) {
        return false;
    }
    bool has = false;
    if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has) {
        return false;
    }
    return napi_get_named_property(env, obj, name, out) == napi_ok;
}

bool ReadInt(napi_env env, napi_value obj, const char* name, int* out)
{
    napi_value v = nullptr;
    if (!HasProperty(env, obj, name, &v)) {
        return false;
    }
    return napi_get_value_int32(env, v, out) == napi_ok;
}

bool ReadDouble(napi_env env, napi_value obj, const char* name, double* out)
{
    napi_value v = nullptr;
    if (!HasProperty(env, obj, name, &v)) {
        return false;
    }
    return napi_get_value_double(env, v, out) == napi_ok;
}

bool ReadBool(napi_env env, napi_value obj, const char* name, bool* out)
{
    napi_value v = nullptr;
    if (!HasProperty(env, obj, name, &v)) {
        return false;
    }
    return napi_get_value_bool(env, v, out) == napi_ok;
}

bool ReadString(napi_env env, napi_value obj, const char* name, std::string* out)
{
    napi_value v = nullptr;
    if (!HasProperty(env, obj, name, &v)) {
        return false;
    }
    size_t need = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &need) != napi_ok) {
        return false;
    }
    std::string buf(need + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, v, &buf[0], need + 1, &written) != napi_ok) {
        return false;
    }
    buf.resize(written);
    *out = buf;
    return true;
}

bool ReadStringArg(napi_env env, napi_value value, std::string* out)
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
    *out = buf;
    return true;
}

// ---------------------------------------------------------------- job state

enum class JobKind { Probe, VideoToGif, Keying, Crop };

struct ProgressMsg {
    float value = 0.0f;
    std::string message;
};

struct Job {
    napi_env env = nullptr;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    napi_threadsafe_function tsfn = nullptr;

    JobKind kind = JobKind::Probe;
    std::string input;
    std::string output;

    ms::VideoToGifOptions gif_opts;
    MsKeyingOptions key_opts;
    ms::VideoCropOptions crop_opts;

    // Result payload.
    int rc = 0;
    std::string error;
    int width = 0;
    int height = 0;
    int nb_frames = 0;
    double fps = 0.0;
    double duration = 0.0;
    int64_t file_size = 0;
    std::string codec;
    int frame_count = 0;
    int output_width = 0;
    int output_height = 0;
    int64_t duration_ms = 0;
};

// ---------------------------------------------------------------- logging

void LogBridge(int level, const char* message, void* user)
{
    (void)user;
    // The executor marks every stage with inproc_log(); forwarding them makes
    // the pipeline visible in the device log, like the Windows build shows the
    // ffmpeg output. FFmpeg's own chatter stays suppressed through
    // av_log_set_level(AV_LOG_WARNING).
    if (level >= AV_LOG_WARNING) {
        LOGE("%{public}s", message);
    } else {
        LOGI("%{public}s", message);
    }
}

// ---------------------------------------------------------------- progress

void ProgressCallJs(napi_env env, napi_value js_cb, void* context, void* data)
{
    (void)context;
    ProgressMsg* msg = static_cast<ProgressMsg*>(data);
    if (msg == nullptr) {
        return;
    }
    if (env != nullptr && js_cb != nullptr) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_value value = nullptr;
        napi_create_double(env, msg->value, &value);
        napi_value text = nullptr;
        napi_create_string_utf8(env, msg->message.c_str(), msg->message.size(), &text);
        napi_value args[2] = {value, text};
        napi_value result = nullptr;
        napi_call_function(env, undefined, js_cb, 2, args, &result);
    }
    delete msg;
}

bool ProgressBridge(float p, void* user)
{
    Job* job = static_cast<Job*>(user);
    if (job == nullptr) {
        return true;
    }
    if (job->tsfn == nullptr) {
        return true;
    }
    ProgressMsg* msg = new ProgressMsg();
    msg->value = p;
    msg->message = "处理中";
    if (napi_call_threadsafe_function(job->tsfn, msg, napi_tsfn_blocking) != napi_ok) {
        delete msg;
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- execution

void ExecuteJob(napi_env env, void* data)
{
    (void)env;
    Job* job = static_cast<Job*>(data);
    ms::set_inproc_log(LogBridge, nullptr);
    // FFmpeg's own chatter is suppressed; the pipeline's stage markers still
    // arrive through the log bridge.
    av_log_set_level(AV_LOG_WARNING);

    switch (job->kind) {
        case JobKind::Probe: {
            ms::VideoInfo info;
            if (!ms::probe_video(job->input, info, true)) {
                job->rc = ms::MS_PIPE_ERR_INVALID_FORMAT;
                job->error = "无法探测媒体信息";
                break;
            }
            job->width = info.width;
            job->height = info.height;
            job->fps = info.fps;
            job->duration = info.duration_seconds;
            job->nb_frames = info.nb_frames;
            job->codec = info.codec_name;
            job->file_size = ms::file_size_of(job->input);
            job->rc = ms::MS_PIPE_OK;
            break;
        }
        case JobKind::VideoToGif: {
            ms::VideoToGifResult res;
            job->rc = ms::video_to_gif_inproc(job->input, job->output, job->gif_opts, &res,
                                              ProgressBridge, job);
            if (job->rc == ms::MS_PIPE_OK) {
                job->frame_count = res.frame_count;
                job->output_width = res.output_width;
                job->output_height = res.output_height;
                job->file_size = res.file_size;
            } else {
                job->error = "视频转 GIF 失败";
            }
            break;
        }
        case JobKind::Keying: {
            MsKeyingResult res;
            job->rc = ms::gif_keying_inproc(job->input, job->output, job->key_opts, &res,
                                             ProgressBridge, job);
            if (job->rc == ms::MS_PIPE_OK) {
                job->frame_count = res.output_frame_count;
                job->output_width = res.output_width;
                job->output_height = res.output_height;
                job->file_size = res.file_size;
            } else {
                job->error = "GIF 抠图失败";
            }
            break;
        }
        case JobKind::Crop: {
            ms::VideoCropResult res;
            job->rc = ms::video_crop_inproc(job->input, job->output, job->crop_opts, &res,
                                            ProgressBridge, job);
            if (job->rc == ms::MS_PIPE_OK) {
                job->frame_count = res.frame_count;
                job->output_width = res.output_width;
                job->output_height = res.output_height;
                job->file_size = res.file_size;
                job->duration_ms = res.duration_ms;
            } else {
                job->error = "视频裁剪失败";
            }
            break;
        }
    }
}

// ---------------------------------------------------------------- results

void SetProp(napi_env env, napi_value obj, const char* name, napi_value value)
{
    napi_set_named_property(env, obj, name, value);
}

void SetInt(napi_env env, napi_value obj, const char* name, int value)
{
    napi_value v = nullptr;
    napi_create_int32(env, value, &v);
    SetProp(env, obj, name, v);
}

void SetDouble(napi_env env, napi_value obj, const char* name, double value)
{
    napi_value v = nullptr;
    napi_create_double(env, value, &v);
    SetProp(env, obj, name, v);
}

void SetBool(napi_env env, napi_value obj, const char* name, bool value)
{
    napi_value v = nullptr;
    napi_get_boolean(env, value, &v);
    SetProp(env, obj, name, v);
}

void SetString(napi_env env, napi_value obj, const char* name, const std::string& value)
{
    napi_value v = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &v);
    SetProp(env, obj, name, v);
}

napi_value BuildResult(napi_env env, Job* job)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);

    const bool ok = job->rc == ms::MS_PIPE_OK;
    SetBool(env, obj, "ok", ok);
    SetInt(env, obj, "code", job->rc);
    SetString(env, obj, "message", ok ? "完成" : job->error);

    if (job->kind == JobKind::Probe) {
        SetInt(env, obj, "width", job->width);
        SetInt(env, obj, "height", job->height);
        SetDouble(env, obj, "fps", job->fps);
        SetDouble(env, obj, "duration", job->duration);
        SetInt(env, obj, "nbFrames", job->nb_frames);
        SetInt(env, obj, "fileSize", static_cast<int>(job->file_size));
        SetString(env, obj, "codec", job->codec);
    } else {
        SetInt(env, obj, "frameCount", job->frame_count);
        SetInt(env, obj, "outputWidth", job->output_width);
        SetInt(env, obj, "outputHeight", job->output_height);
        SetInt(env, obj, "fileSize", static_cast<int>(job->file_size));
        SetInt(env, obj, "durationMs", static_cast<int>(job->duration_ms));
    }
    return obj;
}

void CompleteJob(napi_env env, napi_status status, void* data)
{
    (void)status;
    Job* job = static_cast<Job*>(data);
    napi_value result = BuildResult(env, job);
    napi_resolve_deferred(env, job->deferred, result);
    napi_delete_async_work(env, job->work);
    if (job->tsfn != nullptr) {
        napi_release_threadsafe_function(job->tsfn, napi_tsfn_release);
    }
    delete job;
}

// Starts the worker thread for one job. `on_progress` may be undefined, in
// which case no progress is reported.
napi_value StartJob(napi_env env, Job* job, napi_value on_progress)
{
    napi_value promise = nullptr;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok) {
        delete job;
        napi_throw_error(env, nullptr, "cannot create promise");
        return nullptr;
    }

    bool has_callback = false;
    napi_valuetype type = napi_undefined;
    if (on_progress != nullptr && napi_typeof(env, on_progress, &type) == napi_ok) {
        has_callback = type == napi_function;
    }
    if (has_callback) {
        napi_value name = nullptr;
        napi_create_string_utf8(env, "msMediaProgress", NAPI_AUTO_LENGTH, &name);
        if (napi_create_threadsafe_function(env, on_progress, nullptr, name, 0, 1, nullptr,
                                           nullptr, nullptr, ProgressCallJs, &job->tsfn) != napi_ok) {
            job->tsfn = nullptr;
            has_callback = false;
        }
    }

    napi_value resource = nullptr;
    napi_create_string_utf8(env, "msMediaTask", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_async_work(env, nullptr, resource, ExecuteJob, CompleteJob, job,
                               &job->work) != napi_ok) {
        if (job->tsfn != nullptr) {
            napi_release_threadsafe_function(job->tsfn, napi_tsfn_release);
        }
        delete job;
        napi_throw_error(env, nullptr, "cannot create async work");
        return nullptr;
    }
    napi_queue_async_work(env, job->work);
    return promise;
}

// ---------------------------------------------------------------- options

void ApplyKeyingOptions(napi_env env, napi_value opts, MsKeyingOptions* out)
{
    ms::keying_options_init(out);
    if (opts == nullptr) {
        return;
    }
    std::string algorithm;
    if (ReadString(env, opts, "algorithm", &algorithm)) {
        if (algorithm == "brightness") {
            out->algorithm = MS_KEYING_BRIGHTNESS;
        } else if (algorithm == "white") {
            out->algorithm = MS_KEYING_WHITE_PIXEL;
        } else if (algorithm == "chroma") {
            out->algorithm = MS_KEYING_CHROMA_KEY;
        } else if (algorithm == "distance") {
            out->algorithm = MS_KEYING_COLOR_DISTANCE;
        } else {
            out->algorithm = MS_KEYING_RGB_MASK_SPLIT;
        }
    }
    ReadInt(env, opts, "brightnessThreshold", &out->brightness_threshold);
    ReadInt(env, opts, "whiteThreshold", &out->white_threshold);
    ReadInt(env, opts, "distanceThreshold", &out->distance_threshold);
    ReadInt(env, opts, "bgR", &out->bg_r);
    ReadInt(env, opts, "bgG", &out->bg_g);
    ReadInt(env, opts, "bgB", &out->bg_b);
    ReadInt(env, opts, "channelThreshold", &out->channel_threshold);
    ReadBool(env, opts, "useChannelFallback", &out->use_channel_fallback);
    ReadBool(env, opts, "watermarkBottomRight", &out->watermark_bottom_right);
    ReadBool(env, opts, "watermarkTopLeft", &out->watermark_top_left);
    ReadInt(env, opts, "maxColors", &out->max_colors);
    ReadInt(env, opts, "quality", &out->quality);
    ReadInt(env, opts, "logLevel", &out->log_level);
    ReadBool(env, opts, "pingPong", &out->ping_pong);
}

// ---------------------------------------------------------------- entry points

napi_value ProbeMedia(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    Job* job = new Job();
    job->env = env;
    job->kind = JobKind::Probe;
    if (argc < 1 || !ReadStringArg(env, argv[0], &job->input)) {
        delete job;
        napi_throw_type_error(env, nullptr, "expected (path)");
        return nullptr;
    }
    return StartJob(env, job, nullptr);
}

napi_value ConvertVideoToGif(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    Job* job = new Job();
    job->env = env;
    job->kind = JobKind::VideoToGif;
    if (argc < 2 || !ReadStringArg(env, argv[0], &job->input) ||
        !ReadStringArg(env, argv[1], &job->output)) {
        delete job;
        napi_throw_type_error(env, nullptr, "expected (input, output, options, onProgress)");
        return nullptr;
    }
    if (argc >= 3) {
        ReadInt(env, argv[2], "width", &job->gif_opts.width);
        ReadInt(env, argv[2], "height", &job->gif_opts.height);
        ReadInt(env, argv[2], "fps", &job->gif_opts.fps);
        ReadInt(env, argv[2], "maxColors", &job->gif_opts.max_colors);
        ReadInt(env, argv[2], "quality", &job->gif_opts.quality);
        ReadBool(env, argv[2], "pingPong", &job->gif_opts.ping_pong);
        ReadDouble(env, argv[2], "startSeconds", &job->gif_opts.start_seconds);
        ReadDouble(env, argv[2], "endSeconds", &job->gif_opts.end_seconds);
    }
    return StartJob(env, job, argc >= 4 ? argv[3] : nullptr);
}

napi_value ConvertGifKeying(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    Job* job = new Job();
    job->env = env;
    job->kind = JobKind::Keying;
    if (argc < 2 || !ReadStringArg(env, argv[0], &job->input) ||
        !ReadStringArg(env, argv[1], &job->output)) {
        delete job;
        napi_throw_type_error(env, nullptr, "expected (input, output, options, onProgress)");
        return nullptr;
    }
    if (argc >= 3) {
        ApplyKeyingOptions(env, argv[2], &job->key_opts);
    }
    return StartJob(env, job, argc >= 4 ? argv[3] : nullptr);
}

napi_value ConvertVideoCrop(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    Job* job = new Job();
    job->env = env;
    job->kind = JobKind::Crop;
    if (argc < 2 || !ReadStringArg(env, argv[0], &job->input) ||
        !ReadStringArg(env, argv[1], &job->output)) {
        delete job;
        napi_throw_type_error(env, nullptr, "expected (input, output, options, onProgress)");
        return nullptr;
    }
    if (argc >= 3) {
        ReadInt(env, argv[2], "outputWidth", &job->crop_opts.output_width);
        ReadInt(env, argv[2], "outputHeight", &job->crop_opts.output_height);
        ReadDouble(env, argv[2], "scale", &job->crop_opts.scale);
        ReadDouble(env, argv[2], "offsetX", &job->crop_opts.offset_x);
        ReadDouble(env, argv[2], "offsetY", &job->crop_opts.offset_y);
        ReadString(env, argv[2], "background", &job->crop_opts.background);
        ReadInt(env, argv[2], "crf", &job->crop_opts.crf);
        ReadBool(env, argv[2], "keepAudio", &job->crop_opts.keep_audio);
        ReadInt(env, argv[2], "sourceWidth", &job->crop_opts.source_width);
        ReadInt(env, argv[2], "sourceHeight", &job->crop_opts.source_height);
    }
    return StartJob(env, job, argc >= 4 ? argv[3] : nullptr);
}

/**
 * Decodes the first frame of a video and writes it as a PNG.
 *
 * The crop page needs a bitmap to show the WYSIWYG preview; the engine writes
 * it with the same PNG encoder that produces the palette image, so no image
 * codec has to live on the ArkTS side.
 */
napi_value DecodeFirstFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string input;
    std::string output;
    if (argc < 2 || !ReadStringArg(env, argv[0], &input) ||
        !ReadStringArg(env, argv[1], &output)) {
        napi_throw_type_error(env, nullptr, "expected (inputPath, outputPath)");
        return nullptr;
    }

    ms::set_inproc_log(LogBridge, nullptr);
    av_log_set_level(AV_LOG_WARNING);

    ms::VideoInfo info_out;
    int rc = ms::MS_PIPE_OK;
    if (!ms::probe_video(input, info_out, false)) {
        rc = ms::MS_PIPE_ERR_INVALID_FORMAT;
    } else {
        ms::InprocJob job;
        job.sources.push_back({input, nullptr});
        job.output_path = output;
        job.video_codec = "png";
        job.raw_image_output = true;
        // Keep the first frame only; the auto-rotation the executor injects
        // applies as well, so the bitmap matches the crop geometry.
        job.filter = "[0:v]trim=end_frame=1[v]";
        job.map_label = "[v]";
        int job_rc = ms::run_inproc_job(job, nullptr, nullptr, nullptr, nullptr);
        if (job_rc != 0) {
            char err[160] = {0};
            av_strerror(job_rc, err, sizeof(err));
            LOGE("decodeFirstFrame failed rc=%d (%{public}s)", job_rc, err);
            rc = ms::MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetBool(env, obj, "ok", rc == ms::MS_PIPE_OK);
    SetInt(env, obj, "code", rc);
    SetString(env, obj, "message", rc == ms::MS_PIPE_OK ? "完成" : "无法解码首帧");
    int width = info_out.width;
    int height = info_out.height;
    if (rc == ms::MS_PIPE_OK && ms::probe_source_rotation(input) == 90) {
        int t = width;
        width = height;
        height = t;
    }
    SetInt(env, obj, "width", width);
    SetInt(env, obj, "height", height);
    SetString(env, obj, "path", output);
    return obj;
}

}  // namespace

// Exposed through verify_common.h so napi_init.cpp stays a thin registry.
napi_value MsProbeMedia(napi_env env, napi_callback_info info) { return ProbeMedia(env, info); }
napi_value MsConvertVideoToGif(napi_env env, napi_callback_info info) { return ConvertVideoToGif(env, info); }
napi_value MsConvertGifKeying(napi_env env, napi_callback_info info) { return ConvertGifKeying(env, info); }
napi_value MsConvertVideoCrop(napi_env env, napi_callback_info info) { return ConvertVideoCrop(env, info); }
napi_value MsDecodeFirstFrame(napi_env env, napi_callback_info info) { return DecodeFirstFrame(env, info); }
