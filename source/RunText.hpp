#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

enum class OutputTone { Text, Warning, Error };

// ANSI truecolors are opaque RGBA. The low values hold the default and palette indices.
inline constexpr uint32_t defaultOutputColor = 0;
inline constexpr uint32_t outputPaletteStart = 1;

struct OutputColors {
    uint32_t foreground = defaultOutputColor;
    uint32_t background = defaultOutputColor;

    bool operator==(const OutputColors &) const = default;
};

struct OutputRange {
    uint32_t location;
    uint32_t length;
};

struct OutputColorSpan {
    OutputRange range;
    OutputColors colors;
};

enum class TerminalState { Text, Escape, EscapeSuffix, CSI, ControlString, StringEscape };

struct TerminalDecoder {
    TerminalState state = TerminalState::Text;
    char parameters[64];
    size_t parameterCount = 0;
    OutputColors colors;
    bool sawSGR = false;
};

void AddOutputColors(std::vector<OutputColorSpan> &spans, size_t location, size_t length, OutputColors colors);
struct DecodedOutput {
    std::string text;
    std::vector<OutputColorSpan> spans;
    size_t characters = 0;
};

void DecodeTerminal(TerminalDecoder &decoder, std::string_view bytes, DecodedOutput &output);
void ClearDecodedOutput(DecodedOutput &output);
OutputTone ConsoleTone(std::string_view line, bool stderrLine);
size_t CompleteUTF8Prefix(std::string_view bytes);

struct RunRecords {
    std::string partial;
    bool dropping = false;
};

using RunRecord = bool (*)(void *, std::string_view);
// The returned view is the unread portion if the callback stops.
std::string_view ReadRunRecords(RunRecords &reader, std::string_view bytes, size_t limit, RunRecord receive, void *context);

enum class CompilerFormat { Standard, Go, DotNet, Kotlin };

struct CompilerLocation {
    std::string_view path;
    size_t details = 0;
    size_t line = 0, column = 0;
    size_t firstColumn = 0, endColumn = 0;
    OutputTone tone = OutputTone::Text;
    bool addSeverity = false;
};

bool ParseCompilerLocation(std::string_view text, CompilerFormat fallback, CompilerLocation &location);

struct SyntaxIssue {
    size_t line = 0, column = 0;
    std::string_view message;
};

enum class ScriptDiagnostic { Node, Shell, PHP };

SyntaxIssue FindScriptIssue(std::string_view output, std::string_view file, ScriptDiagnostic format);
SyntaxIssue CheckJSONText(std::string_view text, bool comments);
bool ParseRuntimeLocation(std::string_view text, bool python, CompilerLocation &location);