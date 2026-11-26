#include "RunText.hpp"
#include "Color.h"
#include "LSPJson.hpp"

#include <algorithm>

void AddOutputColors(std::vector<OutputColorSpan> &spans, size_t location, size_t length, OutputColors colors)
{
    if (!length || colors == OutputColors{})
        return;

    if (!spans.empty() && spans.back().colors == colors && spans.back().range.location + spans.back().range.length == location)
        spans.back().range.length += uint32_t(length);
    else
        spans.push_back({{uint32_t(location), uint32_t(length)}, colors});
}

static std::string_view TakeColorParameter(std::string_view &parameters, char separator)
{
    size_t end = parameters.find(separator);
    std::string_view parameter = parameters.substr(0, end);
    if (end == std::string_view::npos)
        parameters = {};
    else
        parameters.remove_prefix(end + 1);
    return parameter;
}

static int ColorParameter(std::string_view text)
{
    if (text.empty())
        return -1;
    int number = 0;
    for (char digit : text) {
        if (digit < '0' || digit > '9')
            return -1;
        number = number * 10 + (digit - '0');
        if (number > 255)
            return -1;
    }
    return number;
}

static uint32_t ExtendedOutputColor(std::string_view &parameters, char separator)
{
    int kind = ColorParameter(TakeColorParameter(parameters, separator));
    if (kind == 5) {
        int value = ColorParameter(TakeColorParameter(parameters, separator));
        return value < 0 ? defaultOutputColor : outputPaletteStart + uint32_t(value);
    }
    if (kind != 2)
        return defaultOutputColor;
    // Colon notation can include a color space field before the RGB components.
    if (separator == ':' && std::count(parameters.begin(), parameters.end(), ':') >= 3)
        TakeColorParameter(parameters, separator);
    int red = ColorParameter(TakeColorParameter(parameters, separator));
    int green = ColorParameter(TakeColorParameter(parameters, separator));
    int blue = ColorParameter(TakeColorParameter(parameters, separator));
    if (red < 0 || green < 0 || blue < 0)
        return defaultOutputColor;
    return rgb(red, green, blue);
}

static void ApplySGR(TerminalDecoder &decoder, std::string_view values)
{
    decoder.sawSGR = true;
    do {
        std::string_view value = TakeColorParameter(values, ';');
        bool colon = value.find(':') != std::string_view::npos;
        auto mode = TakeColorParameter(value, ':');
        int code = mode.empty() ? 0 : ColorParameter(mode);
        if (code == 0) {
            decoder.colors = {};
        } else if (code == 39) {
            decoder.colors.foreground = defaultOutputColor;
        } else if (code == 49) {
            decoder.colors.background = defaultOutputColor;
        } else if (code == 38 || code == 48) {
            uint32_t color = colon ? ExtendedOutputColor(value, ':') : ExtendedOutputColor(values, ';');
            if (color != defaultOutputColor)
                (code == 38 ? decoder.colors.foreground : decoder.colors.background) = color;
        } else if (code >= 30 && code <= 37) {
            decoder.colors.foreground = outputPaletteStart + uint32_t(code - 30);
        } else if (code >= 40 && code <= 47) {
            decoder.colors.background = outputPaletteStart + uint32_t(code - 40);
        } else if (code >= 90 && code <= 97) {
            decoder.colors.foreground = outputPaletteStart + uint32_t(code - 82);
        } else if (code >= 100 && code <= 107) {
            decoder.colors.background = outputPaletteStart + uint32_t(code - 92);
        }
    } while (values.data()); // An empty parameter still means reset.
}

static void ReadControl(TerminalDecoder &decoder, unsigned char character)
{
    switch (decoder.state) {
        case TerminalState::Text:
            if (character == 0x1B)
                decoder.state = TerminalState::Escape;
            break;
        case TerminalState::Escape:
            if (character == '[') {
                decoder.state = TerminalState::CSI;
                decoder.parameterCount = 0;
            } else if (character == ']' || character == 'P' || character == 'X' || character == '^' || character == '_') {
                decoder.state = TerminalState::ControlString;
            } else if (character >= 0x20 && character <= 0x2F) {
                decoder.state = TerminalState::EscapeSuffix;
            } else if (character != 0x1B) {
                decoder.state = TerminalState::Text;
            }
            break;
        case TerminalState::EscapeSuffix:
            if (character == 0x1B)
                decoder.state = TerminalState::Escape;
            else if (character < 0x20 || character > 0x2F)
                decoder.state = TerminalState::Text;
            break;
        case TerminalState::CSI:
            if (character == 0x1B) {
                decoder.state = TerminalState::Escape;
            } else if (character >= 0x40 && character <= 0x7E) {
                if (character == 'm' && decoder.parameterCount <= sizeof(decoder.parameters))
                    ApplySGR(decoder, {decoder.parameters, decoder.parameterCount});
                decoder.state = TerminalState::Text;
            } else if (decoder.parameterCount < sizeof(decoder.parameters) &&
                       ((character >= '0' && character <= '9') || character == ';' || character == ':')) {
                decoder.parameters[decoder.parameterCount++] = char(character);
            } else {
                decoder.parameterCount = sizeof(decoder.parameters) + 1;
            }
            break;
        case TerminalState::ControlString:
            if (character == '\a')
                decoder.state = TerminalState::Text;
            else if (character == 0x1B)
                decoder.state = TerminalState::StringEscape;
            break;
        case TerminalState::StringEscape:
            if (character == '\\' || character == '\a')
                decoder.state = TerminalState::Text;
            else if (character != 0x1B)
                decoder.state = TerminalState::ControlString;
            break;
    }
}


static unsigned UTF8Width(uint8_t lead)
{
    return lead < 0x80 ? 1 : lead < 0xC2 ? 0 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : lead < 0xF5 ? 4 : 0;
}

static bool ReadUTF8(std::string_view bytes, size_t &index, uint32_t &value)
{
    uint8_t lead = bytes[index];
    unsigned width = UTF8Width(lead);
    if (!width || width > bytes.size() - index)
        return false;

    value = width == 1 ? lead : lead & (0x7f >> width);
    for (unsigned i = 1; i < width; ++i) {
        uint8_t ch = bytes[index + i];
        if ((ch & 0xC0) != 0x80)
            return false;

        value = (value << 6) | (ch & 0x3f);
    }

    constexpr uint32_t minimum[] = {0, 0, 0x80, 0x800, 0x10000};
    if (value < minimum[width] || (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF)
        return false;

    index += width;
    return true;
}

static bool IsUTF8(std::string_view bytes)
{
    for (size_t i = 0; i < bytes.size();) {
        if (uint8_t(bytes[i]) < 0x80) {
            ++i;
        } else {
            uint32_t value;
            if (!ReadUTF8(bytes, i, value))
                return false;
        }
    }

    return true;
}

size_t CompleteUTF8Prefix(std::string_view bytes)
{
    if (bytes.empty())
        return 0;

    size_t last = bytes.size() - 1;
    while (last && (uint8_t(bytes[last]) & 0xC0) == 0x80)
        --last;

    return bytes.size() - last < UTF8Width(bytes[last]) ? last : bytes.size();
}

void DecodeTerminal(TerminalDecoder &decoder, std::string_view bytes, DecodedOutput &output)
{
    size_t color_start = output.characters;
    auto colors = decoder.colors;
    bool latin1 = false, checked_encoding = false;
    size_t index = 0;
    while (index < bytes.size()) {
        if (decoder.state == TerminalState::Text) {
            size_t start = index;
            while (index < bytes.size()) {
                unsigned char ch = bytes[index];
                if (ch < 32 && ch != '\t' && ch != '\n')
                    break;
                if (ch >= 127)
                    break;

                ++index;
            }

            output.text.append(bytes.substr(start, index - start));
            output.characters += index - start;
            if (index == bytes.size())
                break;

            unsigned char ch = bytes[index];
            if (ch > 127) {
                if (!checked_encoding) {
                    latin1 = !IsUTF8(bytes);
                    checked_encoding = true;
                }

                if (latin1) {
                    output.text += char(0xC0 | (ch >> 6));
                    output.text += char(0x80 | (ch & 63));
                    ++index;
                    ++output.characters;
                } else {
                    size_t first = index;
                    uint32_t value;
                    if (!ReadUTF8(bytes, index, value)) {
                        ++index;
                        continue;
                    }

                    output.text.append(bytes.substr(first, index - first));
                    output.characters += value >= 0x10000 ? 2 : 1;
                }
                continue;
            }
        }

        unsigned char ch = bytes[index++];
        if (ch == '\n') {
            // A malformed escape ends at the next line.
            decoder.state = TerminalState::Text;
            output.text += '\n';
            ++output.characters;
            continue;
        }

        ReadControl(decoder, ch);
        if (colors != decoder.colors) {
            AddOutputColors(output.spans, color_start, output.characters - color_start, colors);
            color_start = output.characters;
            colors = decoder.colors;
        }
    }

    AddOutputColors(output.spans, color_start, output.characters - color_start, colors);
}

void ClearDecodedOutput(DecodedOutput &output)
{
    output.text.clear();
    output.spans.clear();
    output.characters = 0;
}

static char LowerASCII(char ch)
{
    return ch >= 'A' && ch <= 'Z' ? ch + ('a' - 'A') : ch;
}

static bool StartsWith(std::string_view line, std::string_view word)
{
    if (line.size() < word.size())
        return false;

    for (size_t i = 0; i < word.size(); ++i) {
        if (LowerASCII(line[i]) != LowerASCII(word[i]))
            return false;
    }

    return true;
}

OutputTone ConsoleTone(std::string_view line, bool stderrLine)
{
    if (StartsWith(line, "warning:") || StartsWith(line, "warning[") ||
        line.ends_with(" warning generated.\n") || line.ends_with(" warnings generated.\n"))
        return OutputTone::Warning;

    if (stderrLine) {
        for (size_t at = 0; at < line.size(); ++at) {
            if (LowerASCII(line[at]) == 'w' && StartsWith(line.substr(at), "warning:"))
                return OutputTone::Warning;
        }
    }

    if (StartsWith(line, "note:") || StartsWith(line, "help:") || StartsWith(line, "In file included from "))
        return OutputTone::Text;

    return stderrLine || StartsWith(line, "error:") || StartsWith(line, "fatal error:") ? OutputTone::Error : OutputTone::Text;
}

std::string_view ReadRunRecords(RunRecords &reader, std::string_view bytes, size_t limit, RunRecord receive, void *context)
{
    while (!bytes.empty()) {
        size_t newline = bytes.find('\n');
        size_t count = newline == bytes.npos ? bytes.size() : newline + 1;
        auto line = bytes.substr(0, count);
        bytes.remove_prefix(count);

        if (count > limit - reader.partial.size()) {
            reader.partial.clear();
            reader.dropping = true;
        }

        if (!reader.dropping) {
            if (!reader.partial.empty() || newline == line.npos) {
                reader.partial += line;
                line = reader.partial;
            }

            if (newline != line.npos && !receive(context, line)) {
                reader.partial.clear();
                break;
            }
        }

        if (newline != line.npos) {
            reader.partial.clear();
            reader.dropping = false;
        }
    }

    return bytes;
}

static bool Take(std::string_view &text, char ch)
{
    if (text.empty() || text.front() != ch)
        return false;

    text.remove_prefix(1);
    return true;
}

static bool TakeNumber(std::string_view &text, size_t &number)
{
    if (text.empty() || text.front() < '0' || text.front() > '9')
        return false;

    number = 0;
    do {
        unsigned digit = text.front() - '0';
        number = number > (INT64_MAX - digit) / 10 ? INT64_MAX : number * 10 + digit;
        text.remove_prefix(1);
    } while (!text.empty() && text.front() >= '0' && text.front() <= '9');

    return true;
}

static void SkipSpaces(std::string_view &text)
{
    while (!text.empty() && (text.front() == ' ' || text.front() == '\t'))
        text.remove_prefix(1);
}

static bool TakeSeverity(std::string_view &text, OutputTone &tone, bool standard)
{
    if (StartsWith(text, "warning")) {
        tone = OutputTone::Warning;
        text.remove_prefix(7);
    } else if (StartsWith(text, "error")) {
        tone = OutputTone::Error;
        text.remove_prefix(5);
    } else if (standard && StartsWith(text, "fatal error")) {
        tone = OutputTone::Error;
        text.remove_prefix(11);
    } else if (standard && StartsWith(text, "syntax error")) {
        tone = OutputTone::Error;
        text.remove_prefix(12);
    } else if (standard && (StartsWith(text, "help") || StartsWith(text, "note"))) {
        tone = OutputTone::Text;
        text.remove_prefix(4);
    } else {
        return false;
    }

    if (!standard) {
        if (text.empty())
            return true;

        char ch = LowerASCII(text.front());
        return (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') && ch != '_';
    }

    if (Take(text, '[')) {
        size_t end = text.find(']');
        if (end == text.npos)
            return false;

        text.remove_prefix(end + 1);
    }

    return Take(text, ':');
}

static void ParseSourceRange(std::string_view text, CompilerLocation &location)
{
    size_t line, first, finalLine, end;
    if (TakeNumber(text, line) && Take(text, ':') && TakeNumber(text, first) && Take(text, '-') &&
        TakeNumber(text, finalLine) && Take(text, ':') && TakeNumber(text, end) && text.empty() &&
        line == location.line && finalLine == line && first <= location.column && end > location.column) {
        location.firstColumn = first;
        location.endColumn = end;
    }
}

static bool ParsePositionLine(std::string_view line, CompilerFormat format, CompilerLocation &location)
{
    auto path = line;
    OutputTone kotlin_tone = OutputTone::Error;
    if (format == CompilerFormat::Kotlin) {
        if (path.size() < 3 || path[1] != ':' || (path[0] != 'e' && path[0] != 'w' && path[0] != 'i'))
            return false;

        kotlin_tone = path[0] == 'w' ? OutputTone::Warning : path[0] == 'i' ? OutputTone::Text : OutputTone::Error;
        path.remove_prefix(2);
        SkipSpaces(path);
    }

    char separator = format == CompilerFormat::DotNet ? '(' : ':';
    for (size_t at = path.find(separator, 1); at != path.npos; at = path.find(separator, at + 1)) {
        CompilerLocation candidate{};
        candidate.path = path.substr(0, at);
        auto rest = path.substr(at + 1);
        if (format == CompilerFormat::Go && !candidate.path.ends_with(".go"))
            continue;
        if (!TakeNumber(rest, candidate.line))
            continue;

        if (format == CompilerFormat::DotNet) {
            if (!Take(rest, ',') || !TakeNumber(rest, candidate.column))
                continue;

            if (Take(rest, ',')) {
                size_t unused;
                if (!TakeNumber(rest, unused) || !Take(rest, ',') || !TakeNumber(rest, unused))
                    continue;
            }

            if (!Take(rest, ')') || !Take(rest, ':'))
                continue;

            SkipSpaces(rest);
        } else {
            if (!Take(rest, ':'))
                continue;

            auto column = rest;
            size_t value;
            if (TakeNumber(column, value) && (format == CompilerFormat::Kotlin || Take(column, ':'))) {
                if (format == CompilerFormat::Kotlin)
                    Take(column, ':');

                candidate.column = value;
                rest = column;
            } else if (format == CompilerFormat::Kotlin) {
                continue;
            }

            if (format == CompilerFormat::Standard) {
                while (rest.starts_with('{')) {
                    size_t end = rest.find('}');
                    if (end == rest.npos || end + 1 == rest.size() || rest[end + 1] != ':')
                        break;

                    if (!candidate.endColumn)
                        ParseSourceRange(rest.substr(1, end - 1), candidate);

                    rest.remove_prefix(end + 2);
                }
            }

            size_t before = rest.size();
            SkipSpaces(rest);
            if (format == CompilerFormat::Kotlin && rest.size() == before)
                continue;
        }

        candidate.details = line.size() - rest.size();
        if (format == CompilerFormat::Standard || format == CompilerFormat::DotNet) {
            if (!TakeSeverity(rest, candidate.tone, format == CompilerFormat::Standard))
                continue;
        } else {
            if (rest.empty() || rest.front() == '\n')
                continue;

            candidate.tone = format == CompilerFormat::Go ? OutputTone::Error : kotlin_tone;
            candidate.addSeverity = true;
        }

        location = candidate;
        return true;
    }

    return false;
}

bool ParseCompilerLocation(std::string_view text, CompilerFormat fallback, CompilerLocation &location)
{
    return ParsePositionLine(text, CompilerFormat::Standard, location) ||
           (fallback != CompilerFormat::Standard && ParsePositionLine(text, fallback, location));
}

static std::string_view ReadLine(std::string_view &text)
{
    size_t end = text.find('\n');
    auto line = text.substr(0, end);
    text.remove_prefix(end == text.npos ? text.size() : end + 1);
    if (line.ends_with('\r'))
        line.remove_suffix(1);

    return line;
}

static std::string_view TrimLine(std::string_view text)
{
    SkipSpaces(text);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\t' || text.back() == '\r'))
        text.remove_suffix(1);

    return text;
}

SyntaxIssue FindScriptIssue(std::string_view output, std::string_view file, ScriptDiagnostic format)
{
    SyntaxIssue issue{};
    while (!output.empty()) {
        auto line = ReadLine(output);
        if (format == ScriptDiagnostic::Node && issue.line) {
            auto detail = TrimLine(line);
            if (detail.starts_with("SyntaxError:"))
                return {issue.line, issue.column, TrimLine(detail.substr(12))};

            if (detail.starts_with('^') && detail.find_first_not_of('^') == detail.npos)
                issue.column = detail.data() - line.data() + 1;
        }

        auto path = line.find(file);
        if (path == line.npos)
            continue;

        auto rest = line.substr(path + file.size());
        if (format == ScriptDiagnostic::PHP) {
            if (rest.starts_with(" on line ")) {
                rest.remove_prefix(9);
                if (TakeNumber(rest, issue.line)) {
                    auto details = TrimLine(line.substr(0, path));
                    if (details.ends_with(" in"))
                        details.remove_suffix(3);

                    return {issue.line, 0, details};
                }
            }
            continue;
        }

        if (rest.starts_with(" (line ")) {
            rest.remove_prefix(7);
            if (TakeNumber(rest, issue.line) && Take(rest, ')') && Take(rest, ':'))
                return {issue.line, 0, TrimLine(rest)};

            continue;
        }

        if (!Take(rest, ':'))
            continue;

        SkipSpaces(rest);
        if (rest.starts_with("line "))
            rest.remove_prefix(5);

        size_t row;
        if (!TakeNumber(rest, row) || !row)
            continue;

        if (format == ScriptDiagnostic::Node) {
            if (TrimLine(rest).empty())
                issue = {row, 0, {}};

            continue;
        }

        if (Take(rest, ':') && !TrimLine(rest).empty())
            return {row, 0, TrimLine(rest)};
    }

    return {};
}

bool ParseRuntimeLocation(std::string_view text, bool python, CompilerLocation &location)
{
    auto line = TrimLine(text);
    if (line.ends_with('\n'))
        line = TrimLine(line.substr(0, line.size() - 1));

    if (python) {
        auto path = line;
        if (!path.starts_with("File \""))
            return false;

        path.remove_prefix(6);
        size_t end = path.find("\", line ");
        if (end == path.npos || !end || path[0] == '<')
            return false;

        auto row = path.substr(end + 8);
        if (!TakeNumber(row, location.line) || (!row.empty() && row.front() != ','))
            return false;

        location.path = path.substr(0, end);
        return location.line != 0;
    }

    if (line.starts_with("at ")) {
        line.remove_prefix(3);
        if (line.ends_with(')')) {
            size_t opening = line.rfind(" (");
            if (opening != line.npos)
                line = line.substr(opening + 2, line.size() - opening - 3);
        }
    }

    size_t last = line.rfind(':');
    if (last == line.npos)
        return false;

    auto number = line.substr(last + 1);
    size_t row;
    if (!TakeNumber(number, row) || !number.empty())
        return false;

    auto path = line.substr(0, last);
    size_t middle = path.rfind(':');
    if (middle != path.npos) {
        auto earlier = path.substr(middle + 1);
        size_t first;
        if (TakeNumber(earlier, first) && earlier.empty()) {
            location.column = row;
            row = first;
            path = path.substr(0, middle);
        }
    }

    if (!path.starts_with('/') && !path.starts_with("file://"))
        return false;

    location.path = path;
    location.line = row;
    return row != 0;
}

SyntaxIssue CheckJSONText(std::string_view text, bool comments)
{
    if (text.starts_with("\xEF\xBB\xBF"))
        text.remove_prefix(3);
    auto rest = text;
    const char *error = nullptr;
    if (lsp::ReadJsonValue<true>(rest, 0, &error, comments)) {
        if (!lsp::SkipJsonTrivia(rest, comments))
            error = "Unterminated comment.";
        else if (!rest.empty())
            error = "Unexpected text after the JSON value.";
    }

    if (!error)
        return {};

    size_t row = 1, column = 1;
    auto consumed = text.substr(0, text.size() - rest.size());
    for (size_t i = 0; i < consumed.size(); ++i) {
        unsigned char byte = consumed[i];
        if (byte == '\r' || byte == '\n') {
            if (byte == '\r' && i + 1 < consumed.size() && consumed[i + 1] == '\n')
                ++i;

            ++row;
            column = 1;
        } else if ((byte & 0xC0) != 0x80) {
            ++column;
        }
    }

    return {row, column, error};
}