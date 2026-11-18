/*
 * End-to-end FFmpeg probe for the HarmonyOS port.
 *
 * Two things are proven here that the port design depends on:
 *
 *  1. avfilterProbe() parses and evaluates the *exact* alpha expression that
 *     sdk/src/gif_keying/mask_builder.cpp generates, on a real OHOS device.
 *     If this passes, the port can keep the filter strings byte-for-byte
 *     identical and only replace the executor (see docs 4.4.1).
 *
 *  2. gifEncodeProbe() encodes a real animated GIF with the OHOS-built
 *     libavcodec and verifies the GIF89a magic on disk, i.e. the whole
 *     decode/filter/encode chain is alive on the device.
 */

#include "verify_common.h"

extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>
#include <libavutil/dict.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
}

#include <string>
#include <cstdio>
#include <cstring>

// The exact expression mask_builder.cpp builds for the default background
// colour (231,225,223) and thresholds (distance 1500, channel 220).
static const char *MS_ALPHA_EXPR =
    "if(lt((r(X,Y)-231)*(r(X,Y)-231)+(g(X,Y)-225)*(g(X,Y)-225)+"
    "(b(X,Y)-223)*(b(X,Y)-223),1500)+gt(r(X,Y),220)+gt(g(X,Y),220)+"
    "gt(b(X,Y),220),0,255)";

// The complete filter_complex mask_builder.cpp emits.
static const char *MS_KEYING_FILTER =
    "[0:v]fps=15,scale=480:-2,format=rgb24[rgb];"
    "[0:v]fps=15,scale=480:-2,format=rgba,"
    "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='"
    "if(lt((r(X,Y)-231)*(r(X,Y)-231)+(g(X,Y)-225)*(g(X,Y)-225)+"
    "(b(X,Y)-223)*(b(X,Y)-223),1500)+gt(r(X,Y),220)+gt(g(X,Y),220)+"
    "gt(b(X,Y),220),0,255)',format=rgba,alphaextract,format=gray[mask_a];"
    "[rgb][mask_a]alphamerge,format=rgba";

// ------------------------------------------------------------------ helpers

static std::string lastFmt;

static void FillRgba(AVFrame *f, uint8_t r, uint8_t g, uint8_t b)
{
    for (int y = 0; y < f->height; y++) {
        for (int x = 0; x < f->width; x++) {
            uint8_t *p = f->data[0] + y * f->linesize[0] + x * 4;
            p[0] = r;
            p[1] = g;
            p[2] = b;
            p[3] = 255;
        }
    }
}

/**
 * Push one RGBA frame through buffer source -> geq -> buffer sink and return
 * the alpha byte of the first output pixel.
 *
 * NOTE: FFmpeg 7.x changed the avfilter API:
 *   avfilter_graph_alloc_filter(graph, filter, name)  -> returns the context
 *   avfilter_init_dict(ctx, &options)                  -> options are a dict
 */
static int RunGeqAlpha(int r, int g, int b)
{
    AVFilterGraph *graph = avfilter_graph_alloc();
    if (graph == nullptr) {
        return -1;
    }

    AVFilterContext *src = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("buffer"), "src");
    AVFilterContext *geq = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("geq"), "geq");
    AVFilterContext *sink = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("buffersink"), "sink");
    if (src == nullptr || geq == nullptr || sink == nullptr) {
        avfilter_graph_free(&graph);
        return -2;
    }

    AVDictionary *srcOpts = nullptr;
    av_dict_set(&srcOpts, "video_size", "64x64", 0);
    av_dict_set(&srcOpts, "pix_fmt", "26", 0);          // AV_PIX_FMT_RGBA
    av_dict_set(&srcOpts, "time_base", "1/25", 0);
    av_dict_set(&srcOpts, "pixel_aspect_ratio", "1/1", 0);
    if (avfilter_init_dict(src, &srcOpts) < 0) {
        av_dict_free(&srcOpts);
        avfilter_graph_free(&graph);
        return -3;
    }
    av_dict_free(&srcOpts);

    AVDictionary *geqOpts = nullptr;
    av_dict_set(&geqOpts, "r", "r(X,Y)", 0);
    av_dict_set(&geqOpts, "g", "g(X,Y)", 0);
    av_dict_set(&geqOpts, "b", "b(X,Y)", 0);
    av_dict_set(&geqOpts, "a", MS_ALPHA_EXPR, 0);
    if (avfilter_init_dict(geq, &geqOpts) < 0) {
        av_dict_free(&geqOpts);
        avfilter_graph_free(&graph);
        return -4;
    }
    av_dict_free(&geqOpts);

    if (avfilter_init_dict(sink, nullptr) < 0) {
        avfilter_graph_free(&graph);
        return -5;
    }

    avfilter_link(src, 0, geq, 0);
    avfilter_link(geq, 0, sink, 0);
    if (avfilter_graph_config(graph, nullptr) < 0) {
        avfilter_graph_free(&graph);
        return -6;
    }

    AVFrame *in = av_frame_alloc();
    in->format = AV_PIX_FMT_RGBA;
    in->width = 64;
    in->height = 64;
    av_frame_get_buffer(in, 0);
    FillRgba(in, (uint8_t)r, (uint8_t)g, (uint8_t)b);
    in->pts = 0;

    int alpha = -1;
    std::string fmtName = "none";
    if (av_buffersrc_add_frame_flags(src, in, AV_BUFFERSRC_FLAG_KEEP_REF) >= 0) {
        AVFrame *out = av_frame_alloc();
        if (av_buffersink_get_frame(sink, out) >= 0) {
            // FFmpeg 7.x types AVFrame::format as int (dynamic pixel formats).
            enum AVPixelFormat pf = (enum AVPixelFormat)out->format;
            const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(pf);
            if (d != nullptr) {
                fmtName = av_get_pix_fmt_name(pf);
                // geq() outputs a planar format (GBRP/GBRAP) when per-plane
                // expressions are used, so the alpha lives in its own plane.
                if ((d->flags & AV_PIX_FMT_FLAG_PLANAR) && out->data[3] != nullptr) {
                    alpha = out->data[3][0];
                } else {
                    alpha = out->data[0][3];
                }
            }
        }
        av_frame_free(&out);
    }
    av_frame_free(&in);
    avfilter_graph_free(&graph);
    lastFmt = fmtName;
    return alpha;
}

// ------------------------------------------------------------------ probes

/**
 * P6: the real keying filter chain
 *   - parses the complete filter_complex string produced by mask_builder.cpp
 *   - evaluates the alpha expression on a background-coloured frame (expect 0)
 *     and on a foreground-coloured frame (expect 255)
 */
napi_value AvfilterProbe(napi_env env, napi_callback_info info)
{
    std::string out;

    AVFilterGraph *parsed = avfilter_graph_alloc();
    int prc = avfilter_graph_parse_ptr(parsed, MS_KEYING_FILTER, nullptr, nullptr, nullptr);
    if (prc < 0) {
        out += "parse=FAILED(" + std::to_string(prc) + ") ";
        avfilter_graph_free(&parsed);
        return MakeString(env, out);
    }
    out += "parse=OK(filters=" + std::to_string(parsed->nb_filters) + ") ";
    avfilter_graph_free(&parsed);

    int aBg = RunGeqAlpha(231, 225, 223);     // exactly the background colour
    int aFg = RunGeqAlpha(10, 200, 10);       // clearly not background
    out += "alpha(bg)=" + std::to_string(aBg) + " alpha(fg)=" + std::to_string(aFg);
    out += " fmt=" + lastFmt;
    out += (aBg == 0 && aFg == 255) ? " verdict=PASS" : " verdict=FAIL";

    LOGI("avfilterProbe %s", out.c_str());
    return MakeString(env, out);
}

/**
 * P7: real GIF encoding through the OHOS-built libavcodec/libavformat.
 * Writes a 2-frame animated GIF and verifies the GIF89a magic on disk.
 */
napi_value GifEncodeProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string path = "/data/local/tmp/probe.gif";
    if (argc >= 1) {
        size_t need = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &need);
        std::string buf(need + 1, '\0');
        size_t written = 0;
        napi_get_value_string_utf8(env, argv[0], &buf[0], need + 1, &written);
        buf.resize(written);
        path = buf;
    }

    std::string out;
    AVFormatContext *fmt = nullptr;
    if (avformat_alloc_output_context2(&fmt, nullptr, "gif", path.c_str()) < 0 || fmt == nullptr) {
        return MakeString(env, "gif_encode: alloc_output_context FAILED");
    }

    const AVCodec *enc = avcodec_find_encoder(fmt->oformat->video_codec);
    if (enc == nullptr) {
        avformat_free_context(fmt);
        return MakeString(env, "gif_encode: no gif encoder");
    }

    AVStream *st = avformat_new_stream(fmt, nullptr);
    AVCodecContext *cc = avcodec_alloc_context3(enc);
    cc->width = 64;
    cc->height = 64;
    cc->pix_fmt = AV_PIX_FMT_RGB8;
    cc->time_base = AVRational{1, 10};
    if (avcodec_open2(cc, enc, nullptr) < 0) {
        avcodec_free_context(&cc);
        avformat_free_context(fmt);
        return MakeString(env, "gif_encode: avcodec_open2 FAILED");
    }
    avcodec_parameters_from_context(st->codecpar, cc);
    st->time_base = cc->time_base;

    if (avio_open(&fmt->pb, path.c_str(), AVIO_FLAG_WRITE) < 0) {
        avcodec_free_context(&cc);
        avformat_free_context(fmt);
        return MakeString(env, "gif_encode: avio_open FAILED");
    }
    if (avformat_write_header(fmt, nullptr) < 0) {
        avio_closep(&fmt->pb);
        avcodec_free_context(&cc);
        avformat_free_context(fmt);
        return MakeString(env, "gif_encode: write_header FAILED");
    }

    int packets = 0;
    AVPacket *pkt = av_packet_alloc();
    for (int i = 0; i < 2; i++) {
        AVFrame *f = av_frame_alloc();
        f->format = AV_PIX_FMT_RGB8;
        f->width = 64;
        f->height = 64;
        av_frame_get_buffer(f, 0);
        for (int y = 0; y < 64; y++) {
            memset(f->data[0] + y * f->linesize[0], 20 + i * 60, 64);
        }
        f->pts = i;
        if (avcodec_send_frame(cc, f) == 0) {
            int ret = 0;
            while ((ret = avcodec_receive_packet(cc, pkt)) == 0) {
                pkt->stream_index = st->index;
                av_packet_rescale_ts(pkt, cc->time_base, st->time_base);
                av_interleaved_write_frame(fmt, pkt);
                packets++;
                av_packet_unref(pkt);
            }
        }
        av_frame_free(&f);
    }
    avcodec_send_frame(cc, nullptr);
    {
        int ret = 0;
        while ((ret = avcodec_receive_packet(cc, pkt)) == 0) {
            pkt->stream_index = st->index;
            av_packet_rescale_ts(pkt, cc->time_base, st->time_base);
            av_interleaved_write_frame(fmt, pkt);
            packets++;
            av_packet_unref(pkt);
        }
    }
    av_packet_free(&pkt);

    av_write_trailer(fmt);
    avio_closep(&fmt->pb);
    avcodec_free_context(&cc);
    avformat_free_context(fmt);

    // Verify the file on disk.
    FILE *fp = fopen(path.c_str(), "rb");
    if (fp == nullptr) {
        out = "gif_encode: output file missing (" + path + ")";
    } else {
        unsigned char magic[6] = {0};
        size_t n = fread(magic, 1, 6, fp);
        fseek(fp, 0, SEEK_END);
        long size = ftell(fp);
        fclose(fp);
        out = "gif_encode: packets=" + std::to_string(packets) + " bytes=" + std::to_string(size) +
              " magic=" + std::string((const char *)magic, n) + " verdict=" +
              ((n == 6 && memcmp(magic, "GIF89a", 6) == 0) ? "PASS" : "FAIL");
    }
    LOGI("gifEncodeProbe %s", out.c_str());
    return MakeString(env, out);
}
