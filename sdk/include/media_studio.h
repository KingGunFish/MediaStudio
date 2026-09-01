/*
 * media_studio.h - C ABI for Video/GIF transparent GIF SDK
 *
 * Pure C interface; C++ implementations behind the scenes.
 * Thread-safe; async APIs return opaque task handles.
 */

#ifndef MEDIA_STUDIO_H
#define MEDIA_STUDIO_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* === Export macro === */
#if defined(_WIN32)
    #if defined(MS_BUILDING)
        #define MS_API __declspec(dllexport)
    #else
        #define MS_API __declspec(dllimport)
    #endif
#else
    #define MS_API __attribute__((visibility("default")))
#endif

/* === Error codes === */
typedef enum {
    MS_OK = 0,
    MS_ERR_INVALID_ARG = 1,
    MS_ERR_FILE_NOT_FOUND = 2,
    MS_ERR_FFMPEG_FAILED = 3,
    MS_ERR_INVALID_FORMAT = 4,
    MS_ERR_OUT_OF_MEMORY = 5,
    MS_ERR_CANCELLED = 6,
    MS_ERR_NOT_SUPPORTED = 7,
    MS_ERR_INTERNAL = 99
} MsError;

MS_API const char* ms_error_string(MsError code);

/* === Version === */
MS_API const char* ms_version(void);

/* === Progress callback ===
 * progress: 0.0 ~ 1.0
 * message:   short progress message (may be NULL)
 * user_data: opaque pointer supplied by caller
 * Return:    true to continue, false to request cancellation
 */
typedef bool (*MsProgressCallback)(float progress, const char* message, void* user_data);

/* === Common result === */
typedef struct {
    MsError code;
    char message[256];
    int64_t duration_ms;
} MsResult;

MS_API void ms_result_init(MsResult* result);

/* ===============================
 * 1. Video → GIF
 * =============================== */

typedef struct {
    int width;               /* 0 = auto (preserves aspect) */
    int height;              /* 0 = auto */
    int fps;                 /* 0 = source fps */
    int max_colors;          /* default 256, range 16-256 */
    bool ping_pong;          /* default true */
    int quality;             /* 1-100, default 90 (sierra2_4a dither) */
    double start_seconds;    /* default 0 */
    double end_seconds;      /* default -1 (to end) */
    int log_level;           /* ffmpeg -loglevel, default 24 (warning) */
} MsVideoToGifOptions;

MS_API void ms_video_to_gif_options_init(MsVideoToGifOptions* opts);

typedef struct {
    int frame_count;
    int output_width;
    int output_height;
    int output_fps;
    int64_t file_size;
    int64_t duration_ms;
} MsVideoToGifResult;

/* Synchronous */
MS_API MsError ms_video_to_gif(
    const char* input_path,
    const char* output_path,
    const MsVideoToGifOptions* options,
    MsVideoToGifResult* result,
    MsProgressCallback callback,
    void* user_data
);

/* ===============================
 * 2. GIF keying (background → transparent, watermark removal)
 * =============================== */

typedef enum {
    MS_KEYING_BRIGHTNESS = 0,    /* dark background: lum < threshold */
    MS_KEYING_WHITE_PIXEL = 1,    /* light background: each channel > threshold */
    MS_KEYING_CHROMA_KEY = 2,     /* pure-color background */
    MS_KEYING_COLOR_DISTANCE = 3, /* euclidean distance + channel fallback */
    MS_KEYING_RGB_MASK_SPLIT = 4, /* RGB + mask split + alphamerge (best) */
    MS_KEYING_AUTO = 99           /* heuristic pick */
} MsKeyingAlgorithm;

typedef struct {
    MsKeyingAlgorithm algorithm;

    /* Brightness */
    int brightness_threshold;     /* default 55 */

    /* White-pixel (each channel >=) */
    int white_threshold;          /* default 215 */

    /* Color distance */
    int distance_threshold;       /* squared distance; default 1500 */
    int bg_r;                     /* default 231 */
    int bg_g;                     /* default 225 */
    int bg_b;                     /* default 223 */
    bool use_channel_fallback;    /* default true: any channel > channel_threshold → transparent */
    int channel_threshold;        /* default 220 */

    /* Watermark (Doubao AI watermark) */
    bool watermark_bottom_right;  /* default true */
    bool watermark_top_left;       /* default true */
    int watermark_br_x_ratio;     /* 0-100, default 83 */
    int watermark_br_y_ratio;     /* 0-100, default 75 */
    int watermark_tl_x_ratio;     /* 0-100, default 20 */
    int watermark_tl_y_ratio;     /* 0-100, default 15 */

    /* Output */
    bool ping_pong;               /* default true */
    int max_colors;               /* default 255 */
    int quality;                  /* default 90 */
    int log_level;                /* default 24 */
} MsKeyingOptions;

MS_API void ms_keying_options_init(MsKeyingOptions* opts);

typedef struct {
    int input_frame_count;
    int output_frame_count;
    int output_width;
    int output_height;
    int64_t file_size;
    int64_t duration_ms;
} MsKeyingResult;

/* Synchronous */
MS_API MsError ms_gif_keying(
    const char* input_path,
    const char* output_path,
    const MsKeyingOptions* options,
    MsKeyingResult* result,
    MsProgressCallback callback,
    void* user_data
);

/* ===============================
 * 3. Async API
 * =============================== */

typedef struct MsTask MsTask;

typedef void (*MsTaskCallback)(MsTask* task, MsError code, void* user_data);

MS_API MsTask* ms_video_to_gif_async(
    const char* input_path,
    const char* output_path,
    const MsVideoToGifOptions* options,
    MsTaskCallback callback,
    void* user_data
);

MS_API MsTask* ms_gif_keying_async(
    const char* input_path,
    const char* output_path,
    const MsKeyingOptions* options,
    MsTaskCallback callback,
    void* user_data
);

MS_API float  ms_task_progress(const MsTask* task);
MS_API MsError ms_task_cancel(MsTask* task);
MS_API void   ms_task_free(MsTask* task);

#ifdef __cplusplus
}
#endif

#endif /* MEDIA_STUDIO_H */