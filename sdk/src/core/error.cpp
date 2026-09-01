#include "media_studio.h"

namespace {
struct ErrorEntry {
    MsError code;
    const char* msg;
};

constexpr ErrorEntry kErrorTable[] = {
    {MS_OK, "Success"},
    {MS_ERR_INVALID_ARG, "Invalid argument"},
    {MS_ERR_FILE_NOT_FOUND, "File not found"},
    {MS_ERR_FFMPEG_FAILED, "ffmpeg execution failed"},
    {MS_ERR_INVALID_FORMAT, "Invalid input format"},
    {MS_ERR_OUT_OF_MEMORY, "Out of memory"},
    {MS_ERR_CANCELLED, "Operation cancelled"},
    {MS_ERR_NOT_SUPPORTED, "Operation not supported"},
    {MS_ERR_INTERNAL, "Internal error"},
};
}

extern "C" MS_API const char* ms_error_string(MsError code) {
    for (const auto& e : kErrorTable) {
        if (e.code == code) return e.msg;
    }
    return "Unknown error";
}

extern "C" MS_API void ms_result_init(MsResult* result) {
    if (!result) return;
    result->code = MS_OK;
    result->message[0] = '\0';
    result->duration_ms = 0;
}