// sdk/src/engine/ms_pipeline.cpp

#include "ms_pipeline.h"

#include "ms_inproc_exec.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/pixdesc.h>
}

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace ms {
namespace {

// Mirrors ms::normalize_video_options() in
// sdk/src/video_to_gif/video_to_gif.cpp.
void normalize_video_options(VideoToGifOptions& opts, const VideoInfo& info) {
    if (opts.fps <= 0) {
        opts.fps = static_cast<int>(info.fps + 0.5);
        if (opts.fps <= 0) opts.fps = 15;
    }
    if (opts.max_colors <= 0) {
        opts.max_colors = 255;
    } else if (opts.max_colors < 16) {
        opts.max_colors = 16;
    } else if (opts.max_colors > 256) {
        opts.max_colors = 256;
    }

    if (opts.width <= 0 && opts.height <= 0) {
        opts.width = 480;
    } else if (opts.width > 0 && opts.height <= 0) {
        if (info.width > 0 && info.height > 0) {
            opts.height = static_cast<int>(
                static_cast<double>(opts.width) * info.height / info.width);
            opts.height = (opts.height / 2) * 2;
            if (opts.height < 2) opts.height = 2;
        } else {
            opts.height = 480;
        }
    } else if (opts.height > 0 && opts.width <= 0) {
        if (info.width > 0 && info.height > 0) {
            opts.width = static_cast<int>(
                static_cast<double>(opts.height) * info.width / info.height);
            opts.width = (opts.width / 2) * 2;
            if (opts.width < 2) opts.width = 2;
        } else {
            opts.width = 480;
        }
    } else {
        opts.width = (opts.width / 2) * 2;
        opts.height = (opts.height / 2) * 2;
    }
}

// Progress adapter: maps the progress of one stage onto a slice of the
// overall progress, the same way the Windows implementation does.
struct StageProgress {
    PipelineProgressFn fn = nullptr;
    void* user = nullptr;
    float base = 0.0f;
    float span = 1.0f;

    static bool call(float p, void* user) {
        StageProgress* self = static_cast<StageProgress*>(user);
        if (self->fn == nullptr) {
            return true;
        }
        float scaled = self->base + self->span * p;
        if (scaled < 0.0f) scaled = 0.0f;
        if (scaled > 1.0f) scaled = 1.0f;
        return self->fn(scaled, self->user);
    }
};

}  // namespace

int64_t file_size_of(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        return 0;
    }
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fclose(f);
    return static_cast<int64_t>(n);
}

int probe_source_rotation(const std::string& path) {
    AVFormatContext* fmt = nullptr;
    if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0 || fmt == nullptr) {
        return 0;
    }
    int rotation = 0;
    if (avformat_find_stream_info(fmt, nullptr) >= 0) {
        for (unsigned i = 0; i < fmt->nb_streams; i++) {
            AVStream* st = fmt->streams[i];
            if (st->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
                continue;
            }
            // The display matrix travels as coded side data of the stream.
            const AVPacketSideData* dm = nullptr;
            for (int k = 0; k < st->codecpar->nb_coded_side_data; k++) {
                if (st->codecpar->coded_side_data[k].type == AV_PKT_DATA_DISPLAYMATRIX) {
                    dm = &st->codecpar->coded_side_data[k];
                    break;
                }
            }
            if (dm == nullptr || dm->size < sizeof(int32_t) * 9) {
                break;
            }
            // fftools/ffmpeg.c:get_rotation()
            const int32_t* matrix = reinterpret_cast<const int32_t*>(dm->data);
            double theta = -std::round(av_display_rotation_get(matrix));
            theta -= 360 * std::floor(theta / 360 + 0.9 / 360);
            rotation = static_cast<int>(std::lround(theta));
            break;
        }
    }
    avformat_close_input(&fmt);
    // The CLI auto-rotates by 90 or 270, so the frame the filters see is the
    // transposed one.
    const int norm = ((rotation % 360) + 360) % 360;
    return (norm == 90 || norm == 270) ? 90 : 0;
}

bool probe_video(const std::string& path, VideoInfo& out, bool count_frames) {
    out = VideoInfo{};
    AVFormatContext* fmt = nullptr;
    if (avformat_open_input(&fmt, path.c_str(), nullptr, nullptr) < 0) {
        return false;
    }
    if (avformat_find_stream_info(fmt, nullptr) < 0) {
        avformat_close_input(&fmt);
        return false;
    }
    int idx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (idx < 0) {
        avformat_close_input(&fmt);
        return false;
    }
    AVStream* st = fmt->streams[idx];
    out.width = st->codecpar->width;
    out.height = st->codecpar->height;
    // ffprobe reports r_frame_rate; fall back to the average rate and only
    // then to a guess.
    if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) {
        out.fps = static_cast<double>(st->r_frame_rate.num) / st->r_frame_rate.den;
    } else if (st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0) {
        out.fps = static_cast<double>(st->avg_frame_rate.num) / st->avg_frame_rate.den;
    } else {
        AVRational fr = av_guess_frame_rate(fmt, st, nullptr);
        out.fps = (fr.den > 0) ? static_cast<double>(fr.num) / fr.den : 0.0;
    }
    // Same source as ffprobe's nb_frames field: the container hint only.
    out.nb_frames = st->nb_frames;
    if (fmt->duration > 0) {
        out.duration_seconds = static_cast<double>(fmt->duration) / AV_TIME_BASE;
    }
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    out.codec_name = (dec != nullptr) ? dec->name : "";
    out.pix_fmt = av_get_pix_fmt_name(static_cast<enum AVPixelFormat>(st->codecpar->format));

    if (count_frames && dec != nullptr) {
        // The first pass may already have consumed the whole file (the GIF
        // demuxer scans it during avformat_find_stream_info), so the frame
        // count needs a fresh handle.
        AVFormatContext* cfmt = nullptr;
        AVCodecContext* cc = nullptr;
        // Note: avformat_find_stream_info is deliberately not called here.
        // For the GIF demuxer it scans the whole file, which would leave
        // nothing to decode afterwards.
        if (avformat_open_input(&cfmt, path.c_str(), nullptr, nullptr) >= 0) {
            int cidx = -1;
            for (unsigned i = 0; i < cfmt->nb_streams; i++) {
                if (cfmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                    cidx = static_cast<int>(i);
                    break;
                }
            }
            cc = avcodec_alloc_context3(dec);
            if (cc != nullptr && cidx >= 0 &&
                avcodec_parameters_to_context(cc, cfmt->streams[cidx]->codecpar) >= 0 &&
                avcodec_open2(cc, dec, nullptr) >= 0) {
                AVPacket* pkt = av_packet_alloc();
                AVFrame* frame = av_frame_alloc();
                int counted = 0;
                int packets_read = 0;
                int last_read = 0;
                bool flushing = false;
                bool pending = false;
                for (;;) {
                    int ret = avcodec_receive_frame(cc, frame);
                    if (ret == 0) {
                        counted++;
                        continue;
                    }
                    if (ret == AVERROR_EOF || ret != AVERROR(EAGAIN)) {
                        break;
                    }
                    if (flushing) {
                        break;
                    }
                    if (pending) {
                        ret = avcodec_send_packet(cc, pkt);
                        if (ret == 0) {
                            av_packet_unref(pkt);
                            pending = false;
                        } else if (ret != AVERROR(EAGAIN)) {
                            av_packet_unref(pkt);
                            pending = false;
                            break;
                        }
                        continue;
                    }
                    last_read = av_read_frame(cfmt, pkt);
                    packets_read++;
                    if (last_read < 0) {
                        avcodec_send_packet(cc, nullptr);
                        flushing = true;
                        continue;
                    }
                    if (pkt->stream_index == cidx) {
                        pending = true;
                    } else {
                        av_packet_unref(pkt);
                    }
                }
                if (pending) {
                    av_packet_unref(pkt);
                }
                av_frame_free(&frame);
                av_packet_free(&pkt);
                // Keep the container hint when the decoder could not produce
                // a single frame. The GIF demuxer already counts the image
                // blocks while it scans the file, so st->nb_frames is
                // authoritative even when the parser is unavailable.
                if (counted > 0) {
                    out.nb_frames = counted;
                }
                // The real cadence of the clip, the same value ffprobe ends
                // up reporting for r_frame_rate.
                if (counted > 0 && out.duration_seconds > 0.0) {
                    out.fps = static_cast<double>(counted) / out.duration_seconds;
                }
                {
                    char buf[192];
                    std::snprintf(buf, sizeof(buf),
                                  "probe count: streams=%u cidx=%d packets=%d counted=%d lastRead=%d",
                                  cfmt->nb_streams, cidx, packets_read, counted, last_read);
                    inproc_log(buf);
                }
            }
            avcodec_free_context(&cc);
        }
        avformat_close_input(&cfmt);
        inproc_log(("probe frames: " + path + " -> " + std::to_string(out.nb_frames) +
                    " fps=" + std::to_string(out.fps)).c_str());
    }

    out.valid = (out.width > 0 && out.height > 0);
    avformat_close_input(&fmt);
    return out.valid;
}

int video_to_gif_inproc(const std::string& input_path,
                        const std::string& output_path,
                        const VideoToGifOptions& opts_in,
                        VideoToGifResult* result,
                        PipelineProgressFn progress, void* user_data) {
    if (input_path.empty() || output_path.empty()) {
        return MS_PIPE_ERR_INVALID_ARG;
    }
    VideoToGifOptions opts = opts_in;

    // 1. Probe the input.
    VideoInfo info;
    if (!probe_video(input_path, info, false)) {
        return MS_PIPE_ERR_INVALID_FORMAT;
    }
    normalize_video_options(opts, info);

    // 2. Intermediate files, next to the output just like the Windows build.
    const std::string tmp_mkv = output_path + ".tmp.mkv";
    const std::string tmp_mkv2 = output_path + ".tmp2.mkv";
    const std::string tmp_pal = output_path + ".pal.png";
    std::remove(tmp_mkv.c_str());
    std::remove(tmp_mkv2.c_str());
    std::remove(tmp_pal.c_str());

    StageProgress sp;
    sp.fn = progress;
    sp.user = user_data;

    // 3. Stage A: fps + scale normalisation into an intermediate ffv1 file.
    {
        std::string filter = "[0:v]";
        if (opts.start_seconds > 0.0 || opts.end_seconds > 0.0) {
            char buf[64];
            std::snprintf(buf, sizeof(buf), "trim=%.3f:", opts.start_seconds);
            filter += buf;
            if (opts.end_seconds > 0.0) {
                std::snprintf(buf, sizeof(buf), "%.3f", opts.end_seconds);
                filter += buf;
            }
            filter += ",setpts=PTS-STARTPTS,";
        }
        filter += "fps=" + std::to_string(opts.fps) + ",scale=" +
                  std::to_string(opts.width) + ":-2,format=rgba[v]";

        InprocJob job;
        job.sources.push_back({input_path, nullptr});
        job.output_path = tmp_mkv;
        job.format = "matroska";
        job.video_codec = "ffv1";
        job.pix_fmt = "yuva420p";
        job.level = 3;
        job.filter = filter;
        job.map_label = "[v]";

        inproc_log("pipeline: stage A start (fps/scale -> ffv1)");
        sp.base = 0.0f;
        sp.span = 0.6f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        if (ret != 0) {
            std::remove(tmp_mkv.c_str());
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 4. Stage B: optional ping-pong.
    std::string feed = tmp_mkv;
    if (opts.ping_pong) {
        VideoInfo tmp_info;
        bool probed = probe_video(tmp_mkv, tmp_info, false);
        int n = probed ? tmp_info.nb_frames : 0;
        // The Windows build uses the same fallback: the matroska container
        // does not report a frame count, so the trim window covers the whole
        // clip and the ping-pong repeats the first and last frame.
        if (n <= 0) n = 76;

        std::string filter = "[0:v]split=2[main][rev];"
                             "[main]trim=0:" + std::to_string(n) +
                             ",setpts=PTS-STARTPTS[main2];"
                             "[rev]trim=0:" + std::to_string(n - 1) +
                             ",setpts=PTS-STARTPTS,reverse[rev2];"
                             "[main2][rev2]concat=n=2:v=1[v]";

        InprocJob job;
        job.sources.push_back({tmp_mkv, nullptr});
        job.output_path = tmp_mkv2;
        job.format = "matroska";
        job.video_codec = "ffv1";
        job.pix_fmt = "yuva420p";
        job.level = 3;
        job.filter = filter;
        job.map_label = "[v]";

        inproc_log("pipeline: stage B start (ping-pong)");
        sp.base = 0.6f;
        sp.span = 0.2f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        if (!opts.keep_intermediates) {
            std::remove(tmp_mkv.c_str());
        }
        if (ret != 0) {
            std::remove(tmp_mkv2.c_str());
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
        feed = tmp_mkv2;
    }

    // 5. Stage C1: palettegen -> palette image.
    {
        std::string filter = "[0:v]palettegen=stats_mode=diff:max_colors=" +
                             std::to_string(opts.max_colors) +
                             ":reserve_transparent=1[pal]";

        InprocJob job;
        job.sources.push_back({feed, nullptr});
        job.output_path = tmp_pal;
        job.video_codec = "png";
        job.raw_image_output = true;
        job.filter = filter;
        job.map_label = "[pal]";

        inproc_log("pipeline: stage C1 start (palettegen)");
        sp.base = 0.8f;
        sp.span = 0.1f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        if (ret != 0) {
            std::remove(tmp_mkv2.c_str());
            std::remove(tmp_pal.c_str());
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 6. Stage C2: paletteuse -> animated GIF.
    {
        InprocJob job;
        job.sources.push_back({feed, nullptr});
        job.sources.push_back({tmp_pal, nullptr});
        job.output_path = output_path;
        job.format = "gif";
        job.video_codec = "gif";
        job.loop0 = true;
        job.filter = "[0:v][1:v]paletteuse=dither=sierra2_4a[v]";
        job.map_label = "[v]";

        inproc_log("pipeline: stage C2 start (paletteuse)");
        sp.base = 0.8f;
        sp.span = 0.2f;
        int ret = run_inproc_job(job, StageProgress::call, &sp, nullptr, nullptr);
        std::remove(tmp_mkv2.c_str());
        std::remove(tmp_pal.c_str());
        if (ret != 0) {
            return MS_PIPE_ERR_FFMPEG_FAILED;
        }
    }

    // 7. Probe the output.
    VideoInfo out_info;
    if (probe_video(output_path, out_info, true)) {
        if (result != nullptr) {
            result->frame_count = out_info.nb_frames;
            result->output_width = out_info.width;
            result->output_height = out_info.height;
            result->output_fps = static_cast<int>(out_info.fps + 0.5);
        }
    }
    if (result != nullptr) {
        result->file_size = file_size_of(output_path);
    }
    if (progress != nullptr) {
        progress(1.0f, user_data);
    }
    return MS_PIPE_OK;
}

}  // namespace ms
