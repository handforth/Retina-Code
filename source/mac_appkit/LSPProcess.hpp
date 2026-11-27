#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <dispatch/dispatch.h>
#include <initializer_list>
#include <span>
#include <string>
#include <string_view>

namespace lsp {

using Clock = std::chrono::steady_clock;
using Environment = std::string; // NUL-separated name=value entries.

void AppendItem(std::string &bytes, std::string_view item);
std::string_view NextItem(std::string_view &bytes);
Environment ReadEnvironment();
void SetEnvironment(Environment &environment, std::string_view name, std::string_view value);
void RemoveEnvironment(Environment &environment, std::string_view name);
void StartChildProcesses();
void StopChildProcesses();

struct CommandResult {
    bool succeeded = false;
    std::string output;
};

struct Progress {
    void *context = nullptr;
    void (*notify)(void *, std::string_view) = nullptr;
};

CommandResult RunCommand(std::string_view program, std::span<const std::string_view> arguments, std::string_view directory,
                         const Environment &environment, std::chrono::seconds timeout, const std::atomic_bool *cancelled = nullptr,
                         Progress progress = {});

inline CommandResult RunCommand(std::string_view program, std::initializer_list<std::string_view> arguments,
                                std::string_view directory, const Environment &environment, std::chrono::seconds timeout,
                                const std::atomic_bool *cancelled = nullptr, Progress progress = {})
{
    return RunCommand(program, std::span(arguments.begin(), arguments.size()), directory, environment, timeout, cancelled, progress);
}

using PipeID = uint64_t;
enum class PipeEvent { Ready, Message, Failed };
enum class PacketField { Method, Identifier, Result, Parameters, Error, Count };
struct PacketRange {
    uint32_t offset = 0;
    uint32_t length = 0;
};
struct Packet {
    std::string_view bytes;
    std::array<PacketRange, size_t(PacketField::Count)> fields{};
};

inline std::string_view Field(const Packet &packet, PacketField field)
{
    auto range = packet.fields[size_t(field)];
    return packet.bytes.substr(range.offset, range.length);
}

using ReceivePipeEvent = void (*)(PipeID, PipeEvent, const Packet &);
PipeID StartPipe(std::string_view program, std::string_view arguments, std::string_view directory,
                 std::string_view environment, ReceivePipeEvent receive);
bool SendPacket(PipeID pipe, std::string_view body);
void ClosePipe(PipeID pipe);
void StopPipes();

} // namespace lsp