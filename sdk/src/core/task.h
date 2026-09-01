// core/task.h - Async task implementation
#pragma once

#include "media_studio.h"

#include <atomic>
#include <thread>
#include <mutex>

struct MsTask {
    std::thread worker;
    std::atomic<float> progress{0.0f};
    std::atomic<MsError> result_code{MS_OK};
    std::atomic<bool> cancelled{false};
    MsTaskCallback callback = nullptr;
    void* user_data = nullptr;
};

namespace ms {

MsTask* spawn_task(
    std::function<MsError(MsProgressCallback, void*)> work,
    MsTaskCallback cb,
    void* user_data
);

}  // namespace ms