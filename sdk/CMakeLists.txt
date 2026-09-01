cmake_minimum_required(VERSION 3.16)
project(media_studio
    VERSION 0.1.0
    DESCRIPTION "Video/GIF to transparent GIF - native SDK"
    LANGUAGES CXX C
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 11)

# 位置无关代码(必要于 so/dylib)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# 导出符号控制
if(NOT WIN32)
    set(CMAKE_CXX_VISIBILITY_PRESET hidden)
    set(CMAKE_C_VISIBILITY_PRESET hidden)
    set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
endif()

# 头文件目录
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

# 主库源文件
set(SDK_SOURCES
    src/core/error.cpp
    src/core/progress.cpp
    src/core/memory.cpp
    src/core/task.cpp
    src/ffmpeg/executor.cpp
    src/ffmpeg/probe.cpp
    src/video_to_gif/video_to_gif.cpp
    src/gif_keying/gif_keying.cpp
    src/gif_keying/mask_builder.cpp
)

add_library(media_studio SHARED ${SDK_SOURCES})
set_target_properties(media_studio PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
    PUBLIC_HEADER include/media_studio.h
)

# 标记我们正在构建 SDK(用于 MS_API 切换 dllexport/dllimport)
target_compile_definitions(media_studio PRIVATE MS_BUILDING)

# 平台相关属性
if(WIN32)
    set_target_properties(media_studio PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    target_compile_definitions(media_studio PRIVATE MS_PLATFORM_WINDOWS)
elseif(APPLE)
    set_target_properties(media_studio PROPERTIES
        MACOSX_RPATH TRUE
        MACOSX_CURRENT_VERSION ${PROJECT_VERSION}
        MACOSX_BUNDLE TRUE
    )
    target_compile_definitions(media_studio PRIVATE MS_PLATFORM_MACOS)
elseif(UNIX)
    target_compile_definitions(media_studio PRIVATE MS_PLATFORM_LINUX)
endif()

# Threads
find_package(Threads REQUIRED)
target_link_libraries(media_studio PRIVATE Threads::Threads)

# 静态链接 C++ runtime,避免依赖 libc++.dll / libunwind.dll
if(MSVC)
    # MSVC 默认静态 CRT
    target_link_options(media_studio PRIVATE /MT$<$<CONFIG:Release>:>)
elseif(APPLE)
    target_link_libraries(media_studio PRIVATE "-Wl,-undefined,dynamic_lookup")
else()
    # Unix / MinGW
    target_link_options(media_studio PRIVATE
        -static-libstdc++
        -static
    )
endif()

# ffmpeg 路径配置
if(NOT DEFINED FFMPEG_EXECUTABLE)
    set(FFMPEG_EXECUTABLE "ffmpeg")
endif()
if(NOT DEFINED FFPROBE_EXECUTABLE)
    set(FFPROBE_EXECUTABLE "ffprobe")
endif()
target_compile_definitions(media_studio PRIVATE
    MS_FFMPEG_EXECUTABLE="${FFMPEG_EXECUTABLE}"
    MS_FFPROBE_EXECUTABLE="${FFPROBE_EXECUTABLE}"
)

# 安装
include(GNUInstallDirs)
install(TARGETS media_studio
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# 可选:examples
option(MS_BUILD_EXAMPLES "Build CLI demo" ON)
if(MS_BUILD_EXAMPLES)
    add_executable(ms_demo examples/cli_demo.cpp)
    target_link_libraries(ms_demo PRIVATE media_studio)
    if(NOT MSVC AND NOT APPLE)
        # Static link to remove libc++ / libunwind dependency
        target_link_options(ms_demo PRIVATE
            -static-libstdc++
            -static
        )
    endif()
endif()