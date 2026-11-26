#include "LanguageServer.hpp"
#include "LanguageTools.hpp"
#include "ChildProcess.hpp"
#include "LSPJson.hpp"

#include <algorithm>
#include <array>
#include <filesystem>
#include <functional>
#include <unistd.h>
#include <utility>
#include <vector>

namespace lsp {
using namespace std::chrono_literals;

static constexpr auto noDeadline = Clock::time_point::max();
static constexpr size_t maxPendingRequests = 64;
static constexpr size_t maxDiagnostics = 512;
static constexpr size_t maxDiagnosticCharacters = 96 * 1024;
static constexpr size_t maxDiagnosticBytes = 2 * 1024 * 1024;
static constexpr Json capabilityNames[]{
    "definitionProvider", "referencesProvider", "hoverProvider", "signatureHelpProvider", "renameProvider",
    "documentFormattingProvider", "codeActionProvider", "documentSymbolProvider", "completionProvider", "diagnosticProvider",
    "documentRangeFormattingProvider", "inlayHintProvider"
};

using ServerID = uint64_t;

struct Diagnostic {
    uint32_t at, length;
    uint32_t key, keyLength;
    uint32_t characters;
};

struct Diagnostics {
    std::string bytes;
    std::vector<Diagnostic> items;
};

struct QueuedChange {
    LSPPosition start, end;
    uint32_t offset, length;
};

struct Document {
    DocumentID id = 0;
    ServerID server = 0;
    std::string names; // File, URI, and workspace root share storage.
    size_t uriOffset = 0, rootOffset = 0;
    Language language = Language::Plain;
    DocumentCallbacks callbacks;
    size_t version = 1;
    size_t sentVersion = 0;
    size_t savedVersion = 0;
    LSPPosition sentEnd;
    bool opened = false;
    bool standaloneRust = false;
    bool fullChange = false;
    std::vector<QueuedChange> changes;
    std::string changeBytes;
    Clock::time_point changeDue = noDeadline;
    Clock::time_point diagnosticDue = noDeadline;
    int64_t diagnosticRequest = 0;
    bool refreshPending = false;
    Diagnostics pushed, pulled;
    bool publishedDiagnostics = false;
    bool receivedPushDiagnostics = false;
};

enum class RequestKind { Initialize, Reply, Diagnostics, Command };

struct Pending {
    int64_t id = 0;
    Clock::time_point due{};
    DocumentID document = 0;
    size_t version = 0;
    RequestKind kind = RequestKind::Reply;
    Reply reply;
};

struct Server {
    ServerID id = 0;
    PipeID pipe = 0;
    std::string root;
    std::string folders;
    Command command;
    const Tool *tool = nullptr;
    Language language = Language::Plain;
    LSPState state = LSPState::Missing;
    std::string status;
    std::string_view failureTitle;
    uint16_t capabilities = 0;
    std::string triggers;
    unsigned sync = 0;
    bool openClose = false;
    bool save = false;
    bool saveText = false;
    bool resolve = false;
    bool pullDiagnostics = false;
    uint64_t launch = 0;
    int64_t sequence = 0;
    std::vector<Pending> pending;
    int64_t commandRequest = 0;
    DocumentID commandDocument = 0;
    size_t commandVersion = 0;
    ApplyEdit commandEdit;
};

struct LocateTask {
    ServerID server;
    uint64_t launch;
    const Tool *tool;
    Language language;
    bool custom;
    ToolPaths paths;
    std::string root;
    std::string executable;
};

struct ToolOperation {
    const Tool *tool;
    Language language;
    bool removing = false;
    bool wasDisabled = false;
    std::atomic_bool cancelled{false};
    ToolPaths paths;
    std::string root;
    std::string error;
};

struct RetiringPipe {
    PipeID pipe;
    Clock::time_point due;
};

static struct {
    Host host;
    ToolPaths paths;
    std::vector<Document> documents;
    std::vector<Server> servers;
    std::vector<ToolOperation *> tools;
    std::vector<RetiringPipe> retiring;
    std::string outgoing;
    Diagnostics diagnosticReport;
    std::string diagnosticJSON;
    uint64_t generation = 0;
    dispatch_source_t timer = nullptr;
    Clock::time_point timerDue = noDeadline;
    bool stopping = false;
} client;

template<class T>
static T *Find(std::vector<T> &rows, uint64_t id)
{
    uint32_t index = uint32_t(id);
    if (!index || index > rows.size() || rows[index - 1].id != id)
        return nullptr;
    return &rows[index - 1];
}

template<class T>
static T &NewRecord(std::vector<T> &rows)
{
    size_t index = 0;
    while (index < rows.size() && rows[index].id)
        ++index;
    if (index == rows.size())
        rows.emplace_back();
    // The low half is the slot. A reused slot must reject old replies.
    rows[index].id = (++client.generation << 32) | (index + 1);
    return rows[index];
}

static Document *FindDocument(DocumentID id)
{
    return Find(client.documents, id);
}

static Server *FindServer(ServerID id)
{
    return Find(client.servers, id);
}

static Server *DocumentServer(DocumentID id)
{
    auto *document = FindDocument(id);
    return document ? FindServer(document->server) : nullptr;
}

static Json File(const Document &document)
{
    return Json(document.names).substr(0, document.uriOffset);
}

static Json URI(const Document &document)
{
    return Json(document.names).substr(document.uriOffset, document.rootOffset - document.uriOffset);
}

static Json WorkspaceRoot(const Document &document)
{
    return Json(document.names).substr(document.rootOffset);
}

template<class Visit>
static void VisitDocuments(ServerID server, Visit visit)
{
    size_t count = client.documents.size();
    for (size_t i = 0; i < count && i < client.documents.size(); ++i) {
        auto &document = client.documents[i];
        if (document.id && document.server == server)
            visit(document);
    }
}

template<class Visit>
static void VisitServers(Visit visit)
{
    size_t count = client.servers.size();
    for (size_t i = 0; i < count && i < client.servers.size(); ++i) {
        auto &server = client.servers[i];
        if (server.id)
            visit(server);
    }
}

static void Tick();
static void PullDiagnostics(Document &document);
static void FinishPending(ServerID session, Pending request, Json result, Json error);

static void WakeAt(Clock::time_point due)
{
    if (due >= client.timerDue)
        return;
    client.timerDue = due;
    if (!client.timer) {
        client.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler_f(client.timer, [](void *) { Tick(); });
        dispatch_resume(client.timer);
    }
    auto delay = std::max(0ns, std::chrono::duration_cast<std::chrono::nanoseconds>(due - Clock::now()));
    dispatch_source_set_timer(client.timer, dispatch_time(DISPATCH_TIME_NOW, delay.count()), DISPATCH_TIME_FOREVER, 1'000'000);
}

static void ClearBytes(std::string &bytes)
{
    bytes.clear();
    if (bytes.capacity() > 128 * 1024)
        std::string().swap(bytes);
}

static bool IsTrue(Json value)
{
    return value == "true" || JsonInteger(value).value_or(0) != 0;
}

static bool Supported(Json value)
{
    return IsObject(value) || IsTrue(value);
}

static Json TextView(Json value, std::string &decoded)
{
    if (!IsString(value))
        return {};
    auto text = JsonContents(value);
    if (text.find('\\') == text.npos)
        return text;
    DecodeJsonString(text, decoded);
    return decoded;
}

static void AppendNumber(std::string &message, uint64_t number)
{
    char digits[24];
    auto end = std::to_chars(digits, digits + sizeof(digits), number).ptr;
    message.append(digits, end);
}

static void AppendPosition(std::string &message, LSPPosition position)
{
    message += R"({"line":)";
    AppendNumber(message, position.line);
    message += R"(,"character":)";
    AppendNumber(message, position.character);
    message += '}';
}

static void AppendRange(std::string &message, LSPPosition start, LSPPosition end)
{
    message += R"({"start":)";
    AppendPosition(message, start);
    message += R"(,"end":)";
    AppendPosition(message, end);
    message += '}';
}

static std::string &MessagePrefix(Json method)
{
    auto &message = client.outgoing;
    message = R"({"jsonrpc":"2.0","method":)";
    AppendJsonString(message, method);
    return message;
}

static void SendMessage(PipeID pipe)
{
    SendPacket(pipe, client.outgoing);
    ClearBytes(client.outgoing);
}

static std::string &ParametersPrefix(Json method)
{
    auto &message = MessagePrefix(method);
    message += R"(,"params":)";
    return message;
}

static void AppendDocument(std::string &message, const Document &document)
{
    message += R"({"textDocument":{"uri":)";
    AppendJsonString(message, URI(document));
    message += "}}";
}

static void Notify(Server &server, Json method, Json params)
{
    auto &message = ParametersPrefix(method);
    message += params;
    message += '}';
    SendMessage(server.pipe);
}

static int64_t SendRequest(Server &server, Json method, Json params, Pending request)
{
    if (!server.pipe || server.pending.size() >= maxPendingRequests)
        return 0;
    request.id = ++server.sequence;
    auto &message = MessagePrefix(method);
    message += R"(,"id":)";
    AppendNumber(message, uint64_t(request.id));
    if (!params.empty()) {
        message += R"(,"params":)";
        message += params;
    }
    message += '}';
    bool sent = SendPacket(server.pipe, message);
    ClearBytes(message);
    if (!sent)
        return 0;
    request.due = Clock::now() + 12s;
    server.pending.push_back(request);
    WakeAt(request.due);
    return request.id;
}

static Pending TakeRequest(Server &server, int64_t id, DocumentID document = 0)
{
    auto found = std::ranges::find(server.pending, id, &Pending::id);
    if (found == server.pending.end() || (document && found->document != document))
        return {};
    auto request = *found;
    *found = server.pending.back();
    server.pending.pop_back();
    return request;
}

static void SendCancellation(Server &server, int64_t id)
{
    auto &message = ParametersPrefix("$/cancelRequest");
    message += R"({"id":)";
    AppendNumber(message, uint64_t(id));
    message += "}}";
    SendMessage(server.pipe);
}

static void ReleaseReply(Reply reply)
{
    if (reply.release)
        reply.release(reply.context);
}

static void ReplyTo(Reply reply, Json result, Json error)
{
    if (reply.call)
        reply.call(reply.context, result, error);
    ReleaseReply(reply);
}

static void ReleaseEdit(ApplyEdit edit)
{
    if (edit.release)
        edit.release(edit.context);
}

static void ClearCommand(Server &server)
{
    server.commandDocument = 0;
    server.commandRequest = 0;
    ReleaseEdit(std::exchange(server.commandEdit, {}));
}

static void Cancel(Server &server, int64_t id, DocumentID document = 0)
{
    auto request = TakeRequest(server, id, document);
    if (!request.id)
        return;
    SendCancellation(server, id);
    if (request.kind == RequestKind::Command)
        ClearCommand(server);
    ReleaseReply(request.reply);
}

static bool UsesRustAnalyzer(const Server &server)
{
    Json executable = server.command.executable;
    auto base = executable.find_last_of('/');
    if (base != executable.npos)
        executable.remove_prefix(base + 1);
    return server.language == Language::Rust && (executable.empty() || executable == "rust-analyzer");
}

static bool UsesLanguageTool(const Server &server, Json name)
{
    Json executable = server.command.executable;
    if (executable.empty())
        return server.tool && server.tool->executable == name;
    return executable.substr(executable.find_last_of('/') + 1) == name;
}

// These servers leave their inlay hints off unless the client supplies preferences.
static constexpr Json goInlaySettings = R"({"hints":{"assignVariableTypes":true,"rangeVariableTypes":true,"parameterNames":true,"compositeLiteralFields":true,"compositeLiteralTypes":true,"functionTypeParameters":true}})";
static constexpr Json tsInlayOptions = R"({"preferences":{"includeInlayParameterNameHints":"literals","includeInlayFunctionParameterTypeHints":true,"includeInlayVariableTypeHints":true,"includeInlayPropertyDeclarationTypeHints":true,"includeInlayFunctionLikeReturnTypeHints":true,"includeInlayEnumMemberValueHints":true}})";

static std::string_view Package(const Tool *tool)
{
    return tool ? (tool->package ? tool->package : tool->executable) : "";
}

static bool UsesPackage(const Server &server, std::string_view package)
{
    return server.tool && server.command.executable.empty() && Package(server.tool) == package;
}

static Command ConfiguredCommand(Language language)
{
    return client.host.command ? client.host.command(language) : Command{};
}

static void UpdateDocument(const Document &document)
{
    auto callbacks = document.callbacks;
    if (callbacks.updated)
        callbacks.updated(callbacks.context);
}

static void UpdateState(ServerID id, LSPState state, Json message, Json title = {})
{
    auto *server = FindServer(id);
    if (!server)
        return;
    server->state = state;
    server->status = message;
    server->failureTitle = title;
    VisitDocuments(id, [](const Document &document) { UpdateDocument(document); });
}

static void ClearReport(Diagnostics &report)
{
    report.items.clear();
    ClearBytes(report.bytes);
}

static void ClearDiagnostics(Document &document)
{
    ClearReport(document.pushed);
    ClearReport(document.pulled);
    if (!std::exchange(document.publishedDiagnostics, false))
        return;
    auto callbacks = document.callbacks;
    if (callbacks.diagnosticsChanged)
        callbacks.diagnosticsChanged(callbacks.context, {});
}

static bool SendingChanges(const Document &document, const Server &server)
{
    return document.opened && server.sync > 0;
}

static bool ChangedSinceSave(const Document &document)
{
    return document.opened && document.savedVersion != document.version;
}

static bool AcceptsDiagnostics(const Document &document, const Server &server)
{
    return server.state == LSPState::Ready && document.opened && !document.standaloneRust;
}

static void ScheduleDiagnostics(Document &document)
{
    auto *server = FindServer(document.server);
    if (!server || !AcceptsDiagnostics(document, *server) || !server->pullDiagnostics || document.diagnosticDue != noDeadline)
        return;
    if (document.diagnosticRequest) {
        document.refreshPending = true;
        return;
    }
    document.diagnosticDue = Clock::now() + 120ms;
    WakeAt(document.diagnosticDue);
}

static void AppendText(std::string &message, const Document &document)
{
    auto callbacks = document.callbacks;
    if (callbacks.appendText)
        callbacks.appendText(callbacks.context, message);
    else
        message += R"("")";
}

static LSPPosition DocumentEnd(const Document &document)
{
    auto callbacks = document.callbacks;
    return callbacks.end ? callbacks.end(callbacks.context) : LSPPosition{};
}

static void OpenOnServer(Document &document)
{
    if (document.opened)
        return;
    auto &server = *FindServer(document.server);
    document.opened = true;
    document.sentVersion = document.savedVersion = document.version;
    document.sentEnd = DocumentEnd(document);
    document.standaloneRust = UsesRustAnalyzer(server) && !HasRustProject(File(document));
    if (server.openClose || server.sync) {
        auto &message = ParametersPrefix("textDocument/didOpen");
        message += R"({"textDocument":{"uri":)";
        AppendJsonString(message, URI(document));
        message += R"(,"languageId":)";
        char lowercase[64];
        AppendJsonString(message, LanguageID(document.language, lowercase));
        message += R"(,"version":)";
        AppendNumber(message, document.version);
        message += R"(,"text":)";
        AppendText(message, document);
        message += "}}}";
        SendMessage(server.pipe);
    }
    ScheduleDiagnostics(document);
}

static void ClearChanges(Document &document)
{
    document.changes.clear();
    ClearBytes(document.changeBytes);
    document.fullChange = false;
}

static void CloseOnServer(Document &document)
{
    document.changeDue = noDeadline;
    document.diagnosticDue = noDeadline;
    document.diagnosticRequest = 0;
    document.refreshPending = false;
    ClearChanges(document);
    document.opened = false;
    document.standaloneRust = false;
    document.receivedPushDiagnostics = false;
    ClearDiagnostics(document);
}

static void FlushChanges(Document &document)
{
    document.changeDue = noDeadline;
    auto *server = FindServer(document.server);
    if (!server || !SendingChanges(document, *server) || document.sentVersion == document.version)
        return;
    auto &message = ParametersPrefix("textDocument/didChange");
    message += R"({"textDocument":{"uri":)";
    AppendJsonString(message, URI(document));
    message += R"(,"version":)";
    AppendNumber(message, document.version);
    message += R"(},"contentChanges":[)";
    if (document.fullChange || document.changes.empty()) {
        message += '{';
        if (server->sync == 2) {
            message += R"("range":)";
            AppendRange(message, {}, document.sentEnd);
            message += ',';
        }
        message += R"("text":)";
        AppendText(message, document);
        message += '}';
    } else {
        bool first = true;
        for (const auto &change : document.changes) {
            if (!std::exchange(first, false))
                message += ',';
            message += R"({"range":)";
            AppendRange(message, change.start, change.end);
            message += R"(,"text":)";
            AppendJsonString(message, Json(document.changeBytes).substr(change.offset, change.length));
            message += '}';
        }
    }
    message += "]}}";
    SendMessage(server->pipe);
    ClearChanges(document);
    document.sentVersion = document.version;
    document.sentEnd = DocumentEnd(document);
}

static size_t UTF16Length(Json text)
{
    size_t length = 0;
    for (unsigned char ch : text) {
        if ((ch & 0xc0) != 0x80)
            length += ch >= 0xf0 ? 2 : 1;
    }
    return length;
}

static void PublishDiagnostics(Document &document)
{
    std::array<Json, 2 * maxDiagnostics> seen{};
    bool merging = !document.pushed.items.empty() && !document.pulled.items.empty();
    auto result = std::move(client.diagnosticJSON);
    result.clear();
    size_t characters = 0, count = 0;
    for (const auto *report : {&document.pushed, &document.pulled}) {
        Json bytes = report->bytes;
        for (const auto &item : report->items) {
            if (merging) {
                auto key = bytes.substr(item.key, item.keyLength);
                size_t slot = std::hash<Json>{}(key) % seen.size();
                while (!seen[slot].empty() && seen[slot] != key)
                    slot = (slot + 1) % seen.size();
                if (!seen[slot].empty())
                    continue;
                seen[slot] = key;
            }
            if (count >= maxDiagnostics || characters + item.characters > maxDiagnosticCharacters)
                break;
            result += count++ ? ',' : '[';
            result += bytes.substr(item.at, item.length);
            characters += item.characters;
        }
    }
    if (count)
        result += ']';
    bool hadDiagnostics = std::exchange(document.publishedDiagnostics, count != 0);
    auto callbacks = document.callbacks;
    if ((count || hadDiagnostics) && callbacks.diagnosticsChanged)
        callbacks.diagnosticsChanged(callbacks.context, result);
    ClearBytes(result);
    if (!client.stopping && result.capacity() > client.diagnosticJSON.capacity())
        client.diagnosticJSON.swap(result);
}

static bool AppendDiagnosticKey(std::string &bytes, Json range, Json code)
{
    uint32_t coordinates[4];
    size_t index = 0;
    for (Json end : {"start", "end"}) {
        Json position = JsonField(range, end);
        for (Json axis : {"line", "character"}) {
            auto coordinate = JsonInteger(JsonField(position, axis));
            if (!coordinate || *coordinate < 0 || *coordinate > INT32_MAX)
                return false;
            coordinates[index++] = uint32_t(*coordinate);
        }
    }
    bytes.append(reinterpret_cast<const char *>(coordinates), sizeof(coordinates));
    bytes += code;
    return true;
}

static void ReceiveDiagnostics(Document &document, Json diagnostics, bool pulled)
{
    bool skipCompiler = UsesRustAnalyzer(*FindServer(document.server)) && ChangedSinceSave(document);
    auto &report = client.diagnosticReport;
    ClearReport(report);
    size_t characters = 0;
    Json input = JsonContents(diagnostics);
    std::string messageDecoded, codeDecoded, sourceDecoded;
    for (Json item; !(item = NextJsonValue(input)).empty();) {
        if (!IsObject(item))
            continue;
        Json message, range, source, rawCode, name, value;
        auto fields = JsonContents(item);
        while (NextJsonMember(fields, name, value)) {
            if (JsonNameEquals(name, "message"))
                message = value;
            else if (JsonNameEquals(name, "range"))
                range = value;
            else if (JsonNameEquals(name, "source"))
                source = value;
            else if (JsonNameEquals(name, "code"))
                rawCode = value;
        }
        if (!IsObject(range))
            continue;
        if (skipCompiler) {
            source = TextView(source, sourceDecoded);
            if (source == "rustc" || source == "clippy")
                continue;
        }
        message = TextView(message, messageDecoded);
        if (message.empty())
            continue;
        size_t length = UTF16Length(message);
        auto code = IsString(rawCode) ? TextView(rawCode, codeDecoded) : JsonInteger(rawCode) ? rawCode : Json{};
        Json keyText = code.empty() ? message : code;
        if (report.items.size() == maxDiagnostics || length + characters > maxDiagnosticCharacters ||
            report.bytes.size() + item.size() + keyText.size() + 48 > maxDiagnosticBytes)
            break;
        auto key = uint32_t(report.bytes.size());
        if (!AppendDiagnosticKey(report.bytes, range, keyText))
            continue;
        auto at = uint32_t(report.bytes.size());
        report.bytes += item;
        report.items.push_back({at, uint32_t(item.size()), key, at - key, uint32_t(length)});
        characters += length;
    }
    auto &stored = pulled ? document.pulled : document.pushed;
    bool changed = report.bytes != stored.bytes;
    if (changed)
        std::swap(report, stored);
    ClearReport(report);
    if (changed)
        PublishDiagnostics(document);
}

static void Shutdown(ServerID id, bool immediate)
{
    auto *server = FindServer(id);
    if (!server)
        return;
    uint64_t launch = ++server->launch;
    auto pipe = std::exchange(server->pipe, 0);
    bool graceful = !immediate && server->state == LSPState::Ready;
    server->state = LSPState::Stopped;
    server->capabilities = 0;
    server->triggers.clear();
    server->sync = 0;
    server->resolve = false;
    server->pullDiagnostics = false;
    if (pipe) {
        if (graceful) {
            auto due = Clock::now() + 1s;
            client.retiring.push_back({pipe, due});
            SendPacket(pipe, R"({"jsonrpc":"2.0","id":0,"method":"shutdown"})");
            WakeAt(due);
        } else {
            ClosePipe(pipe);
        }
    }
    auto pending = std::move(server->pending);
    ClearCommand(*server);
    for (const auto &request : pending)
        ReleaseReply(request.reply);
    VisitDocuments(id, [id, launch](Document &document) {
        auto *server = FindServer(id);
        if (server && server->launch == launch)
            CloseOnServer(document);
    });
}

static Document *DocumentForURI(ServerID server, Json uri)
{
    for (auto &document : client.documents) {
        if (document.server == server && URI(document) == uri)
            return &document;
    }
    auto path = CanonicalURIPath(uri);
    if (path.empty())
        return nullptr;
    for (auto &document : client.documents) {
        if (document.server == server && File(document) == path)
            return &document;
    }
    return nullptr;
}

static void SendResponse(PipeID pipe, Json identifier, Json value, bool error = false)
{
    auto &message = client.outgoing;
    message = R"({"jsonrpc":"2.0","id":)";
    message += identifier;
    message += error ? R"(,"error":)" : R"(,"result":)";
    message += value;
    message += '}';
    SendMessage(pipe);
}

static void HandleMessage(ServerID session, PipeID pipe, const Packet &packet)
{
    Json identifier = Field(packet, PacketField::Identifier);
    Json rawMethod = Field(packet, PacketField::Method);
    Json params = Field(packet, PacketField::Parameters);
    auto *server = FindServer(session);
    if (rawMethod.empty()) {
        if (auto id = JsonInteger(identifier)) {
            auto request = TakeRequest(*server, *id);
            if (request.id) {
                std::string decoded;
                Json error = TextView(JsonField(Field(packet, PacketField::Error), "message"), decoded);
                Json result = Field(packet, PacketField::Result);
                FinishPending(session, request, result == "null" ? Json{} : result, error);
            }
        }
        return;
    }

    std::string decoded;
    Json method = TextView(rawMethod, decoded);
    if (method == "textDocument/publishDiagnostics") {
        std::string uriDecoded;
        auto *document = DocumentForURI(session, TextView(JsonField(params, "uri"), uriDecoded));
        auto version = JsonInteger(JsonField(params, "version"));
        auto items = JsonField(params, "diagnostics");
        if (document && AcceptsDiagnostics(*document, *server) && document->sentVersion == document->version &&
            (!version || (*version >= 0 && size_t(*version) == document->version)) && IsArray(items)) {
            // Push diagnostics have no server capability. Keep the local check until the first report.
            bool first = !std::exchange(document->receivedPushDiagnostics, true) && !server->pullDiagnostics;
            DocumentID id = document->id;
            ReceiveDiagnostics(*document, items, false);
            if (first) {
                if (auto *current = FindDocument(id))
                    UpdateDocument(*current);
            }
        }

        return;
    }
    if (identifier.empty())
        return;
    if (method == "workspace/workspaceFolders") {
        SendResponse(pipe, identifier, server->folders);
        return;
    }
    if (method == "workspace/configuration") {
        Json items = JsonField(params, "items");
        items = IsArray(items) ? JsonContents(items) : Json{};
        std::string value = "[";
        std::string decoded;
        for (Json item; !(item = NextJsonValue(items)).empty();) {
            if (value.size() > 1)
                value += ',';
            auto section = TextView(JsonField(item, "section"), decoded);
            value += UsesLanguageTool(*server, "gopls") && (section.empty() || section == "gopls") ?
                goInlaySettings : "null";
        }
        value += ']';
        SendResponse(pipe, identifier, value);
    } else if (method == "workspace/diagnostic/refresh") {
        VisitDocuments(session, [](Document &document) { ScheduleDiagnostics(document); });
        SendResponse(pipe, identifier, "null");
    } else if (method == "workspace/inlayHint/refresh") {
        SendResponse(pipe, identifier, "null");
        VisitDocuments(session, [](Document &document) {
            if (document.callbacks.inlayHintsChanged)
                document.callbacks.inlayHintsChanged(document.callbacks.context);
        });
    } else if (method == "workspace/applyEdit") {
        const auto id = server->commandDocument;
        const auto request = server->commandRequest;
        auto *document = FindDocument(id);
        std::string error = "Apply the edit from a Retina Code action.";
        if (document && document->version == server->commandVersion && server->commandEdit.call) {
            const auto apply = server->commandEdit;
            error = apply.call(apply.context, JsonField(params, "edit"));
            server = FindServer(session);
            document = FindDocument(id);
            if (server && server->commandRequest == request && document)
                server->commandVersion = document->version;
        }
        if (server && server->pipe == pipe) {
            auto value = error.empty() ? R"({"applied":true})" : JsonObject({{"applied", "false"}, {"failureReason", QuoteJson(error)}});
            SendResponse(pipe, identifier, value);
        }
    } else if (method == "window/workDoneProgress/create" || method == "window/showMessageRequest" ||
               method == "client/registerCapability" || method == "client/unregisterCapability") {
        SendResponse(pipe, identifier, "null");
    } else {
        SendResponse(pipe, identifier, R"({"code":-32601,"message":"Method not supported"})", true);
    }
}

static constexpr Json clientCapabilities = R"({
    "general":{"positionEncodings":["utf-16"]},
    "offsetEncoding":["utf-16"],
    "workspace":{
        "configuration":true,"workspaceFolders":true,"applyEdit":true,
        "diagnostics":{"refreshSupport":true},
        "inlayHint":{"refreshSupport":true},
        "workspaceEdit":{"documentChanges":true,"resourceOperations":[]}
    },
    "textDocument":{
        "synchronization":{"didSave":true},
        "inlayHint":{"dynamicRegistration":false},
        "completion":{"contextSupport":true,"completionItem":{
            "snippetSupport":false,"insertReplaceSupport":true,"labelDetailsSupport":true
        }},
        "definition":{"linkSupport":true},
        "hover":{"contentFormat":["markdown","plaintext"]},
        "signatureHelp":{"signatureInformation":{"documentationFormat":["markdown","plaintext"],
            "parameterInformation":{"labelOffsetSupport":true},"activeParameterSupport":true}},
        "diagnostic":{"relatedDocumentSupport":false},
        "publishDiagnostics":{"versionSupport":true},
        "codeAction":{
            "codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","source"]}},
            "dataSupport":true,"resolveSupport":{"properties":["edit","command"]}
        }
    }
})";

static void Initialized(ServerID session, Json result, Json error)
{
    auto *server = FindServer(session);
    if (!server)
        return;
    Json capabilities = JsonField(result, "capabilities");
    std::string decoded;
    Json encoding = TextView(JsonField(capabilities, "positionEncoding"), decoded);
    if (encoding.empty())
        encoding = TextView(JsonField(result, "offsetEncoding"), decoded);
    if (!IsObject(capabilities) || (!encoding.empty() && encoding != "utf-16")) {
        Shutdown(session, true);
        UpdateState(session, LSPState::Failed, error.empty() ? "The server did not negotiate UTF-16 positions." : error);
        return;
    }
    for (size_t i = 0; i < std::size(capabilityNames); ++i) {
        if (Supported(JsonField(capabilities, capabilityNames[i])))
            server->capabilities |= uint16_t(1u << i);
    }
    Json sync = JsonField(capabilities, "textDocumentSync");
    server->sync = unsigned(std::clamp<int64_t>(JsonInteger(IsObject(sync) ? JsonField(sync, "change") : sync).value_or(0), 0, 2));
    server->openClose = IsObject(sync) ? IsTrue(JsonField(sync, "openClose")) : server->sync != 0;
    Json save = JsonField(sync, "save");
    server->save = Supported(save);
    server->saveText = IsTrue(JsonField(save, "includeText"));
    server->resolve = IsTrue(JsonField(JsonField(capabilities, "codeActionProvider"), "resolveProvider"));
    server->pullDiagnostics = Supported(JsonField(capabilities, "diagnosticProvider"));
    Json triggers = JsonField(JsonField(capabilities, "completionProvider"), "triggerCharacters");
    triggers = IsArray(triggers) ? JsonContents(triggers) : Json{};
    for (Json trigger; !(trigger = NextJsonValue(triggers)).empty() && server->triggers.size() < 256;) {
        trigger = TextView(trigger, decoded);
        if (!trigger.empty() && trigger.size() <= 16 && trigger.find('\0') == trigger.npos)
            AppendItem(server->triggers, trigger);
    }
    Notify(*server, "initialized", "{}");
    server->state = LSPState::Ready;
    VisitDocuments(session, OpenOnServer);
    UpdateState(session, LSPState::Ready, "Connected");
}

static void FinishPending(ServerID session, Pending request, Json result, Json error)
{
    auto *server = FindServer(session);
    auto *document = FindDocument(request.document);
    if (request.kind == RequestKind::Initialize) {
        Initialized(session, result, error);
    } else if (request.kind == RequestKind::Command) {
        if (server && server->commandRequest == request.id) {
            ClearCommand(*server);
            ReplyTo(request.reply, result, error);
            return;
        }
    } else if (server && document && document->server == session && document->version == request.version &&
               server->state == LSPState::Ready) {
        if (request.kind == RequestKind::Reply) {
            ReplyTo(request.reply, result, error);
            return;
        }
        document->diagnosticRequest = 0;
        auto items = JsonField(result, "items");
        if (IsArray(items))
            ReceiveDiagnostics(*document, items, true);
        document = FindDocument(request.document);
        if (document && std::exchange(document->refreshPending, false))
            ScheduleDiagnostics(*document);
    }
    ReleaseReply(request.reply);
}

static void InitializeServer(Server &server)
{
    auto params = JsonObject({{"processId", std::to_string(getpid())}, {"clientInfo", R"({"name":"Retina Code"})"},
                              {"rootUri", QuoteJson(FileURI(server.root, true))}, {"rootPath", QuoteJson(server.root)},
                              {"workspaceFolders", server.folders}, {"capabilities", clientCapabilities}});
    Json options;
    if (UsesRustAnalyzer(server))
        options = R"({"diagnostics":{"experimental":{"enable":true}}})";
    else if (UsesLanguageTool(server, "typescript-language-server"))
        options = tsInlayOptions;
    if (!options.empty()) {
        params.pop_back();
        params += R"(,"initializationOptions":)";
        params += options;
        params += '}';
    }
    SendRequest(server, "initialize", params, {.kind = RequestKind::Initialize});
}

static void PipeChanged(PipeID pipe, PipeEvent event, const Packet &packet)
{
    auto server = std::ranges::find(client.servers, pipe, &Server::pipe);
    if (server == client.servers.end()) {
        if (event == PipeEvent::Message && Field(packet, PacketField::Identifier) == "0" && Field(packet, PacketField::Method).empty() &&
            std::ranges::find(client.retiring, pipe, &RetiringPipe::pipe) != client.retiring.end()) {
            SendPacket(pipe, R"({"jsonrpc":"2.0","method":"exit"})");
        }
        return;
    }
    auto id = server->id;
    if (event == PipeEvent::Ready) {
        InitializeServer(*server);
    } else if (event == PipeEvent::Message) {
        HandleMessage(id, pipe, packet);
    } else {
        Shutdown(id, true);
        UpdateState(id, LSPState::Failed, packet.bytes);
    }
}

static ToolOperation *FindOperation(std::string_view package)
{
    for (auto *job : client.tools) {
        if (Package(job->tool) == package)
            return job;
    }
    return nullptr;
}

static bool ToolsDisabled(std::string_view package)
{
    return client.host.toolsDisabled && client.host.toolsDisabled(package);
}

static void SetToolsDisabled(std::string_view package, bool disabled)
{
    if (client.host.setToolsDisabled)
        client.host.setToolsDisabled(package, disabled);
}

static void LocatedServer(void *context)
{
    auto *job = static_cast<LocateTask *>(context);
    auto *server = FindServer(job->server);
    if (server && server->launch == job->launch) {
        if (job->executable.empty()) {
            UpdateState(job->server, job->custom ? LSPState::Failed : LSPState::Missing,
                        job->custom ? "The configured executable could not be opened." : "Language server not installed.");
        } else {
            UpdateState(job->server, LSPState::Starting, "Starting language server…");
            server = FindServer(job->server);
            if (server && server->launch == job->launch) {
                auto environment = LanguageEnvironment(client.paths, server->language);
                ConfigureToolEnvironment(environment, client.paths, server->tool, job->executable);
                server->pipe = StartPipe(job->executable, server->command.arguments, server->root, environment, PipeChanged);
                if (!server->pipe)
                    UpdateState(job->server, LSPState::Failed, "Could not start the language server transport.");
            }
        }
    }
    delete job;
}

static void LocateServer(void *context)
{
    auto *job = static_cast<LocateTask *>(context);
    if (!job->custom)
        job->executable = FindExecutable(job->paths, job->tool, job->language, job->root);
    else if (!IsExecutable(job->executable.c_str()))
        job->executable.clear();
    dispatch_async_f(dispatch_get_main_queue(), job, LocatedServer);
}

static void StartServer(ServerID id)
{
    auto *server = FindServer(id);
    if (!server || client.stopping)
        return;
    uint64_t launch = ++server->launch;
    bool custom = !server->command.executable.empty();
    if (!custom && !server->tool) {
        UpdateState(id, LSPState::Missing, "Choose a language server for this file type.");
        return;
    }
    if (!custom) {
        auto package = Package(server->tool);
        if (auto *job = FindOperation(package)) {
            UpdateState(id, job->removing ? LSPState::Uninstalling : LSPState::Installing,
                        job->removing ? "Uninstalling language tools…" : "Installing language server…");
            return;
        }
        if (ToolsDisabled(package)) {
            UpdateState(id, LSPState::Missing, "Language tools are off.");
            return;
        }
    }
    UpdateState(id, LSPState::Starting, "Finding language server…");
    server = FindServer(id);
    if (server && server->launch == launch) {
        auto *job = new LocateTask{id, launch, server->tool, server->language, custom, client.paths, server->root, server->command.executable};
        dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), job, LocateServer);
    }
}

void Configure(Host host)
{
    StartChildProcesses();
    client.stopping = false;
    client.paths = {std::move(host.home), std::move(host.managedTools)};
    client.host = std::move(host);
}

DocumentID CreateDocument(Json file, Json uri, Json workspace, Language language, DocumentCallbacks callbacks)
{
    auto &document = NewRecord(client.documents);
    std::string discovered;
    if (workspace.empty()) {
        discovered = ProjectRoot(file, language);
        workspace = discovered;
    } else if (language == Language::Odin) {
        discovered = ProjectRoot(file, language);
        auto candidate = Json(discovered);
        std::error_code error;
        if (candidate.starts_with(workspace) && candidate.size() > workspace.size() && candidate[workspace.size()] == '/' &&
            std::filesystem::is_regular_file(std::filesystem::path(discovered) / "ols.json", error))
            workspace = candidate;
    }

    document.names.reserve(file.size() + uri.size() + workspace.size());
    document.names = file;
    document.names += uri;
    document.names += workspace;
    document.uriOffset = file.size();
    document.rootOffset = file.size() + uri.size();
    document.language = language;
    document.callbacks = callbacks;
    return document.id;
}

void DestroyDocument(DocumentID id)
{
    if (auto *document = FindDocument(id)) {
        document->callbacks = {};
        Close(id);
        if ((document = FindDocument(id)))
            *document = {};
    }
}

Json Root(DocumentID id)
{
    auto *document = FindDocument(id);
    return document ? WorkspaceRoot(*document) : Json{};
}

LSPState State(DocumentID id)
{
    auto *server = DocumentServer(id);
    return server ? server->state : LSPState::Missing;
}

Json Status(DocumentID id)
{
    auto *server = DocumentServer(id);
    return server ? Json(server->status) : Json{};
}

Json FailureTitle(DocumentID id)
{
    auto *server = DocumentServer(id);
    return server ? server->failureTitle : Json{};
}

size_t Version(DocumentID id)
{
    auto *document = FindDocument(id);
    return document ? document->version : 0;
}

bool SendingChanges(DocumentID id)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    return server && SendingChanges(*document, *server);
}

bool ChangedSinceSave(DocumentID id)
{
    auto *document = FindDocument(id);
    return document && ChangedSinceSave(*document);
}

bool HandlesDiagnostics(DocumentID id)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    return server && AcceptsDiagnostics(*document, *server) && (server->sync || !ChangedSinceSave(*document)) &&
           (server->pullDiagnostics || document->receivedPushDiagnostics);
}

std::string ServerName(DocumentID id)
{
    auto *document = FindDocument(id);
    auto language = document ? document->language : Language::Plain;
    auto *server = document ? FindServer(document->server) : nullptr;
    auto fallback = server ? Command{} : ConfiguredCommand(language);
    const auto &executable = server ? server->command.executable : fallback.executable;
    if (!executable.empty()) {
        auto slash = executable.find_last_of('/');
        return executable.substr(slash == executable.npos ? 0 : slash + 1);
    }
    auto *tool = ToolForLanguage(language);
    return tool ? tool->executable : "Language Server";
}

bool CanInstall(DocumentID id)
{
    auto *document = FindDocument(id);
    if (!document)
        return false;
    auto *tool = ToolForLanguage(document->language);
    if (!tool || tool->install == InstallKind::None)
        return false;
    auto *server = FindServer(document->server);
    return server ? server->command.executable.empty() : ConfiguredCommand(document->language).executable.empty();
}

bool CanUninstall(DocumentID id)
{
    auto *server = DocumentServer(id);
    return server && server->command.executable.empty() && HasOwnedTools(client.paths, server->tool);
}

bool Supports(DocumentID id, Json capability)
{
    auto *server = DocumentServer(id);
    if (!server || server->state != LSPState::Ready)
        return false;
    auto name = std::ranges::find(capabilityNames, capability);
    return name != std::end(capabilityNames) && (server->capabilities & (1u << (name - capabilityNames)));
}

bool TriggersCompletion(DocumentID id, Json character)
{
    auto *server = DocumentServer(id);
    if (!server || server->state != LSPState::Ready)
        return false;
    Json triggers = server->triggers;
    while (!triggers.empty()) {
        if (NextItem(triggers) == character)
            return true;
    }
    return false;
}

bool ResolvesCodeActions(DocumentID id)
{
    auto *server = DocumentServer(id);
    return server && server->state == LSPState::Ready && server->resolve;
}

void Start(DocumentID id)
{
    auto *document = FindDocument(id);
    if (!document || client.stopping)
        return;
    if (auto *server = FindServer(document->server)) {
        if (server->state == LSPState::Stopped || server->state == LSPState::Failed || server->state == LSPState::Missing)
            StartServer(server->id);
        return;
    }
    auto *tool = ToolForLanguage(document->language);
    auto command = ConfiguredCommand(document->language);
    bool defaultTool = command.executable.empty() && tool;
    auto root = WorkspaceRoot(*document);
    for (auto &server : client.servers) {
        if (!server.id || server.root != root)
            continue;
        bool sameTool = defaultTool ? server.command.executable.empty() && server.tool == tool :
                                      server.language == document->language && server.command.executable == command.executable &&
                                      server.command.arguments == command.arguments;
        if (!sameTool)
            continue;
        document->server = server.id;
        if (server.state == LSPState::Ready)
            OpenOnServer(*document);
        UpdateDocument(*document);
        return;
    }
    auto &server = NewRecord(client.servers);
    server.root = root;
    server.command = std::move(command);
    server.tool = tool;
    server.language = document->language;
    auto name = std::filesystem::path(server.root).filename().string();
    server.folders = "[" + JsonObject({{"uri", QuoteJson(FileURI(server.root, true))}, {"name", QuoteJson(name)}}) + "]";
    if (defaultTool) {
        if (tool->argument)
            AppendItem(server.command.arguments, tool->argument);
        if (tool->secondArgument)
            AppendItem(server.command.arguments, tool->secondArgument);
        if (server.language == Language::Java) {
            AppendItem(server.command.arguments, "-data");
            AppendItem(server.command.arguments, client.paths.managed + "/jdtls/workspaces/" +
                       std::to_string(std::hash<std::string_view>{}(root)));
        }
    }
    document->server = server.id;
    StartServer(server.id);
}

void Restart(DocumentID id)
{
    if (auto *server = DocumentServer(id)) {
        auto session = server->id;
        Shutdown(session, false);
        auto *document = FindDocument(id);
        if (document && document->server == session)
            StartServer(session);
    }
}

void Stop(DocumentID id)
{
    if (auto *server = DocumentServer(id)) {
        auto session = server->id;
        Shutdown(session, false);
        UpdateState(session, LSPState::Stopped, "Language server stopped.");
    }
}

void Close(DocumentID id)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    if (!server)
        return;
    ServerID session = server->id;
    document->server = 0;
    if (document->opened && server->openClose && server->pipe) {
        auto &message = ParametersPrefix("textDocument/didClose");
        AppendDocument(message, *document);
        message += '}';
        SendMessage(server->pipe);
    }
    CloseOnServer(*document);
    while ((server = FindServer(session))) {
        auto request = std::ranges::find(server->pending, id, &Pending::document);
        if (request == server->pending.end())
            break;
        Cancel(*server, request->id);
    }
    if (server && std::ranges::find(client.documents, session, &Document::server) == client.documents.end()) {
        Shutdown(session, false);
        if (auto *unused = FindServer(session))
            *unused = {};
    }
}

void Reconfigure(Language language)
{
    std::vector<DocumentID> documents;
    for (const auto &document : client.documents) {
        if (document.id && document.language == language)
            documents.push_back(document.id);
    }
    for (auto id : documents)
        Close(id);
    for (auto id : documents)
        Start(id);
}

void Changed(DocumentID id, std::optional<Change> change)
{
    auto *document = FindDocument(id);
    if (!document)
        return;
    ++document->version;
    auto *server = FindServer(document->server);
    if (server && document->diagnosticRequest) {
        Cancel(*server, std::exchange(document->diagnosticRequest, 0));
        document->refreshPending = false;
    }
    if (server && SendingChanges(*document, *server)) {
        if (!change || server->sync != 2 || document->changes.size() >= 32 ||
            document->changeBytes.size() + change->text.size() > 16 * 1024 * 1024) {
            ClearChanges(*document);
            document->fullChange = true;
        } else if (!document->fullChange) {
            document->changes.push_back({change->start, change->end, uint32_t(document->changeBytes.size()), uint32_t(change->text.size())});
            document->changeBytes += change->text;
        }
        if (document->changeDue == noDeadline) {
            document->changeDue = Clock::now() + 45ms;
            WakeAt(document->changeDue);
        }
        ScheduleDiagnostics(*document);
    }
    ClearDiagnostics(*document);
}

void Saved(DocumentID id)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    if (!server || server->state != LSPState::Ready || !document->opened)
        return;
    FlushChanges(*document);
    document->savedVersion = document->version;
    if (server->save) {
        auto &message = ParametersPrefix("textDocument/didSave");
        AppendDocument(message, *document);
        message.pop_back();
        if (server->saveText && document->callbacks.appendText) {
            message += R"(,"text":)";
            AppendText(message, *document);
        }
        message += "}}";
        SendMessage(server->pipe);
    }
    ScheduleDiagnostics(*document);
}

int64_t Request(DocumentID id, Json method, Json params, Reply reply)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    if (server && server->state == LSPState::Ready) {
        FlushChanges(*document);
        auto request = SendRequest(*server, method, params, {.document = id, .version = document->version, .reply = reply});
        if (request)
            return request;
    }
    ReleaseReply(reply);
    return 0;
}

int64_t RequestInlayHints(DocumentID id, LSPPosition start, LSPPosition end, Reply reply)
{
    auto *document = FindDocument(id);
    if (!document) {
        ReleaseReply(reply);
        return 0;
    }

    std::string params;
    AppendDocument(params, *document);
    params.pop_back();
    params += R"(,"range":)";
    AppendRange(params, start, end);
    params += '}';
    return Request(id, "textDocument/inlayHint", params, reply);
}

InlayHints ReadInlayHints(Json result)
{
    constexpr size_t maxHints = 768;
    constexpr size_t maxLabel = 256;
    InlayHints hints;
    if (!IsArray(result))
        return hints;

    std::string decoded;
    auto appendLabel = [&](Json value, size_t start) {
        if (!IsString(value) || value.size() > maxLabel * 6 + 2)
            return false;
        auto label = TextView(value, decoded);
        if (hints.labels.size() - start + label.size() > maxLabel)
            return false;
        for (unsigned char ch : label)
            hints.labels += ch < ' ' || ch == 127 ? ' ' : char(ch);
        return true;
    };

    Json items = JsonContents(result);
    for (Json value; hints.items.size() < maxHints && !(value = NextJsonValue(items)).empty();) {
        Json position = JsonField(value, "position");
        auto line = JsonInteger(JsonField(position, "line"));
        auto column = JsonInteger(JsonField(position, "character"));
        if (!line || !column || *line < 0 || *line > UINT32_MAX || *column < 0 || *column > UINT32_MAX)
            continue;

        Json label = JsonField(value, "label");
        size_t start = hints.labels.size();
        bool valid = true;
        if (IsArray(label)) {
            Json parts = JsonContents(label);
            for (Json part; !(part = NextJsonValue(parts)).empty();) {
                if (!appendLabel(JsonField(part, "value"), start)) {
                    valid = false;
                    break;
                }
            }
        } else {
            valid = appendLabel(label, start);
        }

        size_t length = hints.labels.size() - start;
        if (!valid || !length || hints.labels.find_first_not_of(' ', start) == std::string::npos) {
            hints.labels.resize(start);
            continue;
        }
        hints.items.push_back({uint32_t(*line), uint32_t(*column), uint32_t(start), uint32_t(length),
                               IsTrue(JsonField(value, "paddingLeft")), IsTrue(JsonField(value, "paddingRight"))});
    }
    return hints;
}

void CancelRequest(DocumentID id, int64_t request)
{
    if (auto *server = DocumentServer(id))
        Cancel(*server, request, id);
}

void ExecuteCommand(DocumentID id, Json command, ApplyEdit apply, Reply reply)
{
    auto *document = FindDocument(id);
    auto *server = document ? FindServer(document->server) : nullptr;
    if (server && server->state == LSPState::Ready && !server->commandRequest) {
        FlushChanges(*document);
        auto request = SendRequest(*server, "workspace/executeCommand", command,
                                   {.document = id, .kind = RequestKind::Command, .reply = reply});
        if (request) {
            server->commandRequest = request;
            server->commandDocument = id;
            server->commandVersion = document->version;
            server->commandEdit = apply;
            return;
        }
    }
    ReleaseEdit(apply);
    ReplyTo(reply, {}, "The language server is busy.");
}

static void PullDiagnostics(Document &document)
{
    document.diagnosticDue = noDeadline;
    auto *server = FindServer(document.server);
    if (!server || !AcceptsDiagnostics(document, *server) || !server->pullDiagnostics)
        return;
    FlushChanges(document);
    std::string params;
    AppendDocument(params, document);
    document.diagnosticRequest = SendRequest(*server, "textDocument/diagnostic", params,
                                             {.document = document.id, .version = document.version, .kind = RequestKind::Diagnostics});
    if (!document.diagnosticRequest)
        ScheduleDiagnostics(document);
}

static void Tick()
{
    client.timerDue = noDeadline;
    auto now = Clock::now();
    std::erase_if(client.retiring, [now](const RetiringPipe &entry) {
        if (entry.due > now) {
            WakeAt(entry.due);
            return false;
        }
        ClosePipe(entry.pipe);
        return true;
    });
    VisitServers([now](Server &server) {
        auto id = server.id;
        while (auto *current = FindServer(id)) {
            auto expired = std::find_if(current->pending.begin(), current->pending.end(), [now](const Pending &item) { return item.due <= now; });
            if (expired == current->pending.end())
                break;
            auto request = TakeRequest(*current, expired->id);
            SendCancellation(*current, request.id);
            FinishPending(id, request, {}, "The language server didn’t respond.");
        }
        if (auto *current = FindServer(id)) {
            for (const auto &request : current->pending)
                WakeAt(request.due);
        }
    });
    for (auto &document : client.documents) {
        if (!document.server)
            continue;
        if (document.changeDue <= now)
            FlushChanges(document);
        if (document.diagnosticDue <= now)
            PullDiagnostics(document);
        WakeAt(document.changeDue);
        WakeAt(document.diagnosticDue);
    }
}

struct ToolProgress {
    ToolOperation *operation;
    char status[256];
    size_t length;
};

static void ShowProgress(void *context)
{
    auto *update = static_cast<ToolProgress *>(context);
    auto *job = update->operation;
    if (std::ranges::find(client.tools, job) != client.tools.end()) {
        auto package = Package(job->tool);
        VisitServers([&](Server &server) {
            if (UsesPackage(server, package) && server.state == LSPState::Installing)
                UpdateState(server.id, LSPState::Installing, {update->status, update->length});
        });
    }
    delete update;
}

static void FinishedTools(void *context)
{
    auto *job = static_cast<ToolOperation *>(context);
    if (std::erase(client.tools, job)) {
        auto package = Package(job->tool);
        bool success = job->error.empty();
        if (job->removing && !success)
            SetToolsDisabled(package, job->wasDisabled);
        else if (!job->removing && success)
            SetToolsDisabled(package, false);
        VisitServers([&](Server &server) {
            if (!UsesPackage(server, package))
                return;
            if (job->removing && server.state == LSPState::Uninstalling) {
                if (success)
                    UpdateState(server.id, LSPState::Missing, "Language tools uninstalled.");
                else
                    UpdateState(server.id, LSPState::Failed, job->error, "LSP: Uninstall Failed");
            } else if (!job->removing && success && (server.state == LSPState::Installing || server.state == LSPState::Missing)) {
                StartServer(server.id);
            } else if (!job->removing && !success && server.state == LSPState::Installing) {
                if (job->cancelled.load())
                    UpdateState(server.id, LSPState::Missing, "Installation cancelled.");
                else
                    UpdateState(server.id, LSPState::Failed, job->error, "LSP: Install Failed");
            }
        });
    }
    delete job;
}

static void RunToolOperation(void *context)
{
    auto *job = static_cast<ToolOperation *>(context);
    if (job->removing) {
        job->error = RemoveOwnedTools(job->paths, job->tool);
    } else {
        auto progress = [](void *operation, Json status) {
            auto *update = new ToolProgress;
            update->operation = static_cast<ToolOperation *>(operation);
            update->length = std::min(status.size(), sizeof(update->status));
            status.copy(update->status, update->length);
            dispatch_async_f(dispatch_get_main_queue(), update, ShowProgress);
        };
        job->error = InstallTool(job->paths, *job->tool, job->language, job->root, job->cancelled, {job, progress});
    }
    dispatch_async_f(dispatch_get_main_queue(), job, FinishedTools);
}

void Install(DocumentID id)
{
    auto *server = DocumentServer(id);
    if (!server || client.stopping || !server->command.executable.empty() || !server->tool || server->tool->install == InstallKind::None)
        return;
    auto package = Package(server->tool);
    auto *job = FindOperation(package);
    if (job && job->removing)
        return;
    if (!job) {
        job = new ToolOperation{.tool = server->tool, .language = server->language, .paths = client.paths, .root = server->root};
        client.tools.push_back(job);
        dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), job, RunToolOperation);
    }
    UpdateState(server->id, LSPState::Installing, "Preparing installation…");
}

void CancelInstall(DocumentID id)
{
    if (auto *server = DocumentServer(id)) {
        if (auto *job = FindOperation(Package(server->tool)); job && !job->removing)
            job->cancelled.store(true);
    }
}

void Uninstall(DocumentID id)
{
    auto *server = DocumentServer(id);
    if (!server || client.stopping || !server->tool || !server->command.executable.empty())
        return;
    auto package = Package(server->tool);
    if (FindOperation(package) || !HasOwnedTools(client.paths, server->tool))
        return;
    auto *job = new ToolOperation{.tool = server->tool, .language = server->language, .removing = true,
                                  .wasDisabled = ToolsDisabled(package), .paths = client.paths};
    client.tools.push_back(job);
    SetToolsDisabled(package, true);
    VisitServers([&](Server &item) {
        if (UsesPackage(item, package)) {
            auto session = item.id;
            Shutdown(session, true);
            UpdateState(session, LSPState::Uninstalling, "Uninstalling language tools…");
        }
    });
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), job, RunToolOperation);
}

void StopAll()
{
    if (client.stopping)
        return;
    client.stopping = true;
    for (auto *job : client.tools)
        job->cancelled.store(true);
    client.tools.clear();
    StopChildProcesses();
    StopPipes();
    VisitServers([](Server &server) { Shutdown(server.id, true); });
    for (auto &document : client.documents)
        document.server = 0;
    client.servers = {};
    client.retiring = {};
    client.outgoing = {};
    client.diagnosticReport = {};
    client.diagnosticJSON = {};
    if (client.timer) {
        dispatch_source_cancel(client.timer);
        dispatch_release(std::exchange(client.timer, nullptr));
    }
    client.timerDue = noDeadline;
}

} // namespace lsp