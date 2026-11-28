// Running a file, for both frontends. See Run.hpp. The recipes at the end read top to bottom: each one finds its
// tools, builds, and runs, and stops at the first step that fails with a line saying why.

#include "Run.hpp"
#include "LSPJson.hpp"
#include "RunTools.hpp"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
static const bool RUN_ON_WINDOWS = true;
static const char PATH_LIST_SEPARATOR = ';';
#else
#include <unistd.h>
static const bool RUN_ON_WINDOWS = false;
static const char PATH_LIST_SEPARATOR = ':';
#endif

namespace fs = std::filesystem;

static const size_t CAPTURE_LIMIT = 8 * 1024 * 1024;    // the most a CHILD_CAPTURE child's output keeps
static const size_t JSON_LINE_LIMIT = 2 * 1024 * 1024;  // the longest JSON record from cargo or rustc
static const size_t PARTIAL_LINE_LIMIT = 16 * 1024;     // a line without its end this long shows anyway

//
// Files. Paths are UTF-8 everywhere in the job.
//

static fs::path fs_path(std::string_view path)
{
    return fs::path(std::u8string_view(reinterpret_cast<const char8_t *>(path.data()), path.size()));
}

static std::string utf8_path(const fs::path &path)
{
    std::u8string text = path.lexically_normal().u8string();
    return std::string(reinterpret_cast<const char *>(text.data()), text.size());
}

static std::string join_path(std::string_view folder, std::string_view name)
{
    return utf8_path(fs_path(folder) / fs_path(name));
}

// A path from a folder, or the path itself when it's absolute, with no "." or ".." left in it.
static std::string absolute_path(std::string_view folder, std::string_view path)
{
    std::error_code error;
    fs::path absolute = fs::absolute(fs_path(folder) / fs_path(path), error);
    return error ? join_path(folder, path) : utf8_path(absolute);
}

static std::string parent_folder(std::string_view path)
{
    return utf8_path(fs_path(path).parent_path());
}

static std::string file_name(std::string_view path)
{
    return utf8_path(fs_path(path).filename());
}

// A file's extension without its dot, in lowercase when lower is set.
static std::string file_extension(std::string_view path, bool lower)
{
    std::string extension = utf8_path(fs_path(path).extension());
    if (!extension.empty())
        extension.erase(0, 1);
    if (lower) {
        for (char &ch : extension)
            ch = ch >= 'A' && ch <= 'Z' ? char(ch - 'A' + 'a') : ch;
    }
    return extension;
}

static bool is_file(std::string_view path)
{
    std::error_code error;
    return !path.empty() && fs::is_regular_file(fs_path(path), error);
}

static bool same_file(std::string_view a, std::string_view b)
{
    std::error_code error;
    return !a.empty() && !b.empty() && fs::equivalent(fs_path(a), fs_path(b), error);
}

// Whether a path is inside a folder, or is the folder.
static bool path_in_folder(std::string_view path, std::string_view folder)
{
    if (folder.empty())
        return false;
    fs::path relative = fs_path(path).lexically_normal().lexically_relative(fs_path(folder).lexically_normal());
    return !relative.empty() && *relative.begin() != "..";
}

static bool is_executable(const std::string &path)
{
    if (!is_file(path))
        return false;
#ifdef _WIN32
    return true;
#else
    return access(path.c_str(), X_OK) == 0;
#endif
}

static std::string environment_variable(const char *name)
{
#ifdef _WIN32
    wchar_t wide_name[64];
    std::string result;
    if (!MultiByteToWideChar(CP_UTF8, 0, name, -1, wide_name, 64))
        return result;
    DWORD size = GetEnvironmentVariableW(wide_name, nullptr, 0);
    std::wstring value(size, L'\0');
    DWORD count = size ? GetEnvironmentVariableW(wide_name, value.data(), size) : 0;
    if (!count || count >= size)
        return result;
    result.resize(size_t(count) * 3);
    result.resize(size_t(WideCharToMultiByte(CP_UTF8, 0, value.data(), int(count), result.data(), int(result.size()), nullptr, nullptr)));
    return result;
#else
    const char *value = getenv(name);
    return value ? value : "";
#endif
}

static std::string home_folder()
{
    return environment_variable(RUN_ON_WINDOWS ? "USERPROFILE" : "HOME");
}

// The program a name runs in a folder: the name itself, or on Windows the name with an extension from PATHEXT.
static std::string executable_in(std::string_view folder, std::string_view name)
{
    std::string path = join_path(folder, name);
    if (is_executable(path) && (!RUN_ON_WINDOWS || !file_extension(path, false).empty()))
        return path;
    if (!RUN_ON_WINDOWS)
        return std::string();

    std::string extensions = environment_variable("PATHEXT");
    if (extensions.empty())
        extensions = ".COM;.EXE;.BAT;.CMD";
    std::string_view list = extensions;
    while (!list.empty()) {
        size_t end = std::min(list.find(';'), list.size());
        std::string candidate = path;
        candidate += list.substr(0, end);
        list.remove_prefix(std::min(end + 1, list.size()));
        if (candidate.size() > path.size() && is_executable(candidate))
            return candidate;
    }
    return std::string();
}

// The first program a name runs in a list of folders like PATH. On Windows, folders under WindowsApps are left out
// when skip_store is set: the Microsoft Store puts stand-ins there for python and py that open the Store.
static std::string executable_on_path(std::string_view folders, std::string_view name, bool skip_store)
{
    while (!folders.empty()) {
        size_t end = std::min(folders.find(PATH_LIST_SEPARATOR), folders.size());
        std::string_view folder = folders.substr(0, end);
        folders.remove_prefix(std::min(end + 1, folders.size()));
        if (folder.size() >= 2 && folder.front() == '"' && folder.back() == '"')
            folder = folder.substr(1, folder.size() - 2);
        if (folder.empty())
            continue;
        if (skip_store) {
            std::string lower(folder);
            for (char &ch : lower)
                ch = ch == '\\' ? '/' : ch >= 'A' && ch <= 'Z' ? char(ch - 'A' + 'a') : ch;
            if (lower.find("/microsoft/windowsapps") != std::string::npos)
                continue;
        }

        std::string program = executable_in(folder, name);
        if (!program.empty())
            return program;
    }
    return std::string();
}

// Looks for a file with a name in a folder and each folder above it, up to limit or the root.
static std::string find_parent_file(std::string_view folder, std::string_view limit, std::string_view name)
{
    fs::path at = fs_path(folder).lexically_normal();
    fs::path stop = fs_path(limit).lexically_normal();
    for (;;) {
        std::string candidate = utf8_path(at / fs_path(name));
        if (is_file(candidate))
            return candidate;
        if (at == stop || !at.has_relative_path())
            return std::string();
        at = at.parent_path();
    }
}

static bool write_file(std::string_view path, std::string_view bytes)
{
    std::ofstream file(fs_path(path), std::ios::binary | std::ios::trunc);
    file.write(bytes.data(), std::streamsize(bytes.size()));
    file.close();
    return bool(file);
}

// A name no file in a folder has yet: the prefix, six letters, and the suffix.
static std::string unused_name(std::string_view folder, std::string_view prefix, std::string_view suffix)
{
    static uint32_t seed = uint32_t(std::chrono::steady_clock::now().time_since_epoch().count());
    for (int attempt = 0; attempt < 100; ++attempt) {
        std::string name(prefix);
        for (int index = 0; index < 6; ++index) {
            seed = seed * 1664525u + 1013904223u;
            name += char('a' + (seed >> 16) % 26);
        }
        name += suffix;
        std::string path = join_path(folder, name);
        std::error_code error;
        if (!fs::exists(fs_path(path), error))
            return path;
    }
    return std::string();
}

//
// Text.
//

static uint32_t utf16_length(std::string_view text)
{
    uint32_t length = 0;
    for (unsigned char byte : text)
        length += (byte & 0xC0) != 0x80 ? (byte >= 0xF0 ? 2 : 1) : 0;
    return length;
}

// Adds arguments to a list of them, each followed by a NUL.
static void add_arguments(std::string &arguments, std::initializer_list<std::string_view> list)
{
    for (std::string_view argument : list) {
        arguments += argument;
        arguments += '\0';
    }
}

static std::string json_text(lsp::Json object, std::string_view name)
{
    lsp::Json value = lsp::JsonField(object, name);
    return lsp::IsString(value) ? lsp::DecodeJsonString(lsp::JsonContents(value)) : std::string();
}

static uint32_t json_number(lsp::Json object, std::string_view name)
{
    std::optional<int64_t> number = lsp::JsonInteger(lsp::JsonField(object, name));
    return number && *number > 0 && *number < INT32_MAX ? uint32_t(*number) : 0;
}

// Whether a JSON array of strings holds a string.
static bool json_array_has(lsp::Json array, std::string_view text)
{
    lsp::Json items = lsp::IsArray(array) ? lsp::JsonContents(array) : lsp::Json();
    while (!items.empty()) {
        lsp::Json item = lsp::NextJsonValue(items);
        if (lsp::IsString(item) && lsp::DecodeJsonString(lsp::JsonContents(item)) == text)
            return true;
    }
    return false;
}

//
// The log.
//

static void notify_if_needed(RunJob &job)
{
    if (job.notified)
        return;
    job.notified = true;
    notify_run_output(job);
}

// Drops the oldest messages once the log holds twice what the scrollback keeps, down to what it keeps.
static void trim_log(RunLog &log)
{
    size_t line_limit = outputScrollbackLines;
    size_t byte_limit = outputScrollbackCharacters * 2;
    if (log.messages.size() <= 2 * line_limit && log.text.size() <= 2 * byte_limit)
        return;

    size_t first = log.messages.size() > line_limit ? log.messages.size() - line_limit : 0;
    while (first < log.messages.size() && log.text.size() - log.messages[first].text_start > byte_limit)
        ++first;
    if (first == log.messages.size())
        --first;

    uint32_t text_start = log.messages[first].text_start;
    uint32_t spans_start = log.messages[first].spans_start;
    log.messages.erase(log.messages.begin(), log.messages.begin() + ptrdiff_t(first));
    log.text.erase(0, text_start);
    log.spans.erase(log.spans.begin(), log.spans.begin() + spans_start);
    for (RunMessage &message : log.messages) {
        message.text_start -= text_start;
        message.spans_start -= spans_start;
        if (message.file_length)
            message.file_start -= text_start;
    }
    log.discarded = true;
}

// Adds a message with its text, colors, and the file its link opens, then lets the frontend know.
static void append_message(RunLog &log, RunMessage message, std::string_view text, const OutputColorSpan *spans, size_t span_count,
                           std::string_view file)
{
    message.text_start = uint32_t(log.text.size());
    message.text_length = uint32_t(text.size());
    log.text += text;
    message.file_start = uint32_t(log.text.size());
    message.file_length = uint32_t(file.size());
    log.text += file;
    message.spans_start = uint32_t(log.spans.size());
    message.span_count = uint32_t(span_count);
    log.spans.insert(log.spans.end(), spans, spans + span_count);
    log.messages.push_back(message);
    trim_log(log);
}

static void add_message(RunJob &job, RunMessage message, std::string_view text, const OutputColorSpan *spans, size_t span_count,
                        std::string_view file)
{
    if (text.empty())
        return;

    std::lock_guard lock(job.mutex);
    append_message(job.log, message, text, spans, span_count, file);
    notify_if_needed(job);
}

void log_status(RunJob &job, std::string_view text, OutputTone tone)
{
    RunMessage message = {};
    message.tone = tone;
    add_message(job, message, text, nullptr, 0, std::string_view());
}

void take_run_log(RunJob &job, RunLog &into)
{
    std::lock_guard lock(job.mutex);
    std::swap(job.log, into);
    job.log.text.clear();
    job.log.spans.clear();
    job.log.messages.clear();
    job.log.discarded = false;
    job.notified = false;
    into.input_open = job.input_open;
    into.finished = job.finished;
}

//
// Reading what children write.
//

// The diagnostic in a compiler's line, or a traceback's, made into a link, with the file that ran named by its tab:
// "name:line:column: severity: details". Returns false when the line names no place.
static bool read_diagnostic(RunJob &job, std::string_view text, bool error_stream, RunMessage &message, std::string &file)
{
    CompilerFormat format = job.msvc ? CompilerFormat::Parenthesized : job.format;
    CompilerLocation match = {};
    bool python = job.language == Language::Python;
    bool runtime = job.runtime_locations && error_stream && ParseRuntimeLocation(text, python, match);
    if (!runtime && !ParseCompilerLocation(text, format, match))
        return false;
    if (!runtime && job.language != Language::Rust)
        message.tone = match.tone;
    if (match.path.empty() || match.path.starts_with('<') || !match.line || match.line > INT32_MAX || match.column > INT32_MAX)
        return false;

    std::string_view named = match.path;
    if (named.starts_with("file://"))
        named.remove_prefix(7);
    std::string path = absolute_path(job.diagnostic_folder, named);
    bool current = same_file(path, job.input_path) || path == utf8_path(fs_path(job.input_path));
    if (!current && !is_file(path))
        return false;

    message.current_source = current;
    message.line = uint32_t(match.line);
    message.column = uint32_t(match.column);
    // JavaScript's tracebacks count UTF-16 units, and cl counts characters.
    message.columns = runtime && is_javascript_family(job.language) ? RUN_COLUMN_UTF16 : job.msvc ? RUN_COLUMN_CHARACTERS : job.columns;
    if (!current)
        file = path;

    std::string &line = job.line;
    std::vector<OutputColorSpan> &spans = job.decoded.spans;
    uint32_t text_length = utf16_length(text) - uint32_t(text.ends_with('\n'));
    if (runtime) {
        // A traceback line keeps its words, and links from the path to the line's end.
        size_t at = text.find(match.path);
        if (at == std::string_view::npos)
            return true;
        uint32_t start = utf16_length(text.substr(0, at));
        uint32_t path_length = utf16_length(match.path);
        line.assign(text);
        if (current && !job.name.empty()) {
            line.replace(at, match.path.size(), job.name);
            ShiftOutputColors(spans, {start, path_length}, utf16_length(job.name));
            text_length = text_length - path_length + utf16_length(job.name);
        }
        message.link_start = start;
        message.link_length = text_length - start;
        return true;
    }

    // A compiler's line starts again with the place, then the severity when the format leaves it out. A compiler's
    // error, unlike a traceback, means a script's tool couldn't build it.
    job.build_error |= message.tone == OutputTone::Error;
    std::string_view details = text.substr(std::min(match.details, text.size()));
    line.assign(current && !job.name.empty() ? std::string_view(job.name) : match.path);
    line += ':';
    line += std::to_string(match.line);
    if (match.column) {
        line += ':';
        line += std::to_string(match.column);
    }
    line += ": ";
    if (match.addSeverity) {
        line += match.tone == OutputTone::Warning ? "warning: " : match.tone == OutputTone::Text ? "note: " : "error: ";
    }
    uint32_t prefix = utf16_length(text) - utf16_length(details);
    uint32_t replacement = utf16_length(line);
    line += details;
    ShiftOutputColors(spans, {0, prefix}, replacement);
    message.link_start = 0;
    message.link_length = utf16_length(line) - uint32_t(line.ends_with('\n'));
    return true;
}

// rustc's diagnostic as JSON: its rendered text in its colors, linked from the place it names.
static void read_rust_diagnostic(RunJob &job, lsp::Json diagnostic)
{
    std::string level = json_text(diagnostic, "level");
    std::string details = json_text(diagnostic, "message");
    if (level.empty() || details.empty())
        return;

    RunMessage message = {};
    message.tone = level == "warning" ? OutputTone::Warning : level == "error" || level == "failure-note" ? OutputTone::Error : OutputTone::Text;
    std::string rendered = json_text(diagnostic, "rendered");
    ClearDecodedOutput(job.decoded);
    TerminalDecoder decoder = {};
    DecodeTerminal(decoder, rendered, job.decoded);
    std::string &line = job.line;
    line = job.decoded.text;
    message.colored = decoder.sawSGR;
    if (line.empty()) {
        line = level + ": " + details + "\n";
        message.colored = false;
        job.decoded.spans.clear();
    } else if (!line.ends_with('\n')) {
        line += '\n';
    }
    job.build_error |= message.tone == OutputTone::Error;

    // The primary span is the place.
    lsp::Json spans = lsp::JsonField(diagnostic, "spans");
    lsp::Json items = lsp::IsArray(spans) ? lsp::JsonContents(spans) : lsp::Json();
    lsp::Json primary;
    while (!items.empty()) {
        lsp::Json span = lsp::NextJsonValue(items);
        if (lsp::JsonField(span, "is_primary") == "true") {
            primary = span;
            break;
        }
    }
    std::string named = json_text(primary, "file_name");
    std::string file;
    if (!named.empty() && named.front() != '<') {
        std::string path = absolute_path(job.diagnostic_folder, named);
        if (!fs_path(named).is_absolute() && !is_file(path) && !job.manifest_folder.empty())
            path = absolute_path(job.manifest_folder, named);
        message.line = json_number(primary, "line_start");
        message.column = json_number(primary, "column_start");
        message.columns = RUN_COLUMN_CHARACTERS;
        message.current_source = same_file(path, job.input_path);
        if (!message.current_source)
            file = path;

        // The link covers the "--> path:line:column" under the message, with the tab's name for the file that ran.
        std::string place = named + ':' + std::to_string(message.line) + ':' + std::to_string(message.column);
        size_t arrow = line.find("--> " + place + "\n");
        if (arrow == std::string::npos)
            arrow = line.find("::: " + place + "\n");
        if (arrow != std::string::npos) {
            uint32_t start = utf16_length(std::string_view(line).substr(0, arrow + 4));
            uint32_t length = utf16_length(place);
            if (message.current_source && !job.name.empty()) {
                line.replace(arrow + 4, named.size(), job.name);
                ShiftOutputColors(job.decoded.spans, {start, utf16_length(named)}, utf16_length(job.name));
                length = length - utf16_length(named) + utf16_length(job.name);
            }
            message.link_start = start;
            message.link_length = length;
        } else {
            message.link_start = 0;
            message.link_length = utf16_length(std::string_view(line).substr(0, line.find('\n')));
        }
        if (!message.line)
            message.link_length = 0;
    }
    add_message(job, message, line, job.decoded.spans.data(), job.decoded.spans.size(), file);
}

// A line, or the start of one when it doesn't end with a line break, in its terminal colors or the tone its words
// give it, and as a link when it's a diagnostic.
static void emit_line(RunJob &job, RunStream &stream, std::string_view bytes, bool error_stream)
{
    ClearDecodedOutput(job.decoded);
    DecodeTerminal(stream.decoder, bytes, job.decoded);
    std::string_view text = job.decoded.text;

    // cl writes in the console's code page.
#ifdef _WIN32
    std::string converted;
    if (job.msvc && job.child_kind == CHILD_TOOL) {
        bool valid = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0) > 0;
        if (!valid && !text.empty()) {
            std::wstring wide(text.size(), L'\0');
            int count = MultiByteToWideChar(CP_ACP, 0, text.data(), int(text.size()), wide.data(), int(wide.size()));
            converted.resize(size_t(count) * 3);
            converted.resize(size_t(WideCharToMultiByte(CP_UTF8, 0, wide.data(), count, converted.data(), int(converted.size()), nullptr, nullptr)));
            text = converted;
        }
    }
#endif
    if (text.empty())
        return;

    RunMessage message = {};
    message.colored = stream.decoder.sawSGR;
    message.tone = stream.continued ? OutputTone::Text : ConsoleTone(text, error_stream);
    std::string file;
    bool linked = job.diagnostics && !stream.continued && read_diagnostic(job, text, error_stream, message, file);
    if (linked && message.link_length)
        text = job.line;
    add_message(job, message, text, job.decoded.spans.data(), job.decoded.spans.size(), file);
    stream.continued = !bytes.ends_with('\n');
}

// cargo's JSON record: the build's end, a compiler's diagnostic, or a line of the build script's own.
static bool read_cargo_record(RunJob &job, std::string_view bytes)
{
    lsp::Json record = bytes;
    while (!record.empty() && (record.back() == '\n' || record.back() == '\r'))
        record.remove_suffix(1);
    std::string reason = lsp::IsObject(record) ? json_text(record, "reason") : std::string();
    if (reason == "build-finished") {
        job.cargo_json = false;
        job.cargo_built = lsp::JsonField(record, "success") == "true";
        if (job.cargo_built) {
            log_status(job, "Build successful\n\n", OutputTone::Text);
            std::lock_guard lock(job.mutex);
            job.input_open = true;
            notify_if_needed(job);
        }
        return false;
    }
    if (reason == "compiler-message") {
        std::string manifest = json_text(record, "manifest_path");
        job.manifest_folder = manifest.empty() ? std::string() : parent_folder(manifest);
        read_rust_diagnostic(job, lsp::JsonField(record, "message"));
    } else if (reason.empty()) {
        emit_line(job, job.streams[0], bytes, false);
    }
    return true;
}

struct LineReader {
    RunJob *job;
    int stream;
};

static bool read_line(void *context, std::string_view line)
{
    LineReader &reader = *static_cast<LineReader *>(context);
    RunJob &job = *reader.job;
    if (reader.stream == 0 && job.cargo_json)
        return read_cargo_record(job, line);
    if (reader.stream == 1 && job.rust_json && line.starts_with('{')) {
        read_rust_diagnostic(job, line);
        return true;
    }
    emit_line(job, job.streams[reader.stream], line, reader.stream == 1);
    return true;
}

// A script says it runs as it starts, in the same update that opens its input, so what's typed after the line shows
// reaches the program.
void child_started(RunJob &job)
{
    if (job.child_kind != CHILD_PROGRAM || job.cargo_json)
        return;

    std::lock_guard lock(job.mutex);
    if (job.announce_program) {
        RunMessage message = {};
        append_message(job.log, message, "Running...\n", nullptr, 0, std::string_view());
    }
    job.input_open = true;
    notify_if_needed(job);
}

void child_output(RunJob &job, int stream, std::string_view bytes)
{
    if (job.child_kind == CHILD_QUIET && stream == 1)
        return;
    if ((job.child_kind == CHILD_CAPTURE || job.child_kind == CHILD_QUIET) && stream == 0) {
        job.capture.append(bytes.substr(0, CAPTURE_LIMIT - std::min(CAPTURE_LIMIT, job.capture.size())));
        return;
    }

    RunStream &output = job.streams[stream];
    LineReader reader = {&job, stream};
    bool json = (stream == 0 && job.cargo_json) || (stream == 1 && job.rust_json);
    std::string_view rest = ReadRunRecords(output.records, bytes, json ? JSON_LINE_LIMIT : SIZE_MAX, read_line, &reader);
    if (!rest.empty())
        ReadRunRecords(output.records, rest, SIZE_MAX, read_line, &reader);
    if (output.records.discarded) {
        output.records.discarded = false;
        log_status(job, "[Overlong output line omitted]\n", OutputTone::Text);
    }

    // A long line without its end shows as far as it goes.
    if (!json && output.records.partial.size() >= PARTIAL_LINE_LIMIT) {
        size_t count = CompleteUTF8Prefix(output.records.partial);
        emit_line(job, output, std::string_view(output.records.partial).substr(0, count), stream == 1);
        output.records.partial.erase(0, count);
    }
}

// A prompt the program wrote without a line break shows while it waits for input.
void child_idle(RunJob &job)
{
    if (job.child_kind != CHILD_PROGRAM)
        return;

    for (int index = 0; index < 2; ++index) {
        RunStream &stream = job.streams[index];
        size_t count = CompleteUTF8Prefix(stream.records.partial);
        if (!count || (index == 0 && job.cargo_json))
            continue;
        emit_line(job, stream, std::string_view(stream.records.partial).substr(0, count), index == 1);
        stream.records.partial.erase(0, count);
    }
}

bool take_child_input(RunJob &job, std::string &bytes, bool &close)
{
    std::lock_guard lock(job.mutex);
    bytes.swap(job.typed);
    job.typed.clear();
    close = job.end_of_input;
    if (close)
        job.input_open = false;
    return !bytes.empty() || close;
}

//
// Running children.
//

// Runs a child, then shows the end of what it wrote without a line break, and closes the program's input.
static int run_step(RunJob &job, std::string_view program, const std::string &arguments, std::string_view folder, RunChildKind kind,
                    std::string_view input = std::string_view())
{
    job.child_kind = kind;
    job.capture.clear();
    int code = run_child(job, {program, arguments, folder, input, kind});

    for (int index = 0; index < 2; ++index) {
        RunStream &stream = job.streams[index];
        if (!stream.records.partial.empty() && kind != CHILD_QUIET && !(kind == CHILD_CAPTURE && index == 0)) {
            stream.records.partial += '\n';
            emit_line(job, stream, stream.records.partial, index == 1);
        }
        stream = RunStream();
    }

    std::lock_guard lock(job.mutex);
    if (job.input_open) {
        job.input_open = false;
        notify_if_needed(job);
    }
    job.typed.clear();
    job.end_of_input = false;
    return code;
}

// What run_job() reports after the program: the program's exit, unless it crashed or the job stopped.
static void run_program(RunJob &job, std::string_view program, const std::string &arguments, std::string_view folder, bool diagnostics)
{
    job.diagnostics = diagnostics;
    job.build_error = false;
    int code = run_step(job, program, arguments, folder, CHILD_PROGRAM);
    if (code == CHILD_CRASHED && !job.stop)
        log_status(job, "The process crashed.\n", OutputTone::Error);
    else if (code > 0 && diagnostics && job.build_error)
        log_status(job, "Build failed.\n", OutputTone::Error);
    else
        job.exit_code = code;
}

static bool build_program(RunJob &job, std::string_view tool, const std::string &arguments, std::string_view folder)
{
    log_status(job, "Building...\n", OutputTone::Text);
    job.diagnostics = true;
    int code = run_step(job, tool, arguments, folder, CHILD_TOOL);
    job.diagnostics = false;
    if (job.stop)
        return false;
    if (code) {
        log_status(job, "Build failed.\n", OutputTone::Error);
        return false;
    }
    log_status(job, "Build successful\n\n", OutputTone::Text);
    return true;
}

//
// Tools.
//

// Where a tool is: on PATH, or in the folders its language installs to, or on macOS and Linux in the system's
// folders, which an app started from the desktop may not have on PATH. A tool found outside PATH gets its folder
// added to PATH for the job's children, so the tool finds its neighbors.
static std::string find_tool(RunJob &job, std::string_view name, Language language)
{
    std::string program = executable_on_path(environment_variable("PATH"), name, false);
    if (!program.empty())
        return program;

    std::string home = home_folder();
    std::vector<std::string> folders;
    if (language == Language::Rust) {
        std::string cargo = environment_variable("CARGO_HOME");
        if (!cargo.empty())
            folders.push_back(join_path(cargo, "bin"));
        folders.push_back(join_path(home, ".cargo/bin"));
    }
    if (language == Language::Go)
        folders.push_back(RUN_ON_WINDOWS ? "C:/Program Files/Go/bin" : "/usr/local/go/bin");
    if (language == Language::Odin) {
        std::string root = environment_variable("ODIN_ROOT");
        if (!root.empty())
            folders.push_back(root);
        folders.push_back(join_path(home, "opt/odin"));
        folders.push_back(join_path(home, "bin"));
    }
    if (language == Language::VisualBasic || language == Language::CSharp || language == Language::FSharp) {
        folders.push_back(join_path(home, ".dotnet"));
        if (!RUN_ON_WINDOWS) {
            folders.push_back("/usr/local/share/dotnet");
            folders.push_back("/Library/Frameworks/Mono.framework/Versions/Current/Commands");
        }
    }
    if (!RUN_ON_WINDOWS) {
        folders.push_back(join_path(home, ".local/bin"));
        folders.push_back("/opt/homebrew/bin");
        folders.push_back("/usr/local/bin");
        folders.push_back("/usr/bin");
        folders.push_back("/bin");
    }

    for (const std::string &folder : folders) {
        program = executable_in(folder, name);
        if (program.empty())
            continue;
        if (!job.extra_path.empty())
            job.extra_path += PATH_LIST_SEPARATOR;
        job.extra_path += utf8_path(fs_path(program).parent_path());
        return program;
    }
    return std::string();
}

// A tool, or a line saying it wasn't found.
static std::string get_tool(RunJob &job, std::string_view name, Language language)
{
    std::string tool = find_tool(job, name, language);
    if (tool.empty()) {
        std::string text(name);
        text += " was not found. Install it or add it to PATH.\n";
        log_status(job, text, OutputTone::Error);
    }
    return tool;
}

// Python: a virtual environment's in the folder, or on Windows the py launcher, which takes -3, or python. Windows
// Python writes UTF-8 only with -X utf8.
static std::string find_python(RunJob &job, std::string_view folder, std::string &arguments)
{
    const char *environments[] = {RUN_ON_WINDOWS ? ".venv/Scripts" : ".venv/bin", RUN_ON_WINDOWS ? "venv/Scripts" : "venv/bin"};
    std::string program;
    for (const char *environment : environments) {
        if (program.empty() && !folder.empty())
            program = executable_in(join_path(folder, environment), "python");
    }
    if (RUN_ON_WINDOWS) {
        std::string path = environment_variable("PATH");
        if (program.empty()) {
            program = executable_on_path(path, "py", true);
            if (!program.empty())
                add_arguments(arguments, {"-3"});
        }
        if (program.empty())
            program = executable_on_path(path, "python", true);
        add_arguments(arguments, {"-X", "utf8"});
    }
    if (program.empty())
        program = find_tool(job, "python3", Language::Python);
    if (program.empty())
        log_status(job, "python3 was not found. Install it or add it to PATH.\n", OutputTone::Error);
    return program;
}

// tsx from a node_modules folder above the file, up to the workspace, or else from PATH.
static std::string find_tsx(RunJob &job, std::string_view folder, std::string_view workspace)
{
    fs::path at = fs_path(folder).lexically_normal();
    fs::path stop = fs_path(workspace).lexically_normal();
    while (!folder.empty()) {
        std::string tool = executable_in(utf8_path(at / "node_modules" / ".bin"), "tsx");
        if (!tool.empty())
            return tool;
        if (at == stop || !at.has_relative_path())
            break;
        at = at.parent_path();
    }
    return get_tool(job, "tsx", Language::TypeScript);
}

static bool make_temporary_folder(RunJob &job)
{
    if (!job.temporary.empty())
        return true;

    std::error_code error;
    std::string folder = unused_name(utf8_path(fs::temp_directory_path(error)), "retina-code-", "");
    if (!folder.empty() && fs::create_directory(fs_path(folder), error)) {
        job.temporary = folder;
        return true;
    }
    log_status(job, "A temporary folder could not be made.\n", OutputTone::Error);
    return false;
}

// The draft, written next to the file so its includes and imports still resolve, or else into the temporary folder:
// for text never saved, and for Go and .NET, whose tools would read the other files beside it.
static bool write_draft(RunJob &job, std::string_view folder, std::string_view suffix)
{
    std::string path;
    if (!folder.empty()) {
        std::string prefix = ".retina-code-";
        path = unused_name(folder, prefix, suffix);
        if (!path.empty() && write_file(path, job.draft))
            job.snapshot = path;
        else
            path.clear();
    }
    if (path.empty()) {
        if (!make_temporary_folder(job))
            return false;
        path = join_path(job.temporary, "main");
        path += suffix;
        if (!write_file(path, job.draft)) {
            log_status(job, "The file could not be written for the run.\n", OutputTone::Error);
            return false;
        }
    }
    job.input_path = path;
    return true;
}

#ifdef _WIN32
// A C or C++ compiler on Windows, and the environment it builds in when that isn't the app's.
struct WindowsCompiler {
    std::string program;
    std::string environment;
    bool msvc;
    bool searched;
};

static std::mutex windows_compilers_mutex;
static WindowsCompiler windows_compilers[2];    // C, then C++
static WindowsCompiler msvc_compiler;

// Whether a file is in one of the folders a list like INCLUDE or LIB names.
static bool has_toolchain_file(std::string_view folders, std::string_view name)
{
    while (!folders.empty()) {
        size_t end = std::min(folders.find(';'), folders.size());
        std::string_view folder = folders.substr(0, end);
        folders.remove_prefix(std::min(end + 1, folders.size()));
        if (folder.size() >= 2 && folder.front() == '"' && folder.back() == '"')
            folder = folder.substr(1, folder.size() - 2);
        if (!folder.empty() && is_file(join_path(folder, name)))
            return true;
    }
    return false;
}

static std::string_view environment_value(std::string_view environment, std::string_view name)
{
    while (!environment.empty()) {
        std::string_view entry = environment.substr(0, environment.find('\0'));
        environment.remove_prefix(std::min(entry.size() + 1, environment.size()));
        if (entry.size() > name.size() && entry[name.size()] == '=' && _strnicmp(entry.data(), name.data(), name.size()) == 0)
            return entry.substr(name.size() + 1);
    }
    return std::string_view();
}

// MSVC's cl in an environment, when the environment has the headers and libraries it needs. cl's diagnostics are in
// English with VSLANG=1033, which the diagnostic parser reads.
static WindowsCompiler find_msvc(std::string environment)
{
    WindowsCompiler compiler = {};
    std::string_view includes = environment_value(environment, "INCLUDE");
    std::string_view libraries = environment_value(environment, "LIB");
    if (!has_toolchain_file(includes, "stdio.h") || !has_toolchain_file(includes, "vcruntime.h") ||
        !has_toolchain_file(libraries, "kernel32.lib") || !has_toolchain_file(libraries, "ucrt.lib"))
        return compiler;

    std::string cl = executable_on_path(environment_value(environment, "PATH"), "cl.exe", false);
    if (cl.empty() || !is_file(join_path(parent_folder(cl), "link.exe")))
        return compiler;

    environment += "VSLANG=1033";
    environment += '\0';
    compiler.program = cl;
    compiler.environment = environment;
    compiler.msvc = true;
    return compiler;
}

// The app's own environment, as NAME=value entries each followed by a NUL.
static std::string own_environment()
{
    std::string environment;
    wchar_t *block = GetEnvironmentStringsW();
    for (wchar_t *entry = block; entry && *entry; entry += wcslen(entry) + 1) {
        int length = int(wcslen(entry));
        size_t at = environment.size();
        environment.resize(at + size_t(length) * 3);
        environment.resize(at + size_t(WideCharToMultiByte(CP_UTF8, 0, entry, length, environment.data() + at, length * 3, nullptr, nullptr)));
        environment += '\0';
    }
    if (block)
        FreeEnvironmentStringsW(block);
    return environment;
}

// The environment "set" printed in UTF-16, one NAME=value per line.
static std::string read_set_output(std::string_view bytes)
{
    std::wstring wide(bytes.size() / 2, L'\0');
    memcpy(wide.data(), bytes.data(), wide.size() * 2);
    std::string environment;
    size_t start = 0;
    while (start < wide.size()) {
        size_t end = wide.find(L'\n', start);
        if (end == std::wstring::npos)
            end = wide.size();
        size_t length = end - start - (end > start && wide[end - 1] == L'\r');
        if (length && wide.find(L'=', start) < start + length) {
            size_t at = environment.size();
            environment.resize(at + length * 3);
            environment.resize(at + size_t(WideCharToMultiByte(CP_UTF8, 0, wide.data() + start, int(length), environment.data() + at, int(length) * 3, nullptr, nullptr)));
            environment += '\0';
        }
        start = end + 1;
    }
    return environment;
}

// The C or C++ compiler. The first run of each tries clang on PATH, which finds Visual Studio's headers and
// libraries itself, with a probe that builds, since a clang there can still lack headers, a linker, or a runtime.
// Only when it can't build does the job look for MSVC's cl: in the app's environment, or with vswhere and
// vcvars64.bat. What it finds stays for the runs after it.
static WindowsCompiler find_windows_compiler(RunJob &job, bool cpp)
{
    {
        std::lock_guard lock(windows_compilers_mutex);
        if (!windows_compilers[cpp].program.empty())
            return windows_compilers[cpp];
    }

    WindowsCompiler compiler = {};
    std::string clang = executable_on_path(environment_variable("PATH"), cpp ? "clang++" : "clang", false);
    if (!clang.empty() && make_temporary_folder(job)) {
        log_status(job, "Preparing C/C++ toolchain...\n", OutputTone::Text);
        std::string arguments;
        add_arguments(arguments, {"-x", cpp ? "c++" : "c", cpp ? "-std=c++20" : "-std=c17", "-", "-o", "probe.exe"});
        const char *probe = cpp ? "#include <cstdio>\nint main() { return std::puts(\"\") < 0; }\n"
                                : "#include <stdio.h>\nint main(void) { return puts(\"\") < 0; }\n";
        int code = run_step(job, clang, arguments, job.temporary, CHILD_QUIET, probe);
        if (code == 0 && is_file(join_path(job.temporary, "probe.exe")))
            compiler.program = clang;
    }

    if (compiler.program.empty() && !job.stop) {
        std::lock_guard lock(windows_compilers_mutex);
        if (!msvc_compiler.searched) {
            std::string environment = own_environment();
            if (!environment_value(environment, "INCLUDE").empty() && !environment_value(environment, "LIB").empty())
                msvc_compiler = find_msvc(environment);
            msvc_compiler.searched = true;
        }
        compiler = msvc_compiler;
    }

    // vswhere names vcvars64.bat, and "set" after it prints MSVC's environment, in UTF-16 with /u so paths outside
    // the code page come through. vcvars64.bat runs vswhere itself to find the Windows SDK, so its folder goes on
    // PATH for that step.
    std::string vswhere = join_path(environment_variable("ProgramFiles(x86)"), "Microsoft Visual Studio/Installer/vswhere.exe");
    if (compiler.program.empty() && !job.stop && is_file(vswhere)) {
        if (clang.empty())
            log_status(job, "Preparing C/C++ toolchain...\n", OutputTone::Text);
        std::string arguments;
        add_arguments(arguments, {"-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                                  "-utf8", "-find", "VC\\Auxiliary\\Build\\vcvars64.bat"});
        int code = run_step(job, vswhere, arguments, parent_folder(vswhere), CHILD_QUIET);
        std::string script = job.capture.substr(0, job.capture.find_first_of("\r\n"));
        // The two commands go in a batch file, since an argument like ">nul" would reach cmd in quotes.
        bool ready = code == 0 && is_file(script) && !job.stop && make_temporary_folder(job);
        std::string batch = join_path(job.temporary, "environment.bat");
        if (ready && write_file(batch, "@call \"" + script + "\" >nul && set\r\n")) {
            arguments.clear();
            add_arguments(arguments, {"/d", "/u", "/c", batch});
            std::string path = job.extra_path;
            job.extra_path = parent_folder(vswhere);
            code = run_step(job, join_path(environment_variable("SystemRoot"), "System32/cmd.exe"), arguments, job.temporary, CHILD_QUIET);
            job.extra_path = path;
            if (code == 0) {
                compiler = find_msvc(read_set_output(job.capture));
                std::lock_guard lock(windows_compilers_mutex);
                if (!compiler.program.empty())
                    msvc_compiler = compiler;
            }
        }
    }

    if (!compiler.program.empty()) {
        std::lock_guard lock(windows_compilers_mutex);
        windows_compilers[cpp] = compiler;
    } else if (!job.stop) {
        log_status(job, "Install Visual Studio Build Tools with \xE2\x80\x9C" "Desktop development with C++\xE2\x80\x9D and a Windows SDK, then run again.\n",
                   OutputTone::Error);
    }
    return compiler;
}
#endif

//
// Projects.
//

enum RunKind : uint8_t { RUN_SOURCE, RUN_SCRIPT, RUN_CARGO, RUN_GO_MODULE, RUN_SWIFT_PACKAGE, RUN_DOT_NET, RUN_ODIN_PACKAGE };

struct RunProject {
    RunKind kind;
    std::string folder;
    std::string manifest;
};

// The one project file with an extension in a folder or a folder above it, up to limit. Two in one folder name no
// project.
static std::string find_dot_net_project(std::string_view folder, std::string_view limit, std::string_view extension)
{
    fs::path at = fs_path(folder).lexically_normal();
    fs::path stop = fs_path(limit).lexically_normal();
    for (;;) {
        std::string match;
        std::error_code error;
        fs::directory_iterator entry(at, error);
        for (; !error && entry != fs::directory_iterator(); entry.increment(error)) {
            std::string path = utf8_path(entry->path());
            if (file_name(path).starts_with('.') || file_extension(path, true) != extension || !is_file(path))
                continue;
            if (!match.empty())
                return std::string();
            match = path;
        }
        if (!match.empty())
            return match;
        if (at == stop || !at.has_relative_path())
            return std::string();
        at = at.parent_path();
    }
}

// The project a file belongs to, looking up from its folder to the workspace's, or the whole way up without one.
static RunProject locate_run_project(Language language, const std::string &file, std::string workspace)
{
    RunProject project = {};
    if (file.empty())
        return project;
    if (!path_in_folder(file, workspace))
        workspace.clear();
    std::string folder = parent_folder(file);
    std::string extension = file_extension(file, true);

    const char *manifest_name = language == Language::Rust ? "Cargo.toml" : language == Language::Go ? "go.mod" :
                                language == Language::Swift ? "Package.swift" : nullptr;
    RunKind kind = language == Language::Rust ? RUN_CARGO : language == Language::Go ? RUN_GO_MODULE : RUN_SWIFT_PACKAGE;
    if (manifest_name) {
        project.manifest = find_parent_file(folder, workspace, manifest_name);
        if (!project.manifest.empty()) {
            project.kind = kind;
            project.folder = kind == RUN_CARGO && !workspace.empty() ? workspace : parent_folder(project.manifest);
            return project;
        }
    }
    if (language == Language::Odin) {
        if (extension == "odin") {
            project.kind = RUN_ODIN_PACKAGE;
            project.folder = workspace.empty() ? folder : workspace;
        }
        return project;
    }

    const char *project_extension = language == Language::CSharp && extension != "csx" ? "csproj" :
                                    language == Language::FSharp && extension != "fsx" ? "fsproj" :
                                    language == Language::VisualBasic && extension == "vb" ? "vbproj" : nullptr;
    if (project_extension) {
        project.manifest = find_dot_net_project(folder, workspace, project_extension);
        if (!project.manifest.empty()) {
            project.kind = RUN_DOT_NET;
            project.folder = parent_folder(project.manifest);
            return project;
        }
    }
    if (!workspace.empty() && ToolForRun(language).tool) {
        project.kind = RUN_SCRIPT;
        project.folder = workspace;
    }
    return project;
}

//
// Recipes.
//

static void set_diagnostics(RunJob &job, std::string_view folder)
{
    job.diagnostic_folder = folder;
    Language language = job.language;
    job.columns = is_c_family(language) || language == Language::Go || language == Language::Odin || language == Language::Zig ||
                  language == Language::Assembly ? RUN_COLUMN_BYTES : RUN_COLUMN_CHARACTERS;
    job.format = language == Language::Go ? CompilerFormat::Go :
                 language == Language::Kotlin ? CompilerFormat::Kotlin :
                 language == Language::CSharp || language == Language::FSharp || language == Language::VisualBasic ? CompilerFormat::Parenthesized :
                 CompilerFormat::Standard;
}

// Builds a .NET project or a C# file into the temporary folder, then runs the one application it made.
static void build_and_run_dot_net(RunJob &job, std::string_view tool, std::string_view source, std::string_view folder)
{
    if (!make_temporary_folder(job))
        return;
    std::string arguments;
    add_arguments(arguments, {"build", source, "--output", job.temporary, "--disable-build-servers", "--nologo", "-p:NuGetAudit=false"});
    if (file_extension(source, true) == "cs") {
        // File-based builds default to AOT. The managed application runs on the installed runtime instead.
        add_arguments(arguments, {"-p:PublishAot=false", "-p:PublishTrimmed=false", "-p:SelfContained=false"});
    }
    if (!build_program(job, tool, arguments, folder))
        return;

    // The application is the .dll beside a .runtimeconfig.json, the one named after the source when there are several.
    std::string preferred = utf8_path(fs_path(source).stem());
    std::string only;
    int count = 0;
    std::error_code error;
    fs::directory_iterator entry(fs_path(job.temporary), error);
    for (; !error && entry != fs::directory_iterator(); entry.increment(error)) {
        std::string name = file_name(utf8_path(entry->path()));
        const std::string_view suffix = ".runtimeconfig.json";
        if (!name.ends_with(suffix))
            continue;
        std::string base = name.substr(0, name.size() - suffix.size());
        std::string assembly = join_path(job.temporary, base + ".dll");
        if (!is_file(assembly))
            continue;
        if (base == preferred) {
            only = assembly;
            count = 1;
            break;
        }
        only = assembly;
        ++count;
    }
    if (count != 1) {
        log_status(job, "The .NET build did not produce a single executable application.\n", OutputTone::Error);
        return;
    }
    arguments.clear();
    add_arguments(arguments, {only});
    run_program(job, tool, arguments, folder, false);
}

// A single file or script: built into the temporary folder first when its language compiles, from the draft when the
// tab isn't saved.
static void run_source(RunJob &job, const RunProject &project)
{
    Language language = job.language;
    RunTool spec = ToolForRun(language);
    if (!spec.tool) {
        log_status(job, "This file type cannot be run.\n", OutputTone::Error);
        return;
    }
    if (language == Language::VisualBasic) {
        log_status(job, "Open a file in a Visual Basic .NET project to run it.\n", OutputTone::Error);
        return;
    }

    std::string folder = job.file.empty() ? std::string() : parent_folder(job.file);
    std::string extension = file_extension(job.file.empty() ? job.name : job.file, true);
    std::string working = project.kind == RUN_ODIN_PACKAGE ? std::string() : project.folder;
    bool build = is_c_family(language) || language == Language::Rust || language == Language::Swift || language == Language::Go ||
                 language == Language::Odin || language == Language::Assembly;
    bool kotlin = language == Language::Kotlin && extension != "kts";
    bool mono = false;
    bool dotnet = false;

    // The tool, and what runs the program when it doesn't run itself.
    std::string tool;
    std::string launcher;
    std::string arguments;
    std::string tool_name = spec.tool;
    if (language == Language::Python) {
        tool = find_python(job, working.empty() ? folder : working, arguments);
        if (tool.empty())
            return;
    } else if (language == Language::TypeScript || language == Language::JSX || language == Language::TSX) {
        tool = find_tsx(job, folder, working);
        if (tool.empty())
            return;
    } else if (language == Language::CSharp) {
        if (extension == "csx") {
            tool_name = "csi";
        } else {
            tool = find_tool(job, "dotnet", language);
            dotnet = !tool.empty();
            if (!dotnet) {
                tool = find_tool(job, "mcs", language);
                launcher = find_tool(job, "mono", language);
                mono = !tool.empty() && !launcher.empty();
                build = mono;
                if (!mono) {
                    tool.clear();
                    launcher.clear();
                    tool_name = "dotnet";
                }
            }
        }
    }
    if (kotlin) {
        launcher = get_tool(job, "java", Language::Java);
        if (launcher.empty())
            return;
        build = true;
    }

    bool find_compiler = RUN_ON_WINDOWS && (language == Language::C || language == Language::Cpp);
    if (tool.empty() && !find_compiler)
        tool = get_tool(job, tool_name, language);
    if (tool.empty() && !find_compiler)
        return;

    // The file the tool reads.
    job.input_path = job.file;
    if (job.has_draft) {
        std::string suffix = extension.empty() ? std::string(spec.suffix ? spec.suffix : "") : '.' + file_extension(job.file.empty() ? job.name : job.file, false);
        bool beside = !folder.empty() && language != Language::Go && !dotnet;
        if (!write_draft(job, beside ? folder : std::string_view(), suffix))
            return;
    }
    if (!is_file(job.input_path)) {
        log_status(job, "The source file could not be opened.\n", OutputTone::Error);
        return;
    }
    if (build && !make_temporary_folder(job))
        return;
    std::string includes = folder.empty() ? job.temporary : folder;
    std::string run_folder = !working.empty() ? working : !folder.empty() ? folder : job.temporary.empty() ? parent_folder(job.input_path) : job.temporary;
    set_diagnostics(job, run_folder);

    if (dotnet) {
        build_and_run_dot_net(job, tool, job.input_path, run_folder);
        return;
    }
    if (!build) {
        job.runtime_locations = language == Language::Python || is_javascript_family(language);
        bool diagnostics = job.runtime_locations || language == Language::Java || language == Language::Kotlin || language == Language::Zig ||
                           language == Language::Dart || language == Language::CSharp || language == Language::FSharp;
        RunFlags flags = ScriptRunFlags(language);
        for (unsigned index = 0; index < flags.count; ++index)
            add_arguments(arguments, {flags.values[index]});
        add_arguments(arguments, {job.input_path});
        job.announce_program = true;
        run_program(job, tool, arguments, run_folder, diagnostics);
        return;
    }

    // The build's arguments.
    std::string program = join_path(job.temporary, kotlin ? "program.jar" : mono || RUN_ON_WINDOWS ? "program.exe" : "program");
    const std::string &path = job.input_path;
    arguments.clear();
    if (kotlin) {
        add_arguments(arguments, {path, "-include-runtime", "-d", program});
    } else if (mono) {
        add_arguments(arguments, {"-out:" + program, path});
    } else if (language == Language::Rust) {
        add_arguments(arguments, {"--edition=2021", "--crate-name", "editor_program", "--error-format=json",
                                  "--json=diagnostic-rendered-ansi", path, "-o", program});
        job.rust_json = true;
    } else if (language == Language::Swift) {
        add_arguments(arguments, {"-color-diagnostics", path, "-o", program});
    } else if (language == Language::Go) {
        add_arguments(arguments, {"build", "-o", program, path});
    } else if (language == Language::Odin) {
        bool package = !job.has_draft && project.kind == RUN_ODIN_PACKAGE;
        add_arguments(arguments, {"build", package ? parent_folder(path) : path, "-out:" + program, "-error-pos-style:unix", "-terse-errors"});
        if (!package)
            add_arguments(arguments, {"-file"});
    } else if (language == Language::Zig) {
        add_arguments(arguments, {"build-exe", "-O", "Debug", path, "-femit-bin=" + program});
    } else if (language == Language::Assembly) {
        add_arguments(arguments, {"-g", path, "-o", program});
    } else {
        // C, C++, Objective-C, and Objective-C++. On Windows the compiler is clang or MSVC's cl, found the first time.
        bool cpp = language == Language::Cpp || language == Language::ObjectiveCpp;
        bool objective = language == Language::ObjectiveC || language == Language::ObjectiveCpp;
#ifdef _WIN32
        if (find_compiler) {
            WindowsCompiler compiler = find_windows_compiler(job, cpp);
            if (compiler.program.empty())
                return;
            tool = compiler.program;
            job.environment = compiler.environment;
            job.msvc = compiler.msvc;
        }
#endif
        if (job.msvc) {
            std::string object = join_path(job.temporary, "program.obj");
            add_arguments(arguments, {"/nologo", "/utf-8", "/W4", "/FC", "/diagnostics:column", cpp ? "/TP" : "/TC",
                                      cpp ? "/std:c++20" : "/std:c17"});
            if (cpp)
                add_arguments(arguments, {"/EHsc"});
            add_arguments(arguments, {"/I" + utf8_path(fs_path(includes).make_preferred()), "/Fo" + utf8_path(fs_path(object).make_preferred()),
                                      "/Fe" + utf8_path(fs_path(program).make_preferred()), utf8_path(fs_path(path).make_preferred())});
        } else {
            const char *kind = objective ? (cpp ? "objective-c++" : "objective-c") : (cpp ? "c++" : "c");
            add_arguments(arguments, {"-x", kind, cpp ? "-std=c++20" : "-std=c17", "-Wall", "-Wextra", "-fcolor-diagnostics",
                                      "-fno-caret-diagnostics", "-fdiagnostics-print-source-range-info", "-iquote", includes, path, "-o", program});
#ifdef __APPLE__
            if (objective) {
                add_arguments(arguments, {"-framework", "Foundation"});
            }
#endif
        }
    }

    if (!build_program(job, tool, arguments, run_folder))
        return;
    if (language == Language::Go && !is_executable(program)) {
        log_status(job, "A Go program needs package main and a main function.\n", OutputTone::Error);
        return;
    }
    arguments.clear();
    if (kotlin)
        add_arguments(arguments, {"-jar"});
    if (!launcher.empty())
        add_arguments(arguments, {program});
    run_program(job, launcher.empty() ? std::string_view(program) : std::string_view(launcher), arguments, run_folder, false);
}

// cargo's target for the file: the binary, example, or test whose source it is, or else the workspace's one default
// binary when the manifest isn't a package's.
static void add_cargo_target(std::string &arguments, lsp::Json metadata, const std::string &manifest, const std::string &file)
{
    lsp::Json members = lsp::JsonField(metadata, "workspace_default_members");
    if (!lsp::IsArray(members))
        members = lsp::JsonField(metadata, "workspace_members");
    bool package_manifest = false;
    std::string only_package, only_target;
    int defaults = 0;

    lsp::Json packages = lsp::JsonField(metadata, "packages");
    lsp::Json package_items = lsp::IsArray(packages) ? lsp::JsonContents(packages) : lsp::Json();
    while (!package_items.empty()) {
        lsp::Json package = lsp::NextJsonValue(package_items);
        std::string manifest_path = json_text(package, "manifest_path");
        if (manifest_path.empty())
            continue;
        bool current = same_file(manifest_path, manifest);
        package_manifest |= current;
        bool workspace_default = json_array_has(members, json_text(package, "id"));
        std::string default_run = json_text(package, "default_run");

        lsp::Json targets = lsp::JsonField(package, "targets");
        lsp::Json target_items = lsp::IsArray(targets) ? lsp::JsonContents(targets) : lsp::Json();
        while (!target_items.empty()) {
            lsp::Json target = lsp::NextJsonValue(target_items);
            std::string name = json_text(target, "name");
            if (name.empty())
                continue;
            lsp::Json kind = lsp::JsonField(target, "kind");
            bool binary = json_array_has(kind, "bin");
            bool example = json_array_has(kind, "example") && json_array_has(lsp::JsonField(target, "crate_types"), "bin");
            if ((binary || example) && same_file(json_text(target, "src_path"), file)) {
                if (!current) {
                    add_arguments(arguments, {"--package", json_text(package, "name")});
                }
                add_arguments(arguments, {binary ? "--bin" : "--example", name});
                return;
            }
            if (binary && workspace_default && (default_run.empty() || default_run == name)) {
                ++defaults;
                only_package = json_text(package, "name");
                only_target = name;
            }
        }
    }
    if (!package_manifest && defaults == 1) {
        add_arguments(arguments, {"--package", only_package, "--bin", only_target});
    }
}

static void run_cargo(RunJob &job, const RunProject &project)
{
    std::string tool = get_tool(job, "cargo", Language::Rust);
    if (tool.empty())
        return;
    std::string folder = parent_folder(project.manifest);
    log_status(job, "Building...\n", OutputTone::Text);

    // What the workspace holds, to choose the target.
    std::string arguments;
    add_arguments(arguments, {"metadata", "--no-deps", "--format-version", "1", "--manifest-path", project.manifest});
    int code = run_step(job, tool, arguments, folder, CHILD_CAPTURE);
    if (job.stop)
        return;
    std::string metadata = job.capture;
    if (code != 0 || !lsp::IsObject(metadata)) {
        log_status(job, "Could not read the Cargo project.\n", OutputTone::Error);
        return;
    }

    std::string root = json_text(metadata, "workspace_root");
    arguments.clear();
    add_arguments(arguments, {"run", "--quiet", "--color", "always", "--message-format=json,json-diagnostic-rendered-ansi",
                              "--manifest-path", project.manifest});
    add_cargo_target(arguments, metadata, project.manifest, job.file);

    job.input_path = job.file;
    job.diagnostic_folder = root.empty() ? folder : root;
    job.cargo_json = true;
    job.cargo_built = false;
    code = run_step(job, tool, arguments, folder, CHILD_PROGRAM);
    job.cargo_json = false;
    if (job.stop)
        return;
    if (!job.cargo_built) {
        log_status(job, "Build failed.\n", OutputTone::Error);
        return;
    }
    if (code == CHILD_CRASHED)
        log_status(job, "The process crashed.\n", OutputTone::Error);
    else
        job.exit_code = code;
}

static void run_go_module(RunJob &job, const RunProject &project)
{
    std::string tool = get_tool(job, "go", Language::Go);
    if (tool.empty() || !make_temporary_folder(job))
        return;
    std::string folder = parent_folder(job.file);
    if (!path_in_folder(folder, project.folder))
        folder = project.folder;
    job.input_path = job.file;
    set_diagnostics(job, folder);

    bool tests = job.file.ends_with("_test.go");
    std::string program = join_path(job.temporary, RUN_ON_WINDOWS ? "program.exe" : "program");
    std::string arguments;
    if (tests) {
        add_arguments(arguments, {"test", "-c"});
    } else {
        add_arguments(arguments, {"build"});
    }
    add_arguments(arguments, {"-o", program, "."});
    if (!build_program(job, tool, arguments, folder))
        return;
    if (!is_executable(program)) {
        log_status(job, "Open a Go file in a main package or a _test.go file to run tests.\n", OutputTone::Error);
        return;
    }
    arguments.clear();
    if (tests)
        add_arguments(arguments, {"-test.v"});
    run_program(job, program, arguments, folder, false);
}

// The package's executable product: its only one, or the one with a target whose sources hold the file.
static std::string swift_product(lsp::Json package, const std::string &folder, const std::string &file)
{
    lsp::Json products = lsp::JsonField(package, "products");
    std::vector<lsp::Json> executables;
    lsp::Json items = lsp::IsArray(products) ? lsp::JsonContents(products) : lsp::Json();
    while (!items.empty()) {
        lsp::Json product = lsp::NextJsonValue(items);
        if (!lsp::JsonField(lsp::JsonField(product, "type"), "executable").empty())
            executables.push_back(product);
    }
    if (executables.size() == 1)
        return json_text(executables[0], "name");

    lsp::Json targets = lsp::JsonField(package, "targets");
    for (lsp::Json product : executables) {
        lsp::Json names = lsp::JsonField(product, "targets");
        lsp::Json name_items = lsp::IsArray(names) ? lsp::JsonContents(names) : lsp::Json();
        while (!name_items.empty()) {
            lsp::Json name = lsp::NextJsonValue(name_items);
            std::string target_name = lsp::IsString(name) ? lsp::DecodeJsonString(lsp::JsonContents(name)) : std::string();
            std::string path = "Sources/" + target_name;
            lsp::Json target_items = lsp::IsArray(targets) ? lsp::JsonContents(targets) : lsp::Json();
            while (!target_items.empty()) {
                lsp::Json target = lsp::NextJsonValue(target_items);
                if (json_text(target, "name") == target_name && !json_text(target, "path").empty()) {
                    path = json_text(target, "path");
                    break;
                }
            }
            if (path_in_folder(file, join_path(folder, path)))
                return json_text(product, "name");
        }
    }
    return std::string();
}

static void run_swift_package(RunJob &job, const RunProject &project)
{
    std::string tool = get_tool(job, "swift", Language::Swift);
    if (tool.empty())
        return;
    job.input_path = job.file;
    set_diagnostics(job, project.folder);

    std::string arguments;
    add_arguments(arguments, {"package", "dump-package"});
    job.diagnostics = true;
    int code = run_step(job, tool, arguments, project.folder, CHILD_CAPTURE);
    if (code != 0 || job.stop)
        return;
    std::string package = job.capture;
    std::string product = swift_product(package, project.folder, job.file);
    if (product.empty()) {
        log_status(job, "Open a source file in an executable Swift package target.\n", OutputTone::Error);
        return;
    }

    arguments.clear();
    add_arguments(arguments, {"build", "--product", product, "-Xswiftc", "-color-diagnostics"});
    if (!build_program(job, tool, arguments, project.folder))
        return;

    arguments.clear();
    add_arguments(arguments, {"build", "--show-bin-path"});
    code = run_step(job, tool, arguments, project.folder, CHILD_CAPTURE);
    if (code != 0 || job.stop)
        return;
    std::string folder = job.capture.substr(0, job.capture.find_first_of("\r\n"));
    std::string program = executable_in(folder, product);
    if (program.empty()) {
        log_status(job, "Swift did not produce an executable.\n", OutputTone::Error);
        return;
    }
    run_program(job, program, std::string(), project.folder, false);
}

void run_job(RunJob &job)
{
    job.exit_code = -1;
    RunProject project = locate_run_project(job.language, job.file, job.workspace);
    if (project.kind == RUN_CARGO) {
        run_cargo(job, project);
    } else if (project.kind == RUN_GO_MODULE) {
        run_go_module(job, project);
    } else if (project.kind == RUN_SWIFT_PACKAGE) {
        run_swift_package(job, project);
    } else if (project.kind == RUN_DOT_NET) {
        std::string tool = get_tool(job, "dotnet", job.language);
        job.input_path = job.file;
        set_diagnostics(job, project.folder);
        if (!tool.empty())
            build_and_run_dot_net(job, tool, project.manifest, project.folder);
    } else {
        run_source(job, project);
    }

    if (job.stop)
        log_status(job, "Stopped.\n", OutputTone::Text);
    else if (job.exit_code >= 0)
        log_status(job, "Process exited with code " + std::to_string(job.exit_code) + ".\n", job.exit_code ? OutputTone::Error : OutputTone::Text);

    std::error_code error;
    if (!job.snapshot.empty())
        fs::remove(fs_path(job.snapshot), error);
    if (!job.temporary.empty())
        fs::remove_all(fs_path(job.temporary), error);

    std::lock_guard lock(job.mutex);
    job.finished = true;
    job.input_open = false;
    notify_if_needed(job);
}
