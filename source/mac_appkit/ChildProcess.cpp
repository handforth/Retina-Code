#include "ChildProcess.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <crt_externs.h>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <vector>

using ProcessClock = std::chrono::steady_clock;
using namespace std::chrono_literals;

void CloseDescriptor(int &fd)
{
    if (fd < 0)
        return;

    close(fd);
    fd = -1;
}

static int PrepareDescriptors(int (&ends)[2])
{
    for (int &fd : ends) {
        if (fd <= STDERR_FILENO) {
            int spare = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
            if (spare < 0)
                return errno;

            close(fd);
            fd = spare;
        } else if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
            return errno;
        }
    }

    return 0;
}

int OpenTerminal(int (&ends)[2], char *name, bool translateNewlines)
{
    winsize size{24, 80, 0, 0};
    if (openpty(&ends[0], &ends[1], name, nullptr, &size) != 0)
        return errno;

    int error = PrepareDescriptors(ends);
    termios mode;
    if (!error && tcgetattr(ends[1], &mode) != 0)
        error = errno;

    if (!error) {
        // The Output pane already echoes typed input.
        mode.c_lflag &= ~(ECHO | ECHONL);
        if (!translateNewlines)
            mode.c_oflag &= ~ONLCR;

        if (tcsetattr(ends[1], TCSANOW, &mode) != 0 || fcntl(ends[0], F_SETFL, O_NONBLOCK) < 0)
            error = errno;
    }

    if (error) {
        CloseDescriptor(ends[0]);
        CloseDescriptor(ends[1]);
    }

    return error;
}

static int OpenProcessPipe(int (&ends)[2])
{
    if (pipe(ends) != 0)
        return errno;

    return PrepareDescriptors(ends);
}

static int SpawnChild(pid_t &pid, const char *const *argv, const char *directory, int input, int output, int errors,
                      char *const *environment)
{
    posix_spawn_file_actions_t actions = nullptr;
    posix_spawnattr_t attributes = nullptr;
    int error = posix_spawn_file_actions_init(&actions);
    if (!error)
        error = posix_spawnattr_init(&attributes);

    if (!error && directory && *directory) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        error = posix_spawn_file_actions_addchdir_np(&actions, directory);
#pragma clang diagnostic pop
    }

    if (!error) {
        error = input < 0 ? posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) :
                            posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO);
    }

    if (!error)
        error = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
    if (!error)
        error = posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO);
    if (!error)
        error = posix_spawnattr_setpgroup(&attributes, 0);

    if (!error) {
        // Tools must be able to receive SIGCHLD and reap their children.
        sigset_t mask;
        sigemptyset(&mask);
        error = posix_spawnattr_setsigmask(&attributes, &mask);
    }

    if (!error)
        error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!error)
        error = posix_spawn(&pid, argv[0], &actions, &attributes, const_cast<char *const *>(argv),
                            environment ? environment : *_NSGetEnviron());

    if (attributes)
        posix_spawnattr_destroy(&attributes);
    if (actions)
        posix_spawn_file_actions_destroy(&actions);

    return error;
}

int StartChild(ChildProcess &child, const char *const *argv, const char *directory, ChildOptions options)
{
    ChildInput mode = options.input;
    int input[2]{-1, -1}, output[2]{-1, -1}, errors[2]{-1, -1};
    int error = mode == ChildInput::Terminal ? OpenTerminal(output, nullptr, true) : OpenProcessPipe(output);
    if (!error && !options.mergeErrors)
        error = OpenProcessPipe(errors);
    if (!error && mode == ChildInput::Pipe)
        error = OpenProcessPipe(input);

    int write_end = mode == ChildInput::Terminal ? output[0] : input[1];
    for (int fd : {output[0], errors[0], write_end}) {
        if (!error && fd >= 0 && fcntl(fd, F_SETFL, O_NONBLOCK) < 0)
            error = errno;
    }

    if (!error && mode == ChildInput::Pipe && fcntl(write_end, F_SETNOSIGPIPE, 1) < 0)
        error = errno;

    if (!error)
        error = SpawnChild(child.pid, argv, directory, mode == ChildInput::Terminal ? output[1] : input[0],
                           output[1], options.mergeErrors ? output[1] : errors[1], options.environment);

    CloseDescriptor(input[0]);
    CloseDescriptor(output[1]);
    CloseDescriptor(errors[1]);
    if (error) {
        CloseDescriptor(input[1]);
        CloseDescriptor(output[0]);
        CloseDescriptor(errors[0]);
        return error;
    }

    child.input = write_end;
    child.output = output[0];
    child.errors = errors[0];
    return 0;
}

void CloseChildStreams(ChildProcess &child)
{
    if (child.input == child.output)
        child.input = -1;

    CloseDescriptor(child.input);
    CloseDescriptor(child.output);
    CloseDescriptor(child.errors);
}

int ChildExitCode(int status)
{
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
}

void SetProgramInput(ProgramInput &input, bool enabled)
{
    std::lock_guard lock(input.mutex);
    input.open = enabled;
    if (!enabled)
        input.queued.clear();
}

bool QueueProgramInput(ProgramInput &input, std::string_view bytes)
{
    std::lock_guard lock(input.mutex);
    if (!input.open || bytes.empty() || bytes.size() > 65536 - input.queued.size())
        return false;

    input.queued += bytes;
    return true;
}

ChildResult RunChild(const char *const *argv, const char *directory, const std::atomic_bool &stop, ProgramInput *input, ChildRead read_output, void *context)
{
    if (stop.load(std::memory_order_relaxed))
        return {};

    ChildProcess child;
    int error = StartChild(child, argv, directory, {input ? ChildInput::Terminal : ChildInput::Closed});
    if (error)
        return {.startError = error};

    read_output(context, ChildEvent::Started, {});
    pollfd watches[]{{child.output, POLLIN, 0}, {child.errors, POLLIN, 0}};
    std::string outgoing;
    size_t written = 0;
    int status = 0;
    const auto never = ProcessClock::time_point::max();
    auto exited = never, force_stop = never;
    bool stopping = false;
    char bytes[16 * 1024];

    for (;;) {
        auto now = ProcessClock::now();
        if (!stopping && stop.load(std::memory_order_relaxed)) {
            stopping = true;
            kill(-child.pid, SIGTERM);
            force_stop = now + 300ms;
        }

        if (now >= force_stop) {
            kill(-child.pid, SIGKILL);
            force_stop = never;
        }

        bool reaped = exited != never;
        if (input && !stopping && !reaped && outgoing.empty()) {
            std::lock_guard lock(input->mutex);
            outgoing.swap(input->queued);
        }

        watches[0].events = POLLIN | (!stopping && !reaped && !outgoing.empty() ? POLLOUT : 0);
        int count = poll(watches, 2, reaped ? 0 : 40);
        if (count < 0 && errno != EINTR) {
            error = errno;
            if (!reaped) {
                kill(-child.pid, SIGKILL);
                while (waitpid(child.pid, &status, 0) < 0 && errno == EINTR) {}
            }
            break;
        }

        if (reaped && (count == 0 || now - exited > 150ms))
            break;

        if (count > 0 && (watches[0].revents & POLLOUT)) {
            ssize_t size = write(watches[0].fd, outgoing.data() + written, outgoing.size() - written);
            if (size > 0) {
                written += size_t(size);
                if (written == outgoing.size()) {
                    written = 0;
                    outgoing.clear();
                }
            } else if (size < 0 && errno != EAGAIN && errno != EINTR) {
                written = 0;
                outgoing.clear();
                SetProgramInput(*input, false);
            }
        }

        for (size_t i = 0; count > 0 && i < 2; ++i) {
            if (!(watches[i].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)))
                continue;

            ssize_t size = read(watches[i].fd, bytes, sizeof(bytes));
            if (size > 0)
                read_output(context, i == 0 ? ChildEvent::Output : ChildEvent::ErrorOutput, {bytes, size_t(size)});
            else if (!size || (errno != EINTR && errno != EAGAIN))
                watches[i].fd = -1;
        }

        read_output(context, count == 0 ? ChildEvent::Idle : ChildEvent::Update, {});
        if (!reaped) {
            pid_t result = waitpid(child.pid, &status, WNOHANG);
            if (result == child.pid)
                exited = ProcessClock::now();
            else if (result < 0 && errno != EINTR) {
                error = errno;
                break;
            }
        }
    }

    if (input)
        SetProgramInput(*input, false);
    if (stopping)
        kill(-child.pid, SIGKILL);

    CloseChildStreams(child);
    if (error)
        return {.ioError = error};

    return {.code = ChildExitCode(status)};
}

static void JoinPath(std::string &path, std::string_view directory, std::string_view name)
{
    path = directory;
    if (!path.ends_with('/'))
        path += '/';

    path += name;
}

bool IsExecutable(const char *path)
{
    struct stat info;
    return *path && stat(path, &info) == 0 && !S_ISDIR(info.st_mode) && access(path, X_OK) == 0;
}

bool ExecutableIn(std::string &path, std::string_view directory, std::string_view name)
{
    if (!directory.starts_with('/'))
        return false;

    JoinPath(path, directory, name);
    return IsExecutable(path.c_str());
}

std::string_view NextPathFolder(std::string_view &path)
{
    size_t end = path.find(':');
    auto folder = path.substr(0, end);
    path.remove_prefix(end == path.npos ? path.size() : end + 1);
    return folder;
}

bool PathHasFolder(std::string_view path, std::string_view folder)
{
    while (!path.empty()) {
        if (NextPathFolder(path) == folder)
            return true;
    }

    return false;
}

bool ExecutableOnPath(std::string &path, std::string_view search, std::string_view name)
{
    std::string_view stack[32];
    std::vector<std::string_view> overflow;
    size_t count = 0;
    for (auto bins : {search, systemToolPath}) {
        while (!bins.empty()) {
            auto folder = NextPathFolder(bins);
            const auto *seen = overflow.empty() ? stack : overflow.data();
            if (!folder.starts_with('/') || std::find(seen, seen + count, folder) != seen + count)
                continue;

            if (ExecutableIn(path, folder, name))
                return true;

            if (count < std::size(stack)) {
                stack[count] = folder;
            } else {
                if (overflow.empty()) {
                    overflow.reserve(std::size(stack) * 2);
                    overflow.assign(stack, stack + count);
                }
                overflow.push_back(folder);
            }
            ++count;
        }
    }

    return false;
}
