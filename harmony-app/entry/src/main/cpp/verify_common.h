/*
 * Shared helpers for the verification native module.
 */

#ifndef MSVERIFY_COMMON_H
#define MSVERIFY_COMMON_H

#include "napi/native_api.h"
#include "hilog/log.h"

#include <string>

#undef LOG_DOMAIN
#define LOG_DOMAIN 0x3200
#undef LOG_TAG
#define LOG_TAG "MsVerify"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

inline napi_value MakeString(napi_env env, const std::string &s)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

/* Implemented in ffmpeg_probe.cpp */
napi_value AvfilterProbe(napi_env env, napi_callback_info info);
napi_value GifEncodeProbe(napi_env env, napi_callback_info info);

/* Implemented in pipeline_probe.cpp */
napi_value VideoToGifProbe(napi_env env, napi_callback_info info);
napi_value GifKeyingProbe(napi_env env, napi_callback_info info);

#endif /* MSVERIFY_COMMON_H */
