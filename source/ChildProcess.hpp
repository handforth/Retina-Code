#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <string_view>
#include <sys/types.h>

enum class ChildInput { Closed, Pipe, Terminal };

struct ChildProcess {
    pid_t pid = -1;
    int input = -1;
    int output = -1;
    int errors = -1;
};

struct ChildOptions {
    ChildInput input = ChildInput::Closed;
    char *const *environment = nullptr;
    bool mergeErrors = false;
};

void CloseDescriptor(int &fd);
int OpenTerminal(int (&ends)[2], char *name, bool translateNewlines);
int StartChild(ChildProcess &child, const char *const *argv, const char *directory, ChildOptions options);
void CloseChildStreams(ChildProcess &child);
int ChildExitCode(int status);

struct ProgramInput {
    std::mutex mutex;
    std::string queued;
    bool open = false;
};

void SetProgramInput(ProgramInput &input, bool enabled);
bool QueueProgramInput(ProgramInput &input, std::string_view bytes);

enum class ChildEvent { Started, Output, ErrorOutput, Idle, Update };
using ChildRead = void (*)(void *, ChildEvent, std::string_view);

struct ChildResult {
    int code = -1;
    int startError = 0;
    int ioError = 0;
};

ChildResult RunChild(const char *const *argv, const char *directory, const std::atomic_bool &stop, ProgramInput *input, ChildRead read, void *context);

inline constexpr std::string_view systemToolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";

std::string_view NextPathFolder(std::string_view &path);
bool PathHasFolder(std::string_view path, std::string_view folder);
bool IsExecutable(const char *path);
bool ExecutableIn(std::string &path, std::string_view directory, std::string_view name);
bool ExecutableOnPath(std::string &path, std::string_view search, std::string_view name);
bool FindParentFile(std::string &path, std::string_view directory, std::string_view limit, std::string_view name);