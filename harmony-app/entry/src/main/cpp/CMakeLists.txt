cmake_minimum_required(VERSION 3.16)
project(msverify C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------- FFmpeg
# Prebuilt OHOS shared libraries produced by tools/build-ffmpeg-ohos.sh.
# DevEco sets OHOS_ARCH to the ABI being compiled (arm64-v8a / x86_64).
set(FFMPEG_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg)
set(FFMPEG_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})

# config.h and libavutil/avconfig.h are generated per architecture, so the
# ABI overlay directory has to come first on the include path. Without it an
# arm64 build would silently pick up the x86_64 headers.
set(FFMPEG_INC_DIR ${FFMPEG_ROOT}/include)
set(FFMPEG_ABI_INC_DIR ${FFMPEG_INC_DIR}/${OHOS_ARCH})
if(NOT EXISTS "${FFMPEG_ABI_INC_DIR}/config.h")
  message(FATAL_ERROR
    "missing per-ABI FFmpeg headers: ${FFMPEG_ABI_INC_DIR}/config.h\n"
    "Run tools/stage-ffmpeg-ohos.sh before building.")
endif()

add_library(ff_avutil SHARED IMPORTED)
add_library(ff_avcodec SHARED IMPORTED)
add_library(ff_avformat SHARED IMPORTED)
add_library(ff_avfilter SHARED IMPORTED)
add_library(ff_swscale SHARED IMPORTED)
add_library(ff_swresample SHARED IMPORTED)

set_target_properties(ff_avutil PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libavutil.so")
set_target_properties(ff_avcodec PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libavcodec.so")
set_target_properties(ff_avformat PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libavformat.so")
set_target_properties(ff_avfilter PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libavfilter.so")
set_target_properties(ff_swscale PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libswscale.so")
set_target_properties(ff_swresample PROPERTIES IMPORTED_LOCATION "${FFMPEG_LIB_DIR}/libswresample.so")

# ---------------------------------------------------------------- Media Studio engine
# Shared C++ engine from the repository root. The OHOS-specific parts live in
# sdk/src/engine/ and are compiled only here; the Windows build keeps using
# the ffmpeg CLI through sdk/src/ffmpeg/executor.cpp.
set(MS_SDK_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../sdk)

add_library(ms_engine STATIC
  ${MS_SDK_ROOT}/src/engine/ms_inproc_exec.cpp
  ${MS_SDK_ROOT}/src/engine/ms_pipeline.cpp
  ${MS_SDK_ROOT}/src/engine/ms_keying.cpp
  ${MS_SDK_ROOT}/src/engine/ms_crop.cpp
  # The keying filter string is produced by the shared, unmodified
  # mask_builder.cpp so both platforms run byte-for-byte the same graph.
  ${MS_SDK_ROOT}/src/gif_keying/mask_builder.cpp
)
target_include_directories(ms_engine PUBLIC
  ${MS_SDK_ROOT}/src/engine
  ${MS_SDK_ROOT}/include
  ${FFMPEG_ABI_INC_DIR}
  ${FFMPEG_INC_DIR}
)
target_link_libraries(ms_engine
  ff_avutil
  ff_avcodec
  ff_avformat
  ff_avfilter
  ff_swscale
  ff_swresample
)
set_target_properties(ms_engine PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------- NAPI module
add_library(msverify SHARED napi_init.cpp ffmpeg_probe.cpp pipeline_probe.cpp media_api.cpp)

target_include_directories(msverify PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${FFMPEG_ABI_INC_DIR}
  ${FFMPEG_INC_DIR}
)

target_link_libraries(msverify
  ms_engine
  libace_napi.z.so
  libhilog_ndk.z.so
  libz.so
  libchild_process.so
)
