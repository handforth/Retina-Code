#pragma once

#include "../Lexer.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

enum class LSPState { Starting, Ready, Missing, Installing, Uninstalling, Failed, Stopped };

struct LSPPosition {
    size_t line = 0;
    size_t character = 0;
};

namespace lsp {

struct Command {
    std::string executable;
    std::string arguments; // NUL-separated arguments.
};

struct Host {
    std::string home;
    std::string managedTools;
    Command (*command)(Language) = nullptr;
    bool (*toolsDisabled)(std::string_view) = nullptr;
    void (*setToolsDisabled)(std::string_view, bool) = nullptr;
};

using DocumentID = uint64_t;

struct DocumentCallbacks {
    void *context = nullptr;
    void (*appendText)(void *, std::string &json) = nullptr;
    LSPPosition (*end)(void *) = nullptr;
    void (*updated)(void *) = nullptr;
    void (*diagnosticsChanged)(void *, std::string_view) = nullptr;
    void (*inlayHintsChanged)(void *) = nullptr;
};

struct Change {
    LSPPosition start;
    LSPPosition end;
    std::string_view text;
};

struct InlayHint {
    uint32_t line, character;
    uint32_t labelOffset, labelLength;
    bool paddingLeft, paddingRight;
};

struct InlayHints {
    std::vector<InlayHint> items;
    std::string labels;
};

struct Reply {
    void *context = nullptr;
    void (*call)(void *, std::string_view result, std::string_view error) = nullptr;
    void (*release)(void *) = nullptr;
};

struct ApplyEdit {
    void *context = nullptr;
    std::string (*call)(void *, std::string_view edit) = nullptr;
    void (*release)(void *) = nullptr;
};

// The client and its callbacks run on the UI thread. Text suppliers read the document synchronously.
// Requests consume their callbacks. Reply views are valid until the callback returns.
void Configure(Host host);
DocumentID CreateDocument(std::string_view file, std::string_view uri, std::string_view workspace, Language language,
                          DocumentCallbacks callbacks);
void DestroyDocument(DocumentID document);

std::string_view Root(DocumentID document);
LSPState State(DocumentID document);
std::string_view Status(DocumentID document);
std::string_view FailureTitle(DocumentID document);
std::string ServerName(DocumentID document);
bool CanInstall(DocumentID document);
bool CanUninstall(DocumentID document);
size_t Version(DocumentID document);
bool SendingChanges(DocumentID document);
bool ChangedSinceSave(DocumentID document);
bool HandlesDiagnostics(DocumentID document);
bool Supports(DocumentID document, std::string_view capability);
bool TriggersCompletion(DocumentID document, std::string_view character);
bool ResolvesCodeActions(DocumentID document);

void Start(DocumentID document);
void Restart(DocumentID document);
void Stop(DocumentID document);
void Close(DocumentID document);
void Install(DocumentID document);
void CancelInstall(DocumentID document);
void Uninstall(DocumentID document);
void Reconfigure(Language language);
void StopAll();

void Changed(DocumentID document, std::optional<Change> change);
void Saved(DocumentID document);
int64_t Request(DocumentID document, std::string_view method, std::string_view params, Reply reply);
int64_t RequestInlayHints(DocumentID document, LSPPosition start, LSPPosition end, Reply reply);
InlayHints ReadInlayHints(std::string_view result);
void CancelRequest(DocumentID document, int64_t id);
void ExecuteCommand(DocumentID document, std::string_view command, ApplyEdit apply, Reply reply);

} // namespace lsp