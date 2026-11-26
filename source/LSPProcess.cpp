#include "LSPProcess.hpp"
#include "ChildProcess.hpp"
#include "LSPJson.hpp"
#include "ProtocolReader.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <poll.h>
#include <pthread.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>
#include <utility>
#include <vector>
#ifdef __APPLE__
#include <crt_externs.h>
#else
extern char **environ;
#endif

namespace lsp {
using namespace std::chrono_literals;

struct Children {
    std::mutex lock;
    std::vector<pid_t> live;
    bool stopping = false;
};

static Children &ChildProcesses()
{
    // Dispatch may still be draining cancelled sources when the app exits.
    static auto *children = new Children;
    return *children;
}

void StartChildProcesses()
{
    auto &children = ChildProcesses();
    std::lock_guard lock(children.lock);
    children.stopping = false;
}

static void KillGroup(pid_t pid)
{
    if (pid > 0)
        kill(-pid, SIGKILL);
}

void StopChildProcesses()
{
    auto &children = ChildProcesses();
    std::lock_guard lock(children.lock);
    children.stopping = true;
    for (pid_t pid : children.live)
        KillGroup(pid);
}

static pid_t WaitChild(pid_t pid, int *status)
{
    auto &children = ChildProcesses();
    std::lock_guard lock(children.lock);
    pid_t exited = waitpid(pid, status, WNOHANG);
    if (exited > 0 || (exited < 0 && errno == ECHILD))
        std::erase(children.live, pid);
    return exited;
}

void AppendItem(std::string &bytes, std::string_view item)
{
    bytes.append(item);
    bytes += '\0';
}

std::string_view NextItem(std::string_view &bytes)
{
    size_t end = bytes.find('\0');
    auto item = bytes.substr(0, end);
    bytes.remove_prefix(end == bytes.npos ? bytes.size() : end + 1);
    return item;
}

Environment ReadEnvironment()
{
#ifdef __APPLE__
    char **entries = *_NSGetEnviron();
#else
    char **entries = environ;
#endif
    Environment environment;
    for (; entries && *entries; ++entries)
        AppendItem(environment, *entries);
    return environment;
}

static bool EnvironmentEntry(std::string_view entry, std::string_view name)
{
    return entry.size() > name.size() && entry[name.size()] == '=' && entry.starts_with(name);
}

void SetEnvironment(Environment &environment, std::string_view name, std::string_view value)
{
    std::string_view entries = environment;
    while (!entries.empty()) {
        auto entry = NextItem(entries);
        if (EnvironmentEntry(entry, name)) {
            size_t offset = name.size() + 1;
            environment.replace(entry.data() - environment.data() + offset, entry.size() - offset, value);
            return;
        }
    }
    environment += name;
    environment += '=';
    AppendItem(environment, value);
}

void RemoveEnvironment(Environment &environment, std::string_view name)
{
    size_t at = 0;
    while (at < environment.size()) {
        auto entries = std::string_view(environment).substr(at);
        auto entry = NextItem(entries);
        if (EnvironmentEntry(entry, name))
            environment.erase(at, entry.size() + 1);
        else
            at += entry.size() + 1;
    }
}

static int StartTrackedChild(ChildProcess &child, const char *program, std::string_view arguments, const char *directory,
                             std::string_view environment, ChildOptions options)
{
    char *argv_stack[32], *env_stack[128];
    size_t argc = std::ranges::count(arguments, '\0') + 2;
    size_t envc = std::ranges::count(environment, '\0') + 1;
    size_t extra_args = argc > std::size(argv_stack) ? argc : 0;
    size_t extra_env = envc > std::size(env_stack) ? envc : 0;
    std::vector<char *> overflow(extra_args + extra_env);
    char **argv = extra_args ? overflow.data() : argv_stack;
    char **env = extra_env ? overflow.data() + extra_args : env_stack;

    char **slot = argv;
    *slot++ = const_cast<char *>(program);
    while (!arguments.empty())
        *slot++ = const_cast<char *>(NextItem(arguments).data());
    *slot = nullptr;

    slot = env;
    while (!environment.empty())
        *slot++ = const_cast<char *>(NextItem(environment).data());
    *slot = nullptr;
    options.environment = env;

    auto &children = ChildProcesses();
    std::lock_guard lock(children.lock);
    if (children.stopping)
        return ECANCELED;

    int error = StartChild(child, argv, directory, options);
    if (!error)
        children.live.push_back(child.pid);

    return error;
}

static std::string_view Trim(std::string_view text)
{
    size_t first = text.find_first_not_of(" \t\r\n");
    return first == text.npos ? std::string_view{} : text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
}

static void AppendTail(std::string &tail, std::string_view data, size_t limit)
{
    if (data.size() >= limit) {
        tail.assign(data.substr(data.size() - limit));
        return;
    }
    if (tail.size() + data.size() > limit)
        tail.erase(0, tail.size() + data.size() - limit);
    tail.append(data);
}

CommandResult RunCommand(std::string_view program, std::span<const std::string_view> arguments, std::string_view directory,
                         const Environment &environment, std::chrono::seconds timeout, const std::atomic_bool *cancelled,
                         Progress progress)
{
    constexpr std::string_view cancelledText = "Installation cancelled.";
    if (cancelled && cancelled->load())
        return {false, std::string(cancelledText)};
    std::string command;
    AppendItem(command, program);
    AppendItem(command, directory);
    for (auto argument : arguments)
        AppendItem(command, argument);

    std::string_view bytes = command;
    auto executable = NextItem(bytes);
    auto root = NextItem(bytes);
    ChildProcess child;
    int error = StartTrackedChild(child, executable.data(), bytes, root.data(), environment, {.mergeErrors = true});
    if (error)
        return {false, strerror(error)};

    auto deadline = Clock::now() + timeout;
    auto lastProgress = Clock::now();
    std::string tail;
    std::string_view failure;
    int status = 0;
    for (;;) {
        auto now = Clock::now();
        if (failure.empty()) {
            if (cancelled && cancelled->load())
                failure = cancelledText;
            else if (now >= deadline)
                failure = "The command timed out.";
            if (!failure.empty())
                KillGroup(child.pid);
        }
        pid_t exited = WaitChild(child.pid, &status);
        if (exited < 0 && errno == EINTR)
            continue;
        pollfd event{child.output, POLLIN, 0};
        poll(&event, 1, exited == 0 ? 150 : 0);
        if (event.revents) {
            char buffer[4096];
            for (;;) {
                ssize_t count = read(child.output, buffer, sizeof(buffer));
                if (count < 0 && errno == EINTR)
                    continue;
                if (count <= 0) {
                    if (!count)
                        CloseDescriptor(child.output);
                    break;
                }
                std::string_view bytes(buffer, size_t(count));
                AppendTail(tail, bytes, sizeof(buffer));
                if (progress.notify && now - lastProgress >= 350ms) {
                    lastProgress = now;
                    auto line = Trim(tail);
                    size_t start = line.find_last_of("\r\n");
                    if (start != line.npos)
                        line.remove_prefix(start + 1);
                    if (!line.empty())
                        progress.notify(progress.context, line.substr(0, 240));
                }
                if (exited == 0)
                    break;
            }
        }
        if (exited != 0) {
            CloseDescriptor(child.output);
            return failure.empty() ? CommandResult{exited > 0 && ChildExitCode(status) == 0, std::string(Trim(tail))}
                                   : CommandResult{false, std::string(failure)};
        }
    }
}

static constexpr size_t max_message = 16 * 1024 * 1024;
static constexpr size_t max_queued = 2 * max_message;
static constexpr auto never = Clock::time_point::max();

enum class WorkKind { Open, Write, Close, Fail };

struct Work {
    PipeID id;
    WorkKind kind;
    PacketRange data;
    size_t argument_bytes = 0;
};

struct PipeMessage {
    PipeID id;
    PipeEvent kind;
    PacketRange data;
    std::array<PacketRange, size_t(PacketField::Count)> fields;
};

template<class T>
struct Mail {
    std::vector<T> rows;
    std::string bytes;
};

// The worker owns the pipe records. The UI and worker exchange batches of bytes and offsets.
struct Transport {
    std::mutex mutex;
    Mail<Work> outgoing;
    Mail<PipeMessage> incoming, delivery;
    dispatch_source_t inbox = nullptr;
    ReceivePipeEvent receive = nullptr;
    pthread_t thread{};
    int queue = -1;
    PipeID sequence = 0;
    bool stop = false;
};

struct Pipe {
    PipeID id = 0;
    ChildProcess child;
    ProtocolReader reader;
    std::string writes, stderr_tail;
    size_t written = 0;
    Clock::time_point write_due = never;
    Clock::time_point reap_due = never;
    bool closing = false;
};

static Transport transport;

static bool Watch(int queue, uintptr_t key, short filter, unsigned short flags, unsigned mask, PipeID id)
{
    struct kevent change;
    EV_SET(&change, key, filter, flags, mask, 0, reinterpret_cast<void *>(uintptr_t(id)));
    return kevent(queue, &change, 1, nullptr, 0, nullptr) == 0;
}

static void WakeWorker()
{
    Watch(transport.queue, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0);
}

template<class T>
static void ClearMail(Mail<T> &batch)
{
    batch.rows.clear();
    batch.bytes.clear();
    if (batch.rows.capacity() > 1024)
        std::vector<T>().swap(batch.rows);
    if (batch.bytes.capacity() > 128 * 1024)
        std::string().swap(batch.bytes);
}

static void Deliver(void *)
{
    auto &batch = transport.delivery;
    {
        std::lock_guard lock(transport.mutex);
        std::swap(batch, transport.incoming);
    }
    for (const auto &message : batch.rows) {
        if (!transport.inbox)
            break;
        auto bytes = std::string_view(batch.bytes).substr(message.data.offset, message.data.length);
        transport.receive(message.id, message.kind, {bytes, message.fields});
    }
    ClearMail(batch);
}

static bool Post(PipeID id, PipeEvent kind, const Packet &packet)
{
    bool wake;
    {
        std::lock_guard lock(transport.mutex);
        auto &inbox = transport.incoming;
        if (transport.stop)
            return true;
        if (kind == PipeEvent::Message && inbox.bytes.size() + packet.bytes.size() +
            (inbox.rows.size() + 1) * sizeof(PipeMessage) > max_queued)
            return false;
        wake = inbox.rows.empty();
        inbox.rows.push_back({id, kind, {uint32_t(inbox.bytes.size()), uint32_t(packet.bytes.size())}, packet.fields});
        inbox.bytes += packet.bytes;
    }
    if (wake)
        dispatch_source_merge_data(transport.inbox, 1);
    return true;
}

static bool ParsePacket(Json input, Packet &packet)
{
    packet.bytes = input;
    SkipJsonSpace(input);
    if (!TakeJsonChar(input, '{'))
        return false;
    SkipJsonSpace(input);
    if (!TakeJsonChar(input, '}')) {
        for (;;) {
            Json key, value;
            if (!ReadJsonMember(input, key, value))
                return false;

            constexpr Json names[]{"method", "id", "result", "params", "error"};
            for (size_t i = 0; i < std::size(names); ++i) {
                if (JsonNameEquals(key, names[i])) {
                    packet.fields[i] = {uint32_t(value.data() - packet.bytes.data()), uint32_t(value.size())};
                    break;
                }
            }
            SkipJsonSpace(input);
            if (TakeJsonChar(input, '}'))
                break;
            if (!TakeJsonChar(input, ','))
                return false;
        }
    }
    SkipJsonSpace(input);
    return input.empty();
}

static void CloseStreams(Pipe &pipe)
{
    CloseChildStreams(pipe.child);
    pipe.write_due = never;
    pipe.closing = true;
}

static void EndPipe(Pipe &pipe, std::string_view failure = {})
{
    if (pipe.closing)
        return;
    if (!failure.empty())
        Post(pipe.id, PipeEvent::Failed, {failure});
    CloseStreams(pipe);
    KillGroup(pipe.child.pid);
}

static void ReadOutput(Pipe &pipe)
{
    char bytes[16 * 1024];
    for (int i = 0; i < 16 && pipe.child.output >= 0; ++i) {
        ssize_t count = read(pipe.child.output, bytes, sizeof(bytes));
        if (!count) {
            CloseDescriptor(pipe.child.output);
            return;
        }
        if (count < 0) {
            if (errno == EINTR)
                continue;
            if (errno != EAGAIN)
                EndPipe(pipe, "The language server’s output could not be read.");
            return;
        }

        std::string_view failure;
        auto result = ReadProtocolMessages(pipe.reader, {bytes, size_t(count)}, 8192, max_message, [&](Json body) {
            Packet packet;
            if (!ParsePacket(body, packet))
                failure = "The language server sent an invalid JSON message.";
            else if (!Post(pipe.id, PipeEvent::Message, packet))
                failure = "The language server sent too many responses at once.";
            return failure.empty();
        });
        if (result == ProtocolReadResult::InvalidHeader)
            failure = "The language server sent an invalid message header.";
        if (!failure.empty()) {
            EndPipe(pipe, failure);
            return;
        }
    }
}

static void ReadErrors(Pipe &pipe)
{
    char bytes[4096];
    for (int i = 0; i < 16 && pipe.child.errors >= 0; ++i) {
        ssize_t count = read(pipe.child.errors, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0) {
            if (!count || errno != EAGAIN)
                CloseDescriptor(pipe.child.errors);
            return;
        }
        AppendTail(pipe.stderr_tail, {bytes, size_t(count)}, 2048);
    }
}

static void Reap(Pipe &pipe)
{
    if (!pipe.closing) {
        ReadOutput(pipe);
        ReadErrors(pipe);
    }
    KillGroup(pipe.child.pid);
    int status = 0;
    pid_t exited = WaitChild(pipe.child.pid, &status);
    if (exited == 0 || (exited < 0 && errno == EINTR)) {
        pipe.reap_due = Clock::now() + 10ms;
        return;
    }
    pipe.child.pid = -1;
    auto detail = Trim(pipe.stderr_tail);
    char text[80];
    if (detail.empty()) {
        snprintf(text, sizeof(text), "Language server exited (%d).", exited > 0 ? ChildExitCode(status) : -1);
        detail = text;
    }
    EndPipe(pipe, detail);
}

static void Open(Pipe &pipe, Json payload, size_t argument_bytes)
{
    auto program = NextItem(payload);
    auto root = NextItem(payload);
    auto arguments = payload.substr(0, argument_bytes);
    payload.remove_prefix(argument_bytes);

    int error = StartTrackedChild(pipe.child, program.data(), arguments, root.data(), payload, {ChildInput::Pipe});
    if (error) {
        EndPipe(pipe, strerror(error));
        return;
    }
    if (!Watch(transport.queue, pipe.child.pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, pipe.id)) {
        EndPipe(pipe, "The language server process could not be monitored.");
        pipe.reap_due = Clock::now();
        return;
    }
    if (!Watch(transport.queue, pipe.child.output, EVFILT_READ, EV_ADD, 0, pipe.id) ||
        !Watch(transport.queue, pipe.child.errors, EVFILT_READ, EV_ADD, 0, pipe.id)) {
        EndPipe(pipe, "The language server’s pipes could not be opened.");
        return;
    }
    Post(pipe.id, PipeEvent::Ready, {});
}

static std::string_view WriteAvailable(Pipe &pipe, std::string_view bytes)
{
    while (!bytes.empty()) {
        ssize_t count = write(pipe.child.input, bytes.data(), bytes.size());
        if (count > 0)
            bytes.remove_prefix(size_t(count));
        else if (count < 0 && errno == EAGAIN)
            break;
        else if (count >= 0 || errno != EINTR) {
            EndPipe(pipe, "The language server stopped reading requests.");
            return {};
        }
    }
    return bytes;
}

static void Send(Pipe &pipe, std::string_view bytes)
{
    if (pipe.closing)
        return;
    if (pipe.writes.empty()) {
        bytes = WriteAvailable(pipe, bytes);
        if (bytes.empty())
            return;
        pipe.write_due = Clock::now() + 8s;
        if (!Watch(transport.queue, pipe.child.input, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, pipe.id)) {
            EndPipe(pipe, "The language server’s input could not be monitored.");
            return;
        }
    }
    if (pipe.writes.size() - pipe.written + bytes.size() > max_queued) {
        EndPipe(pipe, "The language server stopped keeping up with file changes.");
        return;
    }
    if (pipe.written >= 65536 && pipe.written >= pipe.writes.size() / 2) {
        pipe.writes.erase(0, pipe.written);
        pipe.written = 0;
    }
    pipe.writes += bytes;
}

static void Flush(Pipe &pipe)
{
    auto left = WriteAvailable(pipe, std::string_view(pipe.writes).substr(pipe.written));
    if (!left.empty()) {
        size_t written = pipe.writes.size() - left.size();
        if (written > pipe.written)
            pipe.write_due = Clock::now() + 8s;
        pipe.written = written;
        return;
    }
    if (pipe.child.input >= 0)
        Watch(transport.queue, pipe.child.input, EVFILT_WRITE, EV_DELETE, 0, pipe.id);
    pipe.written = 0;
    pipe.write_due = never;
    pipe.writes.clear();
    if (pipe.writes.capacity() > 128 * 1024)
        std::string().swap(pipe.writes);
}

static Pipe *FindPipe(std::vector<Pipe> &pipes, PipeID id)
{
    for (auto &pipe : pipes) {
        if (pipe.id == id)
            return &pipe;
    }
    return nullptr;
}

static void *RunWorker(void *)
{
    std::vector<Pipe> pipes;
    Mail<Work> jobs;
    for (;;) {
        {
            std::lock_guard lock(transport.mutex);
            if (transport.stop)
                break;
            std::swap(jobs, transport.outgoing);
        }
        for (const auto &job : jobs.rows) {
            auto data = std::string_view(jobs.bytes).substr(job.data.offset, job.data.length);
            if (job.kind == WorkKind::Open) {
                auto &pipe = pipes.emplace_back();
                pipe.id = job.id;
                Open(pipe, data, job.argument_bytes);
            } else if (auto *pipe = FindPipe(pipes, job.id)) {
                if (job.kind == WorkKind::Write)
                    Send(*pipe, data);
                else
                    EndPipe(*pipe, data);
            }
        }
        ClearMail(jobs);

        auto now = Clock::now(), due = never;
        for (auto &pipe : pipes) {
            if (pipe.write_due <= now)
                EndPipe(pipe, "The language server stopped reading requests.");
            if (pipe.reap_due <= now)
                Reap(pipe);
            due = std::min(due, std::min(pipe.write_due, pipe.reap_due));
        }
        std::erase_if(pipes, [](const Pipe &pipe) { return pipe.child.pid < 0; });
        timespec wake{};
        if (due != never) {
            auto ns = std::max(0ns, std::chrono::duration_cast<std::chrono::nanoseconds>(due - Clock::now())).count();
            wake = {time_t(ns / 1'000'000'000), long(ns % 1'000'000'000)};
        }
        struct kevent events[32];
        int count = kevent(transport.queue, nullptr, 0, events, std::size(events), due == never ? nullptr : &wake);
        if (count < 0 && errno != EINTR)
            break;
        for (int i = 0; i < count; ++i) {
            const auto &event = events[i];
            auto *pipe = FindPipe(pipes, PipeID(reinterpret_cast<uintptr_t>(event.udata)));
            if (!pipe || pipe->child.pid < 0)
                continue;
            if (event.filter == EVFILT_PROC) {
                Reap(*pipe);
            } else if (event.filter == EVFILT_READ && int(event.ident) == pipe->child.output) {
                ReadOutput(*pipe);
            } else if (event.filter == EVFILT_READ && int(event.ident) == pipe->child.errors) {
                ReadErrors(*pipe);
            } else if (event.filter == EVFILT_WRITE && int(event.ident) == pipe->child.input) {
                Flush(*pipe);
            }
        }
    }

    for (auto &pipe : pipes)
        EndPipe(pipe);
    auto deadline = Clock::now() + 150ms;
    while (!pipes.empty() && Clock::now() < deadline) {
        std::erase_if(pipes, [](const Pipe &pipe) {
            return pipe.child.pid < 0 || WaitChild(pipe.child.pid, nullptr) != 0;
        });
        if (!pipes.empty())
            poll(nullptr, 0, 5);
    }
    return nullptr;
}

static bool StartWorker(ReceivePipeEvent receive)
{
    if (transport.inbox)
        return true;
    transport.queue = kqueue();
    if (transport.queue < 0)
        return false;
    if (!Watch(transport.queue, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0)) {
        CloseDescriptor(transport.queue);
        return false;
    }
    transport.stop = false;
    transport.receive = receive;
    transport.inbox = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
    if (!transport.inbox || pthread_create(&transport.thread, nullptr, RunWorker, nullptr) != 0) {
        if (transport.inbox) {
            dispatch_activate(transport.inbox);
            dispatch_release(std::exchange(transport.inbox, nullptr));
        }
        CloseDescriptor(transport.queue);
        return false;
    }
    dispatch_source_set_event_handler_f(transport.inbox, Deliver);
    dispatch_activate(transport.inbox);
    return true;
}

PipeID StartPipe(std::string_view program, std::string_view arguments, std::string_view directory,
                 std::string_view environment, ReceivePipeEvent receive)
{
    if (!StartWorker(receive))
        return 0;
    PipeID id = ++transport.sequence;
    bool wake;
    {
        std::lock_guard lock(transport.mutex);
        auto &jobs = transport.outgoing;
        wake = jobs.rows.empty();
        size_t at = jobs.bytes.size();
        AppendItem(jobs.bytes, program);
        AppendItem(jobs.bytes, directory);
        jobs.bytes += arguments;
        jobs.bytes += environment;
        jobs.rows.push_back({id, WorkKind::Open, {uint32_t(at), uint32_t(jobs.bytes.size() - at)}, arguments.size()});
    }
    if (wake)
        WakeWorker();
    return id;
}

bool SendPacket(PipeID pipe, std::string_view body)
{
    if (!pipe || !transport.inbox)
        return false;
    std::string_view failure;
    bool wake;
    {
        std::lock_guard lock(transport.mutex);
        auto &jobs = transport.outgoing;
        wake = jobs.rows.empty();
        size_t at = jobs.bytes.size();
        WorkKind kind = WorkKind::Write;
        if (body.empty() || body.size() > max_message)
            failure = "A language server message exceeded the size limit.";
        else if (at + body.size() > max_queued)
            failure = "The language server stopped keeping up with file changes.";
        if (!failure.empty()) {
            kind = WorkKind::Fail;
            jobs.bytes += failure;
        } else {
            AppendProtocolMessage(jobs.bytes, body);
        }
        jobs.rows.push_back({pipe, kind, {uint32_t(at), uint32_t(jobs.bytes.size() - at)}});
    }
    if (wake)
        WakeWorker();
    return failure.empty();
}

void ClosePipe(PipeID pipe)
{
    if (!pipe || !transport.inbox)
        return;
    bool wake;
    {
        std::lock_guard lock(transport.mutex);
        wake = transport.outgoing.rows.empty();
        transport.outgoing.rows.push_back({pipe, WorkKind::Close, {}});
    }
    if (wake)
        WakeWorker();
}

void StopPipes()
{
    if (!transport.inbox)
        return;
    {
        std::lock_guard lock(transport.mutex);
        transport.stop = true;
    }
    WakeWorker();
    pthread_join(transport.thread, nullptr);
    CloseDescriptor(transport.queue);
    dispatch_source_cancel(transport.inbox);
    dispatch_release(std::exchange(transport.inbox, nullptr));
    transport.outgoing = {};
    transport.incoming = {};
}

} // namespace lsp