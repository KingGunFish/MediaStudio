// core/task.cpp
#include "task.h"

#include <functional>

namespace {

// Trampoline that adapts a C function pointer signature to a static helper.
struct ProgressAdapter {
    static bool call(float p, const char* msg, void* ud) {
        auto* self = reinterpret_cast<ProgressAdapter*>(ud);
        if (self->cancelled->load()) return false;
        self->task->progress.store(p);
        return true;
    }
    std::atomic<bool>* cancelled;
    MsTask* task;
};

}  // namespace

namespace ms {

MsTask* spawn_task(
    std::function<MsError(MsProgressCallback, void*)> work,
    MsTaskCallback cb,
    void* user_data
) {
    MsTask* task = new MsTask();
    task->callback = cb;
    task->user_data = user_data;

    ProgressAdapter adapter{&task->cancelled, task};

    task->worker = std::thread([task, work = std::move(work), adapter]() mutable {
        MsError code = work(&ProgressAdapter::call, &adapter);
        task->result_code.store(code);
        if (task->callback) {
            task->callback(task, code, task->user_data);
        }
    });
    return task;
}

}  // namespace ms


// === Public C API ===

extern "C" MS_API float ms_task_progress(const MsTask* task) {
    if (!task) return -1.0f;
    return task->progress.load();
}

extern "C" MS_API MsError ms_task_cancel(MsTask* task) {
    if (!task) return MS_ERR_INVALID_ARG;
    task->cancelled.store(true);
    return MS_OK;
}

extern "C" MS_API void ms_task_free(MsTask* task) {
    if (!task) return;
    if (task->worker.joinable()) {
        task->worker.join();
    }
    delete task;
}

extern "C" MS_API MsTask* ms_video_to_gif_async(
    const char* input_path,
    const char* output_path,
    const MsVideoToGifOptions* options,
    MsTaskCallback callback,
    void* user_data
) {
    MsVideoToGifOptions opts_copy;
    if (options) opts_copy = *options;
    else ms_video_to_gif_options_init(&opts_copy);

    return ms::spawn_task(
        [input_path, output_path, opts_copy](MsProgressCallback cb, void* ud) -> MsError {
            MsVideoToGifResult result;
            return ms_video_to_gif(input_path, output_path, &opts_copy, &result,
                                  reinterpret_cast<MsProgressCallback>(cb), ud);
        },
        callback, user_data);
}

extern "C" MS_API MsTask* ms_gif_keying_async(
    const char* input_path,
    const char* output_path,
    const MsKeyingOptions* options,
    MsTaskCallback callback,
    void* user_data
) {
    MsKeyingOptions opts_copy;
    if (options) opts_copy = *options;
    else ms_keying_options_init(&opts_copy);

    return ms::spawn_task(
        [input_path, output_path, opts_copy](MsProgressCallback cb, void* ud) -> MsError {
            MsKeyingResult result;
            return ms_gif_keying(input_path, output_path, &opts_copy, &result,
                                reinterpret_cast<MsProgressCallback>(cb), ud);
        },
        callback, user_data);
}