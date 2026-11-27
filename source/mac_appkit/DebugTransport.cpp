#include "DebugTransport.hpp"
#include "../LSPJson.hpp"
#include "../ProtocolReader.h"
#include "../RunText.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

using DebugClock = std::chrono::steady_clock;
using namespace std::chrono_literals;

static constexpr auto noDeadline = DebugClock::time_point::max();
static constexpr size_t maxPacket = 16 * 1024 * 1024;
static constexpr size_t maxQueue = 2 * maxPacket;

static bool Watch(int queue, uintptr_t key, short filter, unsigned short flags, unsigned mask = 0)
{
    struct kevent change;
    EV_SET(&change, key, filter, flags, mask, 0, nullptr);
    return kevent(queue, &change, 1, nullptr, 0, nullptr) == 0;
}

static void Wake(DebugTransport &transport)
{
    Watch(transport.queue, 1, EVFILT_USER, 0, NOTE_TRIGGER);
}

static bool IsText(DebugEventKind kind)
{
    return kind >= DebugEventKind::Console && kind <= DebugEventKind::AdapterError;
}

static void AppendEvent(DebugBatch &batch, DebugEventKind kind, std::string_view bytes = {})
{
    if (IsText(kind) && !batch.events.empty() && batch.events.back().kind == kind &&
        batch.events.back().length + bytes.size() <= 16 * 1024) {
        batch.events.back().length += bytes.size();
    } else {
        batch.events.push_back({kind, batch.bytes.size(), bytes.size()});
    }

    batch.bytes += bytes;
}

static void ClearBatch(DebugBatch &batch)
{
    batch.events.clear();
    batch.bytes.clear();
    if (batch.events.capacity() > 2048)
        std::vector<DebugEvent>().swap(batch.events);
    if (batch.bytes.capacity() > 128 * 1024)
        std::string().swap(batch.bytes);
}

static void Publish(DebugTransport &transport, DebugBatch &batch, bool ended = false)
{
    if (batch.events.empty())
        return;

    std::lock_guard lock(transport.mutex);
    bool wake = transport.inbox.events.empty();
    if (wake) {
        std::swap(batch, transport.inbox);
    } else {
        for (const auto &event : batch.events)
            AppendEvent(transport.inbox, event.kind, std::string_view(batch.bytes).substr(event.offset, event.length));
    }

    if (ended) {
        // The owner may release the transport after this notification.
        transport.ended = true;
        CloseDescriptor(transport.queue);
    }

    if (wake)
        transport.notify(transport.context);
}

void TakeDebugEvents(DebugTransport &transport, DebugBatch &batch)
{
    ClearBatch(batch);
    std::lock_guard lock(transport.mutex);
    std::swap(transport.inbox, batch);
    if (transport.readPaused && !transport.ended)
        Wake(transport);
}

static bool ReceivePacket(DebugBatch &batch, std::string_view packet, std::string &decoded)
{
    using namespace lsp;
    Json input = packet;
    Json type, event, body;
    SkipJsonSpace(input);
    if (!TakeJsonChar(input, '{'))
        return false;

    SkipJsonSpace(input);
    while (!TakeJsonChar(input, '}')) {
        Json name, field;
        if (!NextJsonMember(input, name, field))
            return false;

        if (JsonNameEquals(name, "type"))
            type = field;
        else if (JsonNameEquals(name, "event"))
            event = field;
        else if (JsonNameEquals(name, "body"))
            body = field;
    }

    SkipJsonSpace(input);
    if (!input.empty())
        return false;

    if (!JsonNameEquals(JsonContents(type), "event") || !JsonNameEquals(JsonContents(event), "output")) {
        AppendEvent(batch, DebugEventKind::Packet, packet);
        return true;
    }

    auto category = JsonField(body, "category");
    auto output = JsonField(body, "output");
    if (JsonNameEquals(JsonContents(category), "telemetry") || !IsString(output))
        return true;

    category = JsonContents(category);
    auto text = JsonContents(output);
    if (text.find('\\') != text.npos) {
        DecodeJsonString(text, decoded);
        text = decoded;
    }

    if (!text.empty()) {
        auto kind = JsonNameEquals(category, "stdout") ? DebugEventKind::Program :
                    JsonNameEquals(category, "stderr") ? DebugEventKind::ProgramError : DebugEventKind::Console;
        AppendEvent(batch, kind, text);
    }

    return true;
}

struct DebugWrite {
    std::string bytes;
    size_t sent = 0;
    bool watching = false;
};

static bool TakeWrites(std::string &queued, DebugWrite &write, size_t limit)
{
    if (queued.empty())
        return false;
    if (queued.size() + write.bytes.size() - write.sent > limit)
        return true;

    if (write.bytes.empty()) {
        queued.swap(write.bytes);
    } else {
        if (write.sent >= 65536 && write.sent >= write.bytes.size() / 2) {
            write.bytes.erase(0, write.sent);
            write.sent = 0;
        }

        write.bytes += queued;
        queued.clear();
    }

    return false;
}

static void WriteDebugBytes(int queue, int &fd, DebugWrite &output, bool closeInput)
{
    if (fd < 0) {
        output.bytes.clear();
        output.sent = 0;
        return;
    }

    while (output.sent < output.bytes.size()) {
        auto count = write(fd, output.bytes.data() + output.sent, output.bytes.size() - output.sent);
        if (count > 0) {
            output.sent += size_t(count);
        } else if (count < 0 && errno == EAGAIN) {
            if (output.watching || Watch(queue, fd, EVFILT_WRITE, EV_ADD | EV_CLEAR)) {
                output.watching = true;
                return;
            }

            CloseDescriptor(fd);
            break;
        } else if (count >= 0 || errno != EINTR) {
            CloseDescriptor(fd);
            break;
        }
    }

    output.bytes.clear();
    output.sent = 0;
    if (closeInput) {
        CloseDescriptor(fd);
    } else if (output.watching && fd >= 0) {
        Watch(queue, fd, EVFILT_WRITE, EV_DELETE);
        output.watching = false;
    }

    if (output.bytes.capacity() > 128 * 1024)
        std::string().swap(output.bytes);
}

struct DebugWorker {
    int terminal[2]{-1, -1};
    DebugWrite requests, input;
    ProtocolReader reader;
    std::string decoded;
    std::string tails[2];
    DebugBatch batch;
    bool invalid = false;
};

static void ReadDebugBytes(DebugWorker &worker, int &fd, DebugEventKind kind, size_t limit)
{
    char bytes[8192];
    for (size_t i = 0; fd >= 0 && i < limit; ++i) {
        ssize_t size = read(fd, bytes, sizeof(bytes));
        if (size < 0 && errno == EINTR)
            continue;

        if (size <= 0) {
            if (!size || errno != EAGAIN)
                CloseDescriptor(fd);
            break;
        }

        std::string_view input(bytes, size_t(size));
        if (kind == DebugEventKind::Packet) {
            if (!worker.invalid) {
                auto result = ReadProtocolMessages(worker.reader, input, 4096, maxPacket, [&](std::string_view packet) {
                    return ReceivePacket(worker.batch, packet, worker.decoded);
                });
                if (result != ProtocolReadResult::Valid) {
                    worker.reader = {};
                    worker.invalid = true;
                    AppendEvent(worker.batch, DebugEventKind::Invalid);
                }
            }
        } else {
            auto &tail = worker.tails[kind == DebugEventKind::Program ? 0 : 1];
            if (!tail.empty()) {
                size_t next = 0;
                while (next < input.size() && next < 3 && (uint8_t(input[next]) & 0xC0) == 0x80)
                    ++next;

                tail.append(input.substr(0, next));
                if (next != input.size() || CompleteUTF8Prefix(tail) == tail.size()) {
                    AppendEvent(worker.batch, kind, tail);
                    tail.clear();
                }
                input.remove_prefix(next);
            }

            size_t end = CompleteUTF8Prefix(input);
            if (end)
                AppendEvent(worker.batch, kind, input.substr(0, end));
            if (end < input.size())
                tail = input.substr(end);
        }
    }
}

static void RunDebugTransport(void *context)
{
    auto &transport = *static_cast<DebugTransport *>(context);
    auto &child = transport.child;
    DebugWorker worker;
    auto stop_due = noDeadline;
    bool stopping = false, terminated = false;
    bool exited = false;
    auto reap_due = noDeadline;
    constexpr size_t read_limit = 2;
    constexpr size_t read_watermark = 16 * 1024;

    for (;;) {
        Publish(transport, worker.batch);
        ClearBatch(worker.batch);

        bool close_input, stop_requested, more_requests, more_input;
        {
            std::lock_guard lock(transport.mutex);
            more_requests = TakeWrites(transport.requests, worker.requests, maxQueue);
            more_input = TakeWrites(transport.input, worker.input, 65536);
            close_input = transport.closeInput && !more_requests;

            // Let the adapter's pipes provide back pressure while the UI is busy.
            bool pause = transport.inbox.bytes.size() >= read_watermark || transport.inbox.events.size() >= 1024;
            if (pause != transport.readPaused) {
                transport.readPaused = pause;
                for (int fd : {child.output, child.errors, worker.terminal[0]}) {
                    if (fd >= 0)
                        Watch(transport.queue, fd, EVFILT_READ, pause ? EV_DISABLE : EV_ENABLE);
                }
            }

            stop_requested = transport.stopping;
            if (transport.terminal[0] >= 0) {
                worker.terminal[0] = transport.terminal[0];
                worker.terminal[1] = transport.terminal[1];
                transport.terminal[0] = transport.terminal[1] = -1;
                unsigned flags = EV_ADD | (transport.readPaused ? EV_DISABLE : 0);
                if (!Watch(transport.queue, worker.terminal[0], EVFILT_READ, flags))
                    CloseDescriptor(worker.terminal[0]);
            }
        }

        auto now = DebugClock::now();
        if (stop_requested && !stopping) {
            stopping = true;
            stop_due = now + 2s;
        }

        if (!exited && now >= stop_due) {
            kill(child.pid, terminated ? SIGKILL : SIGTERM);
            stop_due = terminated ? noDeadline : now + 1s;
            terminated = true;
        }

        WriteDebugBytes(transport.queue, child.input, worker.requests, close_input);
        WriteDebugBytes(transport.queue, worker.terminal[0], worker.input, false);

        if (now >= reap_due) {
            int status;
            pid_t result = waitpid(child.pid, &status, WNOHANG);
            if (result == child.pid || (result < 0 && errno != EINTR))
                break;

            reap_due = now + 10ms;
        }

        if ((more_requests && worker.requests.bytes.empty()) || (more_input && worker.input.bytes.empty()))
            continue;

        timespec timeout{};
        auto due = std::min(stop_due, reap_due);
        if (due != noDeadline) {
            auto ns = std::max(0ns, std::chrono::duration_cast<std::chrono::nanoseconds>(due - DebugClock::now())).count();
            timeout = {time_t(ns / 1'000'000'000), long(ns % 1'000'000'000)};
        }

        struct kevent events[8];
        int count = kevent(transport.queue, nullptr, 0, events, 8, due == noDeadline ? nullptr : &timeout);
        if (count < 0 && errno != EINTR) {
            kill(child.pid, SIGKILL);
            while (waitpid(child.pid, nullptr, 0) < 0 && errno == EINTR) {}
            break;
        }

        for (int i = 0; i < count; ++i) {
            const auto &event = events[i];
            if (event.filter == EVFILT_PROC) {
                exited = true;
                stop_due = noDeadline;
                reap_due = DebugClock::now();
            } else if (event.filter == EVFILT_READ) {
                int fd = int(event.ident);
                if (fd == child.output)
                    ReadDebugBytes(worker, child.output, DebugEventKind::Packet, read_limit);
                else if (fd == child.errors)
                    ReadDebugBytes(worker, child.errors, DebugEventKind::AdapterError, read_limit);
                else if (fd == worker.terminal[0])
                    ReadDebugBytes(worker, worker.terminal[0], DebugEventKind::Program, read_limit);
            }
        }
    }

    // The process can exit before the main loop has read the last pipe buffer.
    constexpr size_t final_reads = 32;
    ReadDebugBytes(worker, child.output, DebugEventKind::Packet, final_reads);
    ReadDebugBytes(worker, child.errors, DebugEventKind::AdapterError, final_reads);
    ReadDebugBytes(worker, worker.terminal[0], DebugEventKind::Program, final_reads);
    if (!worker.tails[0].empty())
        AppendEvent(worker.batch, DebugEventKind::Program, worker.tails[0]);
    if (!worker.tails[1].empty())
        AppendEvent(worker.batch, DebugEventKind::AdapterError, worker.tails[1]);

    CloseChildStreams(child);
    CloseDescriptor(worker.terminal[0]);
    CloseDescriptor(worker.terminal[1]);
    {
        std::lock_guard lock(transport.mutex);
        CloseDescriptor(transport.terminal[0]);
        CloseDescriptor(transport.terminal[1]);
        transport.requests = {};
        transport.input = {};
    }

    AppendEvent(worker.batch, DebugEventKind::Exit);
    Publish(transport, worker.batch, true);
}

int StartDebugTransport(DebugTransport &transport, const char *const *argv, const char *directory, void (*notify)(void *), void *context)
{
    transport.queue = kqueue();
    if (transport.queue < 0)
        return errno;

    fcntl(transport.queue, F_SETFD, FD_CLOEXEC);
    int error = Watch(transport.queue, 1, EVFILT_USER, EV_ADD | EV_CLEAR) ? 0 : errno;
    if (!error)
        error = StartChild(transport.child, argv, directory, {ChildInput::Pipe});

    if (!error && (!Watch(transport.queue, transport.child.output, EVFILT_READ, EV_ADD) ||
        !Watch(transport.queue, transport.child.errors, EVFILT_READ, EV_ADD) ||
        !Watch(transport.queue, transport.child.pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT))) {
        error = errno;
        kill(transport.child.pid, SIGKILL);
        while (waitpid(transport.child.pid, nullptr, 0) < 0 && errno == EINTR) {}
        CloseChildStreams(transport.child);
    }

    if (error) {
        CloseDescriptor(transport.queue);
        return error;
    }

    transport.notify = notify;
    transport.context = context;
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &transport, RunDebugTransport);
    return 0;
}

int StartDebugTerminal(DebugTransport &transport, char *path)
{
    int ends[2]{-1, -1};
    int error = OpenTerminal(ends, path, false);
    if (error)
        return error;

    std::lock_guard lock(transport.mutex);
    if (transport.ended) {
        CloseDescriptor(ends[0]);
        CloseDescriptor(ends[1]);
        return EPIPE;
    }

    transport.terminal[0] = ends[0];
    transport.terminal[1] = ends[1];
    Wake(transport);
    return 0;
}

static bool QueueDebugPacket(DebugTransport &transport, std::string_view body, bool framed)
{
    std::lock_guard lock(transport.mutex);
    if (transport.ended || transport.closeInput || body.empty() || body.size() > maxPacket ||
        body.size() + 32 + transport.requests.size() > maxQueue)
        return false;

    bool wake = transport.requests.empty();
    if (framed)
        AppendProtocolMessage(transport.requests, body);
    else
        transport.requests += body;

    if (wake)
        Wake(transport);

    return true;
}

bool SendDebugPacket(DebugTransport &transport, std::string_view body)
{
    return QueueDebugPacket(transport, body, true);
}

static void AppendLispString(std::string &packet, std::string_view text)
{
    packet += '"';
    for (char ch : text) {
        if (ch == '"' || ch == '\\')
            packet += '\\';

        packet += ch;
    }

    packet += '"';
}

static void AppendLispArgument(std::string &packet, lsp::Json value, std::string &decoded)
{
    if (lsp::IsObject(value)) {
        packet += '(';
        auto members = lsp::JsonContents(value);
        lsp::Json key, field;
        while (lsp::NextJsonMember(members, key, field)) {
            lsp::DecodeJsonString(key, decoded);
            AppendLispString(packet, decoded);
            packet += ' ';
            AppendLispArgument(packet, field, decoded);
            packet += ' ';
        }

        packet += ')';
    } else if (lsp::IsArray(value)) {
        packet += '(';
        auto items = lsp::JsonContents(value);
        for (auto item = lsp::NextJsonValue(items); !item.empty(); item = lsp::NextJsonValue(items)) {
            AppendLispArgument(packet, item, decoded);
            packet += ' ';
        }

        packet += ')';
    } else if (lsp::IsString(value)) {
        lsp::DecodeJsonString(lsp::JsonContents(value), decoded);
        AppendLispString(packet, decoded);
    } else if (lsp::JsonInteger(value)) {
        packet += value;
    } else {
        packet += value == "true" ? "t" : "nil";
    }
}

bool SendDebugRequest(DebugTransport &transport, uint64_t sequence, std::string_view command, std::string_view arguments)
{
    auto &packet = transport.packet;
    char number[24];
    auto end = std::to_chars(number, number + sizeof(number), sequence).ptr;
    if (transport.lispRequests) {
        packet = '(';
        packet.append(number, end);
        packet += ' ';
        AppendLispString(packet, command);
        packet += ' ';
        std::string decoded;
        AppendLispArgument(packet, arguments, decoded);
        packet += ")\n";
        return QueueDebugPacket(transport, packet, false);
    }

    packet = R"({"type":"request","seq":)";
    packet.append(number, end);
    packet += R"(,"command":)";
    lsp::AppendJsonString(packet, command);
    packet += R"(,"arguments":)";
    packet += arguments.empty() ? "{}" : arguments;
    packet += '}';
    bool sent = SendDebugPacket(transport, packet);
    if (packet.capacity() > 128 * 1024)
        std::string().swap(packet);

    return sent;
}

bool SendDebugInput(DebugTransport &transport, std::string_view bytes)
{
    std::lock_guard lock(transport.mutex);
    if (transport.ended || bytes.empty() || bytes.size() > 65536 - transport.input.size())
        return false;

    transport.input += bytes;
    Wake(transport);
    return true;
}

void RequestDebugStop(DebugTransport &transport)
{
    std::lock_guard lock(transport.mutex);
    if (transport.ended)
        return;

    transport.stopping = true;
    Wake(transport);
}

void CloseDebugInput(DebugTransport &transport)
{
    std::lock_guard lock(transport.mutex);
    if (transport.ended)
        return;

    transport.closeInput = true;
    Wake(transport);
}