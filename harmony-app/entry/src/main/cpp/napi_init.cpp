/*
 * Verification harness native module.
 *
 * Probes the four platform assumptions that matter for porting Media Studio
 * to HarmonyOS PC:
 *   1. NAPI <-> ArkTS bridge works on a 2in1 device (ping).
 *   2. The native zlib in the OHOS sysroot produces zlib (RFC1950) streams,
 *      which is what PNG IDAT requires (zlibDeflate / zlibProbe).
 *   3. OH_Ability_StartNativeChildProcess is usable by a third-party app on
 *      2in1 (childProcessProbe + the exported ChildMain entry).
 *   4. The musl-based OHOS runtime reports sane system info (sysInfo).
 */

#include "verify_common.h"
#include "AbilityKit/native_child_process.h"

#include <zlib.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/utsname.h>

// ---------------------------------------------------------------- helpers

static bool GetBufferArg(napi_env env, napi_value value, void **data, size_t *len)
{
    bool isBuffer = false;
    if (napi_is_buffer(env, value, &isBuffer) != napi_ok || !isBuffer) {
        return false;
    }
    return napi_get_buffer_info(env, value, data, len) == napi_ok;
}

static std::string HexPrefix(const unsigned char *p, size_t n)
{
    static const char *digits = "0123456789ABCDEF";
    std::string out;
    for (size_t i = 0; i < n; i++) {
        if (i) out += ' ';
        out += digits[(p[i] >> 4) & 0xF];
        out += digits[p[i] & 0xF];
    }
    return out;
}

// ---------------------------------------------------------------- 1. ping

static napi_value Ping(napi_env env, napi_callback_info info)
{
    LOGI("ping called");
    return MakeString(env, "pong-from-native");
}

// ---------------------------------------------------------------- 2. zlib

/**
 * Compress a buffer into a zlib (RFC1950) stream.
 *
 * This is the exact primitive PNG IDAT needs. The browser build used
 * CompressionStream('deflate'), which is also zlib format, so the ArkTS
 * port can keep pngrgb.ts byte-for-byte identical apart from this call.
 */
static napi_value ZlibDeflate(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    void *src = nullptr;
    size_t srcLen = 0;
    if (argc < 1 || !GetBufferArg(env, argv[0], &src, &srcLen)) {
        napi_throw_type_error(env, nullptr, "expected an ArrayBuffer argument");
        return nullptr;
    }

    uLongf destLen = compressBound(static_cast<uLong>(srcLen));
    unsigned char *dest = static_cast<unsigned char *>(malloc(destLen));
    if (dest == nullptr) {
        napi_throw_error(env, nullptr, "out of memory");
        return nullptr;
    }

    int rc = compress2(dest, &destLen, static_cast<const Bytef *>(src),
                       static_cast<uLong>(srcLen), Z_BEST_COMPRESSION);
    if (rc != Z_OK) {
        free(dest);
        napi_throw_error(env, nullptr, "compress2 failed");
        return nullptr;
    }

    napi_value out = nullptr;
    void *outData = nullptr;
    napi_create_arraybuffer(env, destLen, &outData, &out);
    memcpy(outData, dest, destLen);
    free(dest);
    return out;
}

/**
 * Report the format details of the native zlib output so the ArkTS side can
 * assert the PNG precondition (0x78 0x9C header + adler32 trailer).
 */
static napi_value ZlibProbe(napi_env env, napi_callback_info info)
{
    const char *src = "media-studio-harmonyos-port-verification";
    uLong srcLen = static_cast<uLong>(strlen(src));
    uLongf destLen = compressBound(srcLen);
    unsigned char *dest = static_cast<unsigned char *>(malloc(destLen));
    if (dest == nullptr) {
        return MakeString(env, "zlib_probe: malloc failed");
    }
    int rc = compress2(dest, &destLen, reinterpret_cast<const Bytef *>(src), srcLen, 6);
    std::string out = "rc=" + std::to_string(rc) + " len=" + std::to_string(destLen) +
                      " head=[" + HexPrefix(dest, destLen < 4 ? destLen : 4) + "]" +
                      " zlibVer=" + std::to_string(zlibVersion()[0]) + "." +
                      std::to_string(zlibVersion()[1]);
    free(dest);
    LOGI("zlibProbe %s", out.c_str());
    return MakeString(env, out);
}

// ---------------------------------------------------------------- 3. child process

static void OnChildStarted(int errCode, OHIPCRemoteProxy *remoteProxy)
{
    LOGI("child process started: errCode=%d proxy=%p", errCode, (void *)remoteProxy);
}

/**
 * Entry point executed inside the child process. The child loads this very
 * .so and calls the exported symbol named in the "lib:entry" string.
 */
extern "C" void ChildMain(NativeChildProcess_Args args)
{
    LOGI("ChildMain entered, entryParams=%s", args.entryParams ? args.entryParams : "(null)");
    const char *path = args.entryParams;
    if (path != nullptr && path[0] != '\0') {
        FILE *f = fopen(path, "w");
        if (f != nullptr) {
            fputs("child-process-ran", f);
            fclose(f);
            LOGI("ChildMain wrote marker file %s", path);
        } else {
            LOGE("ChildMain could not open %s", path);
        }
    }
}

static napi_value ChildProcessProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string marker;
    if (argc >= 1) {
        size_t need = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &need);
        std::string buf(need + 1, '\0');
        size_t written = 0;
        napi_get_value_string_utf8(env, argv[0], &buf[0], need + 1, &written);
        buf.resize(written);
        marker = buf;
    }

    NativeChildProcess_Args args;
    memset(&args, 0, sizeof(args));
    args.entryParams = const_cast<char *>(marker.c_str());

    NativeChildProcess_Options options;
    options.isolationMode = NCP_ISOLATION_MODE_NORMAL;
    options.reserved = 0;

    int32_t pid = -1;
    int rc = OH_Ability_StartNativeChildProcess("libmsverify.so:ChildMain", args, options, &pid);
    std::string out = "rc=" + std::to_string(rc) + " pid=" + std::to_string(pid);
    LOGI("childProcessProbe %s", out.c_str());
    return MakeString(env, out);
}

// ---------------------------------------------------------------- 4. sysinfo

static napi_value SysInfo(napi_env env, napi_callback_info info)
{
    struct utsname u;
    std::string sys = "unknown";
    if (uname(&u) == 0) {
        sys = std::string(u.sysname) + " " + u.release + " " + u.machine;
    }
    std::string out = sys + " pageSize=" + std::to_string(getpagesize());
    LOGI("sysInfo %s", out.c_str());
    return MakeString(env, out);
}

// ---------------------------------------------------------------- registration

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"ping", nullptr, Ping, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zlibDeflate", nullptr, ZlibDeflate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zlibProbe", nullptr, ZlibProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"childProcessProbe", nullptr, ChildProcessProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sysInfo", nullptr, SysInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"avfilterProbe", nullptr, AvfilterProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gifEncodeProbe", nullptr, GifEncodeProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"videoToGif", nullptr, VideoToGifProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"gifKeying", nullptr, GifKeyingProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "msverify",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMsVerifyModule(void)
{
    napi_module_register(&g_module);
}
