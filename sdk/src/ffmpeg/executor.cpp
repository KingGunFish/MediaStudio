// ffmpeg/executor.cpp
#include "executor.h"

#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <atomic>
#include <chrono>

#ifdef _WIN32
    #include <windows.h>
    #include <io.h>
    #include <fcntl.h>
    #define POPEN _popen
    #define PCLOSE _pclose
    #define FILENO _fileno
#else
    #include <unistd.h>
    #include <signal.h>
    #include <sys/wait.h>
    #define POPEN popen
    #define PCLOSE pclose
    #define FILENO fileno
#endif

#ifndef MS_FFMPEG_EXECUTABLE
    #define MS_FFMPEG_EXECUTABLE "ffmpeg"
#endif
#ifndef MS_FFPROBE_EXECUTABLE
    #define MS_FFPROBE_EXECUTABLE "ffprobe"
#endif

namespace ms {

namespace {

std::string join_args(const std::vector<std::string>& args) {
    // For Windows, use double-quote with backslash escaping.
    std::string out;
    for (size_t i = 0; i < args.size(); ++i) {
        if (i > 0) out += ' ';
        bool need_quote = args[i].empty() ||
                          args[i].find_first_of(" \t\n\"&|<>") != std::string::npos ||
                          args[i].find("'") != std::string::npos;
        if (need_quote) {
            out += '"';
            for (char c : args[i]) {
                if (c == '"') out += "\\\"";
                else if (c == '\\') out += "\\\\";
                else out += c;
            }
            out += '"';
        } else {
            out += args[i];
        }
    }
    return out;
}

#ifdef _WIN32
// Build a UTF-16 wide command line and launch via CreateProcessW.
// This properly supports Unicode (e.g. Chinese) paths in arguments.
struct WinChild {
    HANDLE hProcess = nullptr;
    HANDLE hStdOutRd = nullptr;
    HANDLE hStdOutWr = nullptr;
    HANDLE hStdErrRd = nullptr;
    HANDLE hStdErrWr = nullptr;
    PROCESS_INFORMATION pi{};
};

bool launch_process_w(const std::string& cmd, WinChild& child) {
    // Convert command line to UTF-16 using the system ANSI code page.
    // PowerShell passes command-line arguments in CP_ACP (e.g. CP936 for Chinese),
    // so we use CP_ACP here to keep non-ASCII paths readable to the child process.
    int wlen = MultiByteToWideChar(CP_ACP, 0, cmd.c_str(), -1, nullptr, 0);
    if (wlen <= 0) return false;
    std::wstring wcmd(wlen, L'\0');
    MultiByteToWideChar(CP_ACP, 0, cmd.c_str(), -1, &wcmd[0], wlen);

    // Create pipes for stdout and stderr.
    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    if (!CreatePipe(&child.hStdOutRd, &child.hStdOutWr, &sa, 0)) return false;
    if (!CreatePipe(&child.hStdErrRd, &child.hStdErrWr, &sa, 0)) return false;

    // Don't inherit write ends.
    SetHandleInformation(child.hStdOutRd, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(child.hStdErrRd, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.hStdOutput = child.hStdOutWr;
    si.hStdError = child.hStdErrWr;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.dwFlags |= STARTF_USESTDHANDLES;

    // Build mutable wide-string for CreateProcessW.
    std::wstring wcmd_mut = wcmd;
    BOOL ok = CreateProcessW(
        nullptr,
        &wcmd_mut[0],
        nullptr, nullptr,
        TRUE,
        CREATE_NO_WINDOW,
        nullptr, nullptr,
        &si, &child.pi);
    if (!ok) {
        CloseHandle(child.hStdOutRd); CloseHandle(child.hStdOutWr);
        CloseHandle(child.hStdErrRd); CloseHandle(child.hStdErrWr);
        return false;
    }
    child.hProcess = child.pi.hProcess;
    CloseHandle(child.pi.hThread);
    // Close write ends in our process; child still has them.
    CloseHandle(child.hStdOutWr);
    CloseHandle(child.hStdErrWr);
    child.hStdOutWr = nullptr;
    child.hStdErrWr = nullptr;
    return true;
}

std::string read_pipe_to_string(HANDLE hPipe) {
    std::string out;
    char buf[4096];
    DWORD n = 0;
    while (ReadFile(hPipe, buf, sizeof(buf), &n, nullptr) && n > 0) {
        out.append(buf, buf + n);
        n = 0;
    }
    return out;
}
#endif

bool parse_time_to_seconds(const std::string& time_str, double& out_seconds) {
    int h = 0, m = 0;
    double s = 0.0;
    int consumed = 0;
    if (sscanf(time_str.c_str(), "%d:%d:%lf%n", &h, &m, &s, &consumed) >= 3) {
        out_seconds = h * 3600.0 + m * 60.0 + s;
        return true;
    }
    if (sscanf(time_str.c_str(), "%lf%n", &s, &consumed) >= 1) {
        out_seconds = s;
        return true;
    }
    return false;
}

void emit_progress_from_line(const std::string& line,
                               ProgressFn& cb,
                               double total_duration) {
    // ffmpeg rewrites its progress line in place using '\r', so a single
    // buffered "line" may contain several "time=" updates. Use the LAST one
    // (rfind) to report the most recent progress.
    auto pos = line.rfind("time=");
    if (pos == std::string::npos) return;
    pos += 5;
    auto end = line.find_first_of(" \t\r\n", pos);
    if (end == std::string::npos) end = line.size();
    std::string ts = line.substr(pos, end - pos);

    double cur = 0.0;
    if (!parse_time_to_seconds(ts, cur)) return;

    if (total_duration > 0.0) {
        float p = static_cast<float>(cur / total_duration);
        if (p < 0) p = 0;
        if (p > 1) p = 1;
        if (cb) cb(p, "encoding");
    } else {
        if (cb) cb(-1.0f, "encoding");
    }
}

// Resolve the directory that contains the current executable. Used to locate a
// bundled ffmpeg/ffprobe shipped next to ms_demo (so the app works out of the
// box without requiring ffmpeg on the system PATH).
std::string exe_dir() {
#ifdef _WIN32
    char buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameA(nullptr, buf, MAX_PATH);
    if (n == 0) return "";
    std::string s(buf, n);
    auto pos = s.find_last_of('\\');
    return pos == std::string::npos ? "" : s.substr(0, pos);
#else
    char buf[4096] = {0};
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0) return "";
    std::string s(buf, n);
    auto pos = s.find_last_of('/');
    return pos == std::string::npos ? "" : s.substr(0, pos);
#endif
}

// Prefer a copy of `name` bundled next to this executable; fall back to the
// compile-time default (usually "ffmpeg"/"ffprobe", i.e. a PATH lookup).
// An explicit FFMPEG / FFPROBE environment variable always wins (source builds).
std::string resolve_executable(const std::string& fallback, const std::string& name) {
    const char* env = std::getenv(name == "ffmpeg" ? "FFMPEG" : "FFPROBE");
    if (env && *env) return std::string(env);
    std::string dir = exe_dir();
    if (!dir.empty()) {
#ifdef _WIN32
        std::string candidate = dir + "\\" + name + ".exe";
#else
        std::string candidate = dir + "/" + name;
#endif
        FILE* f = std::fopen(candidate.c_str(), "rb");
        if (f) { std::fclose(f); return candidate; }
    }
    return fallback;
}

}  // namespace

#ifdef _WIN32
FFmpegResult run_with_createprocess(
    const std::string& executable,
    const std::vector<std::string>& args,
    ProgressFn on_progress,
    double total_duration_seconds
) {
    FFmpegResult result;
    std::vector<std::string> full_args;
    full_args.push_back(executable);
    full_args.insert(full_args.end(), args.begin(), args.end());
    std::string cmd = join_args(full_args);

    WinChild child;
    if (!launch_process_w(cmd, child)) {
        result.exit_code = -1;
        result.stderr_output = "CreateProcessW failed";
        return result;
    }

    // Read both pipes concurrently in two threads.
    HANDLE pipe_handles[2] = { child.hStdOutRd, child.hStdErrRd };
    std::string* strs[2] = { &result.stdout_output, &result.stderr_output };
    std::mutex mu[2];

    auto reader = [&](int idx) {
        char buf[4096];
        DWORD n = 0;
        while (ReadFile(pipe_handles[idx], buf, sizeof(buf), &n, nullptr) && n > 0) {
            {
                std::lock_guard<std::mutex> lock(mu[idx]);
                strs[idx]->append(buf, buf + n);
            }
            // Windows path: emit progress in real-time as ffmpeg writes
            // "time=..." lines to stderr (mirrors the POSIX branch). Without
            // this the progress callback only fired once after the process
            // exited, so the UI stayed at 0% for the whole conversion.
            // ffmpeg rewrites its progress with '\r', so normalize '\r' to
            // '\n' first so each update is treated as its own line.
            if (idx == 1 && on_progress && total_duration_seconds > 0.0) {
                std::string chunk(buf, n);
                for (char& c : chunk) if (c == '\r') c = '\n';
                size_t pos = 0;
                while (true) {
                    size_t nl = chunk.find('\n', pos);
                    std::string line = (nl == std::string::npos)
                        ? chunk.substr(pos)
                        : chunk.substr(pos, nl - pos);
                    emit_progress_from_line(line, on_progress, total_duration_seconds);
                    if (nl == std::string::npos) break;
                    pos = nl + 1;
                }
            }
        }
    };

    std::thread t_out(reader, 0);
    std::thread t_err(reader, 1);

    // Watch stderr for progress in real-time (without consuming the buffer).
    // We just read in a separate loop using a peek; here we just join both threads.
    // For progress, callers can poll result.stderr_output after completion.
    // (Simple approach: parse progress from the read result after wait.)
    t_out.join();
    t_err.join();

    CloseHandle(child.hStdOutRd);
    CloseHandle(child.hStdErrRd);

    // Wait for process.
    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD exit_code = 0;
    GetExitCodeProcess(child.hProcess, &exit_code);
    CloseHandle(child.hProcess);
    result.exit_code = static_cast<int>(exit_code);

    // Parse progress from final stderr (best-effort, after completion).
    if (on_progress && total_duration_seconds > 0) {
        // Use last "time=" occurrence as final progress indicator
        std::string& s = result.stderr_output;
        size_t pos = 0;
        double last_time = 0;
        while ((pos = s.find("time=", pos)) != std::string::npos) {
            pos += 5;
            size_t end = s.find_first_of(" \t\n", pos);
            if (end == std::string::npos) end = s.size();
            double cur = 0;
            if (parse_time_to_seconds(s.substr(pos, end - pos), cur) && cur > last_time) {
                last_time = cur;
            }
        }
        if (last_time > 0) {
            float p = static_cast<float>(last_time / total_duration_seconds);
            if (p > 1) p = 1;
            on_progress(p, "done");
        }
    }

    return result;
}
#else
FFmpegResult run_with_createprocess(
    const std::string& executable,
    const std::vector<std::string>& args,
    ProgressFn on_progress,
    double total_duration_seconds
) {
    // POSIX: use popen + 2>&1.
    FFmpegResult result;
    std::vector<std::string> full_args;
    full_args.push_back(executable);
    full_args.insert(full_args.end(), args.begin(), args.end());
    std::string cmd = join_args(full_args);
    cmd += " 2>&1";
    FILE* pipe = POPEN(cmd.c_str(), "r");
    if (!pipe) {
        result.exit_code = -1;
        result.stderr_output = "popen failed";
        return result;
    }
    char buf[4096];
    while (fgets(buf, sizeof(buf), pipe)) {
        std::string line(buf);
        result.stderr_output += line;
        if (on_progress) emit_progress_from_line(line, on_progress, total_duration_seconds);
    }
    int rc = PCLOSE(pipe);
    if (WIFEXITED(rc)) {
        result.exit_code = WEXITSTATUS(rc);
    } else {
        result.exit_code = -1;
    }
    return result;
}
#endif

FFmpegResult run_ffmpeg(
    const std::vector<std::string>& args,
    ProgressFn on_progress,
    double total_duration_seconds
) {
    static const std::string exe = resolve_executable(MS_FFMPEG_EXECUTABLE, "ffmpeg");
    return run_with_createprocess(exe, args, on_progress, total_duration_seconds);
}

FFmpegResult run_ffprobe(
    const std::vector<std::string>& args,
    std::string& output
) {
    static const std::string exe = resolve_executable(MS_FFPROBE_EXECUTABLE, "ffprobe");
    auto r = run_with_createprocess(exe, args, nullptr, -1.0);
    // ffprobe writes metadata to stdout. Use stdout if present, else stderr.
    if (!r.stdout_output.empty()) {
        output = std::move(r.stdout_output);
    } else {
        output = std::move(r.stderr_output);
    }
    return r;
}

}  // namespace ms