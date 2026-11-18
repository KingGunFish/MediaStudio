// sdk/src/engine/ms_inproc_exec.cpp
//
// See ms_inproc_exec.h for the contract.
//
// Two behaviours are replicated from the ffmpeg CLI on purpose, because
// getting them wrong silently changes the output:
//
//  1. Auto-rotation. fftools/ffmpeg_filter.c injects transpose / hflip /
//     vflip / rotate filters *before* the user's filter chain whenever the
//     input carries a display matrix. Without this, portrait phone videos
//     come out sideways.
//
//  2. Input binding. The CLI binds the graph's open input pads to the input
//     files by their "[<index>:v]" label. The same labels are used here so
//     that the filter strings produced by mask_builder.cpp keep working
//     unchanged.

#include "ms_inproc_exec.h"

extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
}

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace ms {
namespace {

// ------------------------------------------------------------------ logging

InprocLogFn g_log_fn = nullptr;
void* g_log_user = nullptr;

void av_log_bridge(void* avcl, int level, const char* fmt, va_list vl) {
    (void)avcl;
    if (g_log_fn == nullptr) {
        return;
    }
    char buf[1024];
    int n = vsnprintf(buf, sizeof(buf), fmt, vl);
    if (n < 0) {
        return;
    }
    if (static_cast<size_t>(n) >= sizeof(buf)) {
        buf[sizeof(buf) - 1] = '\0';
    }
    g_log_fn(level, buf, g_log_user);
}

void install_log_bridge() {
    static bool installed = false;
    if (!installed) {
        av_log_set_callback(av_log_bridge);
        installed = true;
    }
}

// ------------------------------------------------------------------ decoder

// Demux + decode helper for one file source.
struct Decoder {
    AVFormatContext* fmt = nullptr;
    AVCodecContext* dec = nullptr;
    int stream_index = -1;
    AVRational tb{0, 1};
    AVRational fps{0, 1};
    double duration_sec = 0.0;
    AVPacket* pkt = nullptr;
    AVFrame* frame = nullptr;
    AVFrame* peeked = nullptr;
    std::deque<AVFrame*> pending;
    bool has_pkt = false;
    bool flushed = false;
    bool eof = false;

    ~Decoder() {
        if (peeked != nullptr) {
            av_frame_free(&peeked);
        }
        while (!pending.empty()) {
            av_frame_free(&pending.front());
            pending.pop_front();
        }
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
    }
};

int open_decoder(const std::string& path, Decoder& d) {
    if (avformat_open_input(&d.fmt, path.c_str(), nullptr, nullptr) < 0) {
        return AVERROR(EIO);
    }
    if (avformat_find_stream_info(d.fmt, nullptr) < 0) {
        return AVERROR(EIO);
    }
    d.stream_index = av_find_best_stream(d.fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (d.stream_index < 0) {
        return AVERROR_STREAM_NOT_FOUND;
    }
    AVStream* st = d.fmt->streams[d.stream_index];
    const AVCodec* decoder = avcodec_find_decoder(st->codecpar->codec_id);
    if (decoder == nullptr) {
        return AVERROR_DECODER_NOT_FOUND;
    }
    d.dec = avcodec_alloc_context3(decoder);
    if (d.dec == nullptr) {
        return AVERROR(ENOMEM);
    }
    if (avcodec_parameters_to_context(d.dec, st->codecpar) < 0) {
        return AVERROR(EINVAL);
    }
    if (avcodec_open2(d.dec, decoder, nullptr) < 0) {
        return AVERROR(EIO);
    }
    d.tb = st->time_base;
    d.fps = av_guess_frame_rate(d.fmt, st, nullptr);
    if (d.fmt->duration > 0) {
        d.duration_sec = static_cast<double>(d.fmt->duration) / AV_TIME_BASE;
    }
    d.pkt = av_packet_alloc();
    d.frame = av_frame_alloc();
    if (d.pkt == nullptr || d.frame == nullptr) {
        return AVERROR(ENOMEM);
    }
    return 0;
}

// Pulls the next decoded frame. Returns 1 on success, 0 at EOF, <0 on error.
int decoder_next(Decoder& d, AVFrame** out) {
    if (d.peeked != nullptr) {
        *out = d.peeked;
        d.peeked = nullptr;
        return 1;
    }
    for (;;) {
        if (!d.pending.empty()) {
            AVFrame* f = d.pending.front();
            d.pending.pop_front();
            *out = f;
            return 1;
        }
        if (d.eof) {
            return 0;
        }

        int ret = avcodec_receive_frame(d.dec, d.frame);
        if (ret == 0) {
            AVFrame* copy = av_frame_alloc();
            if (copy == nullptr) {
                return AVERROR(ENOMEM);
            }
            av_frame_move_ref(copy, d.frame);
            d.pending.push_back(copy);
            continue;
        }
        if (ret == AVERROR_EOF) {
            d.eof = true;
            return 0;
        }
        if (ret != AVERROR(EAGAIN)) {
            return ret;
        }

        // The decoder wants more input.
        if (d.has_pkt) {
            ret = avcodec_send_packet(d.dec, d.pkt);
            if (ret == 0) {
                av_packet_unref(d.pkt);
                d.has_pkt = false;
            } else if (ret == AVERROR(EAGAIN)) {
                continue;  // output buffers full; drain and retry
            } else {
                av_packet_unref(d.pkt);
                d.has_pkt = false;
                return ret;
            }
            continue;
        }

        if (!d.flushed) {
            int r = av_read_frame(d.fmt, d.pkt);
            if (r < 0) {
                avcodec_send_packet(d.dec, nullptr);
                d.flushed = true;
                continue;
            }
            if (d.pkt->stream_index == d.stream_index) {
                d.has_pkt = true;
            } else {
                av_packet_unref(d.pkt);
            }
            continue;
        }

        d.eof = true;
        return 0;
    }
}

// ------------------------------------------------------------------ rotation

// Mirrors fftools/ffmpeg.c:get_rotation().
double normalize_rotation(const int32_t* displaymatrix) {
    if (displaymatrix == nullptr) {
        return 0.0;
    }
    double theta = -std::round(av_display_rotation_get(displaymatrix));
    theta -= 360 * std::floor(theta / 360 + 0.9 / 360);
    return theta;
}

struct FilterSpec {
    std::string name;
    std::string args;
};

// Mirrors the auto-rotate block of
// fftools/ffmpeg_filter.c:configure_input_video_filter().
std::vector<FilterSpec> autorotate_filters(const int32_t* dm) {
    std::vector<FilterSpec> out;
    if (dm == nullptr) {
        return out;
    }
    double theta = normalize_rotation(dm);
    if (std::fabs(theta - 90.0) < 1.0) {
        out.push_back({"transpose", dm[3] > 0 ? "cclock_flip" : "clock"});
    } else if (std::fabs(theta - 180.0) < 1.0) {
        if (dm[0] < 0) {
            out.push_back({"hflip", ""});
        }
        if (dm[4] < 0) {
            out.push_back({"vflip", ""});
        }
    } else if (std::fabs(theta - 270.0) < 1.0) {
        out.push_back({"transpose", dm[3] < 0 ? "clock_flip" : "cclock"});
    } else if (std::fabs(theta) > 1.0) {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "%f*PI/180", theta);
        out.push_back({"rotate", buf});
    } else if (dm[4] < 0) {
        out.push_back({"vflip", ""});
    }
    return out;
}

// ------------------------------------------------------------------ helpers

std::string label_of(int index) {
    return std::to_string(index) + ":v";
}

struct SourceState {
    Decoder dec;
    AVFrame* mem_frame = nullptr;  // in-memory source
    bool is_stream = false;

    // Filled in from the first frame.
    int width = 0;
    int height = 0;
    enum AVPixelFormat pix_fmt = AV_PIX_FMT_NONE;
    AVRational tb{0, 1};
    AVRational fps{0, 1};
    AVRational sar{0, 1};
    int colorspace = AVCOL_SPC_UNSPECIFIED;
    int color_range = AVCOL_RANGE_UNSPECIFIED;
    int32_t displaymatrix[9] = {0};
    bool has_displaymatrix = false;
};

// Reads the display matrix of the first frame. The CLI does this before it
// builds the graph, so the rotation filters exist before the user's chain.
void capture_displaymatrix(SourceState& s, const AVFrame* f) {
    if (f == nullptr) {
        return;
    }
    const AVFrameSideData* sd = av_frame_get_side_data(f, AV_FRAME_DATA_DISPLAYMATRIX);
    if (sd != nullptr && sd->size >= static_cast<int>(sizeof(s.displaymatrix))) {
        std::memcpy(s.displaymatrix, sd->data, sizeof(s.displaymatrix));
        s.has_displaymatrix = true;
    }
}

// ------------------------------------------------------------------ encoder

struct EncoderState {
    AVFormatContext* fmt = nullptr;   // null in raw image mode
    AVCodecContext* cc = nullptr;
    AVStream* st = nullptr;
    AVPacket* pkt = nullptr;
    AVFrame* frame = nullptr;
    AVIOContext* raw_pb = nullptr;     // raw image mode

    ~EncoderState() {
        av_packet_free(&pkt);
        av_frame_free(&frame);
        if (raw_pb != nullptr) {
            avio_closep(&raw_pb);
        }
        if (fmt != nullptr) {
            if (fmt->pb != nullptr) {
                avio_closep(&fmt->pb);
            }
            avformat_free_context(fmt);
        }
        avcodec_free_context(&cc);
    }
};

// Builds the list of pixel formats the output may use, the same way the
// ffmpeg CLI does with choose_pix_fmts():
//   - an explicit "-pix_fmt" pins the single format
//   - otherwise the encoder's own list is used and the filter graph
//     negotiates the concrete format
std::string encoder_format_list(const AVCodec* enc, const std::string& pix_fmt) {
    if (!pix_fmt.empty()) {
        return pix_fmt;
    }
    std::string out;
    if (enc == nullptr || enc->pix_fmts == nullptr) {
        return out;
    }
    for (const enum AVPixelFormat* p = enc->pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        const char* name = av_get_pix_fmt_name(*p);
        if (name == nullptr) {
            continue;
        }
        if (!out.empty()) {
            out += "|";
        }
        out += name;
    }
    return out;
}

int open_encoder(const InprocJob& job, EncoderState& e, const AVCodec* enc,
                 int width, int height, enum AVPixelFormat pix_fmt,
                 AVRational time_base) {
    if (job.output_path.empty() || enc == nullptr) {
        return 0;
    }
    if (!job.raw_image_output) {
        if (e.fmt == nullptr) {
            if (avformat_alloc_output_context2(&e.fmt, nullptr, job.format.c_str(),
                                               job.output_path.c_str()) < 0 ||
                e.fmt == nullptr) {
                return AVERROR(EIO);
            }
        }
        e.st = avformat_new_stream(e.fmt, nullptr);
        if (e.st == nullptr) {
            return AVERROR(ENOMEM);
        }
    }
    e.cc = avcodec_alloc_context3(enc);
    if (e.cc == nullptr) {
        return AVERROR(ENOMEM);
    }
    e.cc->width = width;
    e.cc->height = height;
    // The graph has already negotiated the format, so the encoder receives
    // frames in exactly the pixel format it expects.
    if (pix_fmt != AV_PIX_FMT_NONE) {
        e.cc->pix_fmt = pix_fmt;
    }
    if (time_base.num > 0 && time_base.den > 0) {
        e.cc->time_base = time_base;
    } else {
        e.cc->time_base = AVRational{1, 25};
    }
    if (job.level >= 0) {
        // ffv1 exposes "level" as an encoder option; other encoders simply
        // do not have it, which is not an error.
        av_opt_set_int(e.cc, "level", job.level, 0);
    }
    if (e.st != nullptr) {
        e.st->time_base = e.cc->time_base;
    }
    // The encoder has to be opened before its parameters are copied: ffv1
    // allocates the global header (extradata) in encode_init, and the
    // container needs it to be able to decode the stream again.
    if (avcodec_open2(e.cc, enc, nullptr) < 0) {
        return AVERROR(EIO);
    }
    if (e.st != nullptr) {
        if (avcodec_parameters_from_context(e.st->codecpar, e.cc) < 0) {
            return AVERROR(EINVAL);
        }
        e.st->time_base = e.cc->time_base;
        // Carry the cadence in the container metadata, like the ffmpeg CLI
        // does, so that a later stage can recover the frame rate.
        e.st->avg_frame_rate = av_inv_q(e.cc->time_base);
    }
    e.pkt = av_packet_alloc();
    e.frame = av_frame_alloc();
    if (e.pkt == nullptr || e.frame == nullptr) {
        return AVERROR(ENOMEM);
    }
    return 0;
}

int write_encoder_header(EncoderState& e, const InprocJob& job) {
    if (job.raw_image_output) {
        return avio_open(&e.raw_pb, job.output_path.c_str(), AVIO_FLAG_WRITE);
    }
    if (e.fmt == nullptr) {
        return 0;  // capture mode, nothing to open
    }
    AVDictionary* opts = nullptr;
    if (job.loop0) {
        av_dict_set(&opts, "loop", "0", 0);
    }
    int ret = 0;
    if (!(e.fmt->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&e.fmt->pb, job.output_path.c_str(), AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_dict_free(&opts);
            return ret;
        }
    }
    ret = avformat_write_header(e.fmt, &opts);
    av_dict_free(&opts);
    return ret;
}

int write_frame(EncoderState& e, AVFrame* src, AVRational src_tb) {
    if (e.cc == nullptr) {
        return 0;
    }
    AVFrame* dst = e.frame;
    av_frame_unref(dst);
    int ret = av_frame_ref(dst, src);
    if (ret < 0) {
        return ret;
    }
    dst->pts = av_rescale_q(src->pts, src_tb, e.cc->time_base);
    dst->time_base = e.cc->time_base;

    ret = avcodec_send_frame(e.cc, dst);
    if (ret < 0) {
        return ret;
    }
    for (;;) {
        ret = avcodec_receive_packet(e.cc, e.pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return ret;
        }
        if (e.raw_pb != nullptr) {
            if (e.pkt->size > 0) {
                avio_write(e.raw_pb, e.pkt->data, e.pkt->size);
            }
            av_packet_unref(e.pkt);
            continue;
        }
        e.pkt->stream_index = e.st->index;
        av_packet_rescale_ts(e.pkt, e.cc->time_base, e.st->time_base);
        ret = av_interleaved_write_frame(e.fmt, e.pkt);
        av_packet_unref(e.pkt);
        if (ret < 0) {
            return ret;
        }
    }
}

int flush_encoder(EncoderState& e) {
    if (e.cc == nullptr) {
        return 0;
    }
    int ret = avcodec_send_frame(e.cc, nullptr);
    if (ret < 0 && ret != AVERROR_EOF) {
        return ret;
    }
    for (;;) {
        ret = avcodec_receive_packet(e.cc, e.pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            return ret;
        }
        if (e.raw_pb != nullptr) {
            if (e.pkt->size > 0) {
                avio_write(e.raw_pb, e.pkt->data, e.pkt->size);
            }
            av_packet_unref(e.pkt);
            continue;
        }
        e.pkt->stream_index = e.st->index;
        av_packet_rescale_ts(e.pkt, e.cc->time_base, e.st->time_base);
        ret = av_interleaved_write_frame(e.fmt, e.pkt);
        av_packet_unref(e.pkt);
        if (ret < 0) {
            return ret;
        }
    }
    if (e.raw_pb != nullptr) {
        avio_flush(e.raw_pb);
        return 0;
    }
    return av_write_trailer(e.fmt);
}

// ------------------------------------------------------------------ job

void cleanup_inputs(AVFilterInOut* io) {
    avfilter_inout_free(&io);
}

}  // namespace

void set_inproc_log(InprocLogFn fn, void* user_data) {
    g_log_fn = fn;
    g_log_user = user_data;
    install_log_bridge();
}

void inproc_log(const char* message) {
    install_log_bridge();
    if (g_log_fn != nullptr && message != nullptr) {
        g_log_fn(48 /* AV_LOG_INFO */, message, g_log_user);
    }
}

int run_inproc_job(const InprocJob& job,
                   InprocProgressFn progress, void* progress_user,
                   InprocFrameFn on_frame, void* frame_user) {
    install_log_bridge();

    if (job.sources.empty() || job.filter.empty()) {
        return AVERROR(EINVAL);
    }
    inproc_log(("job filter: " + job.filter).c_str());
    if (!job.output_path.empty()) {
        inproc_log(("job output: " + job.output_path).c_str());
    }

    // ---- 1. open the sources -------------------------------------------
    std::vector<SourceState> sources(job.sources.size());
    for (size_t i = 0; i < job.sources.size(); i++) {
        SourceState& s = sources[i];
        if (job.sources[i].frame != nullptr) {
            s.mem_frame = job.sources[i].frame;
            s.is_stream = false;
        } else {
            int ret = open_decoder(job.sources[i].path, s.dec);
            if (ret < 0) {
                return ret;
            }
            s.is_stream = true;
        }
    }

    // ---- 2. learn the geometry of every source --------------------------
    // The first frame of the stream source defines the buffersrc parameters,
    // exactly like the CLI does.
    for (size_t i = 0; i < sources.size(); i++) {
        SourceState& s = sources[i];
        if (s.is_stream) {
            AVFrame* f = nullptr;
            int ret = decoder_next(s.dec, &f);
            if (ret <= 0) {
                return ret < 0 ? ret : AVERROR_INVALIDDATA;
            }
            s.width = f->width;
            s.height = f->height;
            s.pix_fmt = static_cast<enum AVPixelFormat>(f->format);
            s.tb = (f->time_base.num > 0 && f->time_base.den > 0) ? f->time_base : s.dec.tb;
            s.fps = s.dec.fps;
            s.sar = f->sample_aspect_ratio;
            s.colorspace = f->colorspace;
            s.color_range = f->color_range;
            capture_displaymatrix(s, f);
            s.dec.peeked = f;  // hand the frame back to the main loop
        } else {
            s.mem_frame = job.sources[i].frame;
            s.width = s.mem_frame->width;
            s.height = s.mem_frame->height;
            s.pix_fmt = static_cast<enum AVPixelFormat>(s.mem_frame->format);
            s.tb = s.mem_frame->time_base;
            if (s.tb.num <= 0 || s.tb.den <= 0) {
                s.tb = AVRational{1, 25};
            }
            s.sar = s.mem_frame->sample_aspect_ratio;
            s.colorspace = s.mem_frame->colorspace;
            s.color_range = s.mem_frame->color_range;
        }
    }

    // ---- 3. find the encoder ---------------------------------------------
    // The encoder's pixel format list constrains the filter graph, so it
    // has to be known before the graph is built.
    const AVCodec* enc_codec = nullptr;
    if (!job.output_path.empty()) {
        enc_codec = avcodec_find_encoder_by_name(job.video_codec.c_str());
        if (enc_codec == nullptr) {
            return AVERROR_ENCODER_NOT_FOUND;
        }
    }

    // ---- 4. build the filter graph --------------------------------------
    AVFilterGraph* graph = avfilter_graph_alloc();
    if (graph == nullptr) {
        return AVERROR(ENOMEM);
    }

    AVFilterContext* sink =
        avfilter_graph_alloc_filter(graph, avfilter_get_by_name("buffersink"), "out_sink");
    if (sink == nullptr || avfilter_init_dict(sink, nullptr) < 0) {
        avfilter_graph_free(&graph);
        return AVERROR(EIO);
    }

    AVFilterInOut* graph_inputs = nullptr;
    AVFilterInOut* graph_outputs = nullptr;
    int ret = avfilter_graph_parse_ptr(graph, job.filter.c_str(), &graph_inputs,
                                       &graph_outputs, nullptr);
    if (ret < 0) {
        avfilter_graph_free(&graph);
        return ret;
    }

    // ---- 4. create one buffer source per input --------------------------
    std::vector<AVFilterContext*> src_ctx(sources.size(), nullptr);
    for (size_t i = 0; i < sources.size(); i++) {
        SourceState& s = sources[i];
        AVRational sar = (s.sar.num > 0 && s.sar.den > 0) ? s.sar : AVRational{1, 1};
        char args[320];
        std::snprintf(args, sizeof(args),
                      "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:"
                      "pixel_aspect=%d/%d:colorspace=%d:range=%d",
                      s.width, s.height, static_cast<int>(s.pix_fmt), s.tb.num,
                      s.tb.den, sar.num, sar.den, s.colorspace, s.color_range);
        if (s.fps.num > 0 && s.fps.den > 0) {
            size_t used = std::strlen(args);
            std::snprintf(args + used, sizeof(args) - used, ":frame_rate=%d/%d",
                          s.fps.num, s.fps.den);
        }
        ret = avfilter_graph_create_filter(&src_ctx[i], avfilter_get_by_name("buffer"),
                                           label_of(static_cast<int>(i)).c_str(), args,
                                           nullptr, graph);
        if (ret < 0) {
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    // ---- 5. bind the graph's open input pads ----------------------------
    std::vector<bool> used(sources.size(), false);
    for (AVFilterInOut* cur = graph_inputs; cur != nullptr;) {
        AVFilterInOut* next = cur->next;
        cur->next = nullptr;

        int idx = -1;
        if (cur->name != nullptr && cur->name[0] >= '0' && cur->name[0] <= '9') {
            idx = cur->name[0] - '0';
        }
        if (idx < 0 || idx >= static_cast<int>(sources.size()) || used[idx]) {
            idx = -1;
            for (size_t k = 0; k < sources.size(); k++) {
                if (!used[k]) {
                    idx = static_cast<int>(k);
                    break;
                }
            }
        }
        if (idx < 0) {
            cleanup_inputs(cur);
            avfilter_graph_free(&graph);
            return AVERROR(EINVAL);
        }
        used[idx] = true;

        // The CLI injects the rotation filters between the buffer source and
        // the user's chain; do the same so portrait videos stay upright.
        AVFilterContext* head = src_ctx[idx];
        std::vector<FilterSpec> rots =
            autorotate_filters(sources[idx].has_displaymatrix ? sources[idx].displaymatrix
                                                             : nullptr);
        for (size_t k = 0; k < rots.size(); k++) {
            AVFilterContext* rc = nullptr;
            ret = avfilter_graph_create_filter(&rc, avfilter_get_by_name(rots[k].name.c_str()),
                                               "autorotate", rots[k].args.c_str(), nullptr,
                                               graph);
            if (ret < 0) {
                cleanup_inputs(cur);
                avfilter_graph_free(&graph);
                return ret;
            }
            ret = avfilter_link(head, 0, rc, 0);
            if (ret < 0) {
                cleanup_inputs(cur);
                avfilter_graph_free(&graph);
                return ret;
            }
            head = rc;
        }

        ret = avfilter_link(head, 0, cur->filter_ctx, cur->pad_idx);
        cleanup_inputs(cur);
        if (ret < 0) {
            avfilter_graph_free(&graph);
            return ret;
        }
        cur = next;
    }

    // ---- 6. bind the graph output to the sink ---------------------------
    if (graph_outputs == nullptr) {
        avfilter_graph_free(&graph);
        return AVERROR(EINVAL);
    }
    AVFilterInOut* chosen = graph_outputs;
    if (!job.map_label.empty()) {
        std::string want = job.map_label;
        if (want.size() >= 2 && want.front() == '[' && want.back() == ']') {
            want = want.substr(1, want.size() - 2);
        }
        for (AVFilterInOut* cur = graph_outputs; cur != nullptr; cur = cur->next) {
            if (cur->name != nullptr && want == cur->name) {
                chosen = cur;
                break;
            }
        }
    }
    AVFilterContext* out_filter = chosen->filter_ctx;
    int out_pad = chosen->pad_idx;

    // The encoder reads the frame planes in its own pixel format, so the
    // graph has to deliver that format. The ffmpeg CLI inserts a "format"
    // filter for exactly this reason; the same node is added here so the
    // user's filter string stays untouched.
    std::string fmt_list = encoder_format_list(enc_codec, job.pix_fmt);
    if (!fmt_list.empty()) {
        AVFilterContext* conv = nullptr;
        ret = avfilter_graph_create_filter(&conv, avfilter_get_by_name("format"),
                                           "out_format", ("pix_fmts=" + fmt_list).c_str(),
                                           nullptr, graph);
        if (ret < 0) {
            avfilter_inout_free(&graph_outputs);
            avfilter_graph_free(&graph);
            return ret;
        }
        ret = avfilter_link(out_filter, out_pad, conv, 0);
        if (ret < 0) {
            avfilter_inout_free(&graph_outputs);
            avfilter_graph_free(&graph);
            return ret;
        }
        out_filter = conv;
        out_pad = 0;
    }

    ret = avfilter_link(out_filter, out_pad, sink, 0);
    avfilter_inout_free(&graph_outputs);
    if (ret < 0) {
        avfilter_graph_free(&graph);
        return ret;
    }

    // ---- 7. configure ----------------------------------------------------
    ret = avfilter_graph_config(graph, nullptr);
    if (ret < 0) {
        avfilter_graph_free(&graph);
        return ret;
    }

    AVRational out_tb = av_buffersink_get_time_base(sink);
    AVRational out_rate = av_buffersink_get_frame_rate(sink);
    int out_w = av_buffersink_get_w(sink);
    int out_h = av_buffersink_get_h(sink);
    enum AVPixelFormat out_fmt = static_cast<enum AVPixelFormat>(av_buffersink_get_format(sink));
    inproc_log(("negotiated output format: " +
                std::string(av_get_pix_fmt_name(out_fmt))).c_str());
    {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "negotiated rate=%d/%d tb=%d/%d size=%dx%d src0fps=%d/%d",
                      out_rate.num, out_rate.den, out_tb.num, out_tb.den, out_w, out_h,
                      sources[0].fps.num, sources[0].fps.den);
        inproc_log(buf);
    }

    // ---- 8. open the encoder --------------------------------------------
    EncoderState enc;
    // The frame rate of the graph output is not always known: filters such
    // as concat drop it. Fall back to the rate of the primary input so that
    // the container keeps the original cadence; the ffmpeg CLI reaches the
    // same result through the frame timestamps it writes.
    AVRational eff_rate = out_rate;
    if (eff_rate.num <= 0 || eff_rate.den <= 0) {
        eff_rate = sources[0].fps;
    }
    AVRational enc_tb = (eff_rate.num > 0 && eff_rate.den > 0) ? av_inv_q(eff_rate) : out_tb;
    ret = open_encoder(job, enc, enc_codec, out_w, out_h, out_fmt, enc_tb);
    if (ret < 0) {
        avfilter_graph_free(&graph);
        return ret;
    }
    if (!job.output_path.empty()) {
        ret = write_encoder_header(enc, job);
        if (ret < 0) {
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    // ---- 9. push the in-memory sources ----------------------------------
    for (size_t i = 0; i < sources.size(); i++) {
        if (sources[i].is_stream) {
            continue;
        }
        AVFrame* f = sources[i].mem_frame;
        f->pts = 0;
        ret = av_buffersrc_add_frame_flags(src_ctx[i], f, AV_BUFFERSRC_FLAG_KEEP_REF);
        if (ret < 0) {
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    // ---- 10. run ---------------------------------------------------------
    AVFrame* out = av_frame_alloc();
    if (out == nullptr) {
        avfilter_graph_free(&graph);
        return AVERROR(ENOMEM);
    }
    int frames_out = 0;
    bool cancelled = false;

    auto handle_output = [&](AVFrame* frame) -> int {
        if (enc.cc != nullptr) {
            int r = write_frame(enc, frame, out_tb);
            if (r < 0) {
                return r;
            }
        } else if (on_frame != nullptr) {
            int r = on_frame(frame, frame_user);
            if (r < 0) {
                return r;
            }
        }
        frames_out++;
        return 0;
    };

    // Pumps one stream source into the graph.
    auto pump_source = [&](size_t idx) -> int {
        SourceState& s = sources[idx];
        for (;;) {
            AVFrame* f = nullptr;
            int r = decoder_next(s.dec, &f);
            if (r < 0) {
                return r;
            }
            if (r == 0) {
                break;
            }
            if (f->time_base.num > 0 && f->time_base.den > 0 &&
                (f->time_base.num != s.tb.num || f->time_base.den != s.tb.den)) {
                f->pts = av_rescale_q(f->pts, f->time_base, s.tb);
            }
            f->time_base = s.tb;
            if (s.has_displaymatrix) {
                // The CLI drops the matrix once it has been applied.
                av_frame_remove_side_data(f, AV_FRAME_DATA_DISPLAYMATRIX);
            }
            r = av_buffersrc_add_frame_flags(src_ctx[idx], f, AV_BUFFERSRC_FLAG_KEEP_REF);
            av_frame_free(&f);
            if (r < 0) {
                return r;
            }
            for (;;) {
                r = av_buffersink_get_frame(sink, out);
                if (r < 0) {
                    break;
                }
                r = handle_output(out);
                av_frame_unref(out);
                if (r < 0) {
                    return r;
                }
            }
            if (progress != nullptr && s.dec.duration_sec > 0.0 &&
                out->pts != AV_NOPTS_VALUE) {
                double pos = static_cast<double>(out->pts) * out_tb.num / out_tb.den;
                float p = static_cast<float>(pos / s.dec.duration_sec);
                if (p < 0.0f) p = 0.0f;
                if (p > 1.0f) p = 1.0f;
                if (!progress(p, progress_user)) {
                    cancelled = true;
                    break;
                }
            }
        }
        // EOF for this source.
        int eof_ret = av_buffersrc_add_frame_flags(src_ctx[idx], nullptr, 0);
        (void)eof_ret;
        for (;;) {
            int r = av_buffersink_get_frame(sink, out);
            if (r < 0) {
                break;
            }
            r = handle_output(out);
            av_frame_unref(out);
            if (r < 0) {
                return r;
            }
        }
        return 0;
    };

    // Secondary sources first. The only one in use is the palette image
    // handed to paletteuse; feeding it before the video guarantees the
    // palette is available when the first video frame is processed.
    for (size_t i = 1; i < sources.size(); i++) {
        if (!sources[i].is_stream) {
            continue;
        }
        ret = pump_source(i);
        if (ret < 0) {
            av_frame_free(&out);
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    for (size_t i = 0; i < sources.size() && !cancelled; i++) {
        if (!sources[i].is_stream) {
            continue;
        }
        ret = pump_source(i);
        if (ret < 0) {
            av_frame_free(&out);
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    // ---- 11. flush the encoder ------------------------------------------
    if (enc.fmt != nullptr) {
        ret = flush_encoder(enc);
        if (ret < 0) {
            av_frame_free(&out);
            avfilter_graph_free(&graph);
            return ret;
        }
    }

    av_frame_free(&out);
    avfilter_graph_free(&graph);
    return 0;
}

}  // namespace ms
