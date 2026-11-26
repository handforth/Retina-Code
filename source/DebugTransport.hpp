#pragma once

#include "ChildProcess.hpp"
#include <vector>

enum class DebugEventKind { Packet, Console, Program, ProgramError, AdapterError, Invalid, Exit };

struct DebugEvent {
    DebugEventKind kind;
    size_t offset, length;
};

struct DebugBatch {
    std::vector<DebugEvent> events;
    std::string bytes;
};

struct DebugTransport {
    std::mutex mutex;
    ChildProcess child;
    int queue = -1;
    int terminal[2]{-1, -1};
    bool closeInput = false;
    bool stopping = false;
    bool ended = false;
    bool readPaused = false;
    bool lispRequests = false;
    std::string requests, input;
    std::string packet;
    DebugBatch inbox;
    void (*notify)(void *) = nullptr;
    void *context = nullptr;
};

// Start and submit on the main thread. The owner remains alive until it receives Exit.
int StartDebugTransport(DebugTransport &transport, const char *const *argv, const char *directory, void (*notify)(void *), void *context);
int StartDebugTerminal(DebugTransport &transport, char *path);
bool SendDebugPacket(DebugTransport &transport, std::string_view body);
bool SendDebugRequest(DebugTransport &transport, uint64_t sequence, std::string_view command, std::string_view arguments);
bool SendDebugInput(DebugTransport &transport, std::string_view bytes);
void RequestDebugStop(DebugTransport &transport);
void CloseDebugInput(DebugTransport &transport);
void TakeDebugEvents(DebugTransport &transport, DebugBatch &batch);