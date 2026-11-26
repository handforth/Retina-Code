#pragma once

#include <charconv>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace lsp {

using Json = std::string_view;

inline bool IsObject(Json value) { return !value.empty() && value.front() == '{'; }
inline bool IsArray(Json value) { return !value.empty() && value.front() == '['; }
inline bool IsString(Json value) { return !value.empty() && value.front() == '"'; }

inline bool JsonSpace(char ch) { return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t'; }
inline bool JsonDigit(char ch) { return ch >= '0' && ch <= '9'; }

inline void SkipJsonSpace(Json &input)
{
    while (!input.empty() && JsonSpace(input.front()))
        input.remove_prefix(1);
}

inline bool TakeJsonChar(Json &input, char ch)
{
    if (input.empty() || input.front() != ch)
        return false;
    input.remove_prefix(1);
    return true;
}

inline int HexDigit(char ch)
{
    if (JsonDigit(ch))
        return ch - '0';
    ch |= 32;
    return ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : -1;
}

inline size_t PlainJsonBytes(Json text)
{
    constexpr uint64_t ones = 0x0101010101010101ull;
    constexpr uint64_t highBits = ones * 128;
    auto hasSmallByte = [=](uint64_t bytes, uint64_t limit) {
        return ((bytes - ones * limit) & ~bytes & highBits) != 0;
    };
    size_t i = 0;
    for (; text.size() - i >= sizeof(uint64_t); i += sizeof(uint64_t)) {
        uint64_t bytes;
        memcpy(&bytes, text.data() + i, sizeof(bytes));
        // Check eight bytes for a control character, quote, or backslash.
        if (hasSmallByte(bytes, 32) || hasSmallByte(bytes ^ (ones * '"'), 1) || hasSmallByte(bytes ^ (ones * '\\'), 1))
            break;
    }
    for (; i < text.size(); ++i) {
        unsigned char ch = text[i];
        if (ch < 32 || ch == '"' || ch == '\\')
            break;
    }
    return i;
}

inline bool TakeJsonString(Json &input)
{
    if (!TakeJsonChar(input, '"'))
        return false;
    size_t i = PlainJsonBytes(input);
    while (i < input.size()) {
        unsigned char ch = input[i];
        if (ch == '"') {
            input.remove_prefix(i + 1);
            return true;
        }
        if (ch != '\\' || ++i == input.size())
            return false;
        ch = input[i++];
        if (ch == 'u') {
            if (input.size() - i < 4)
                return false;
            for (unsigned digit = 0; digit < 4; ++digit) {
                if (HexDigit(input[i++]) < 0)
                    return false;
            }
        } else if (Json(R"("/\bfnrt)").find(ch) == Json::npos) {
            return false;
        }
        i += PlainJsonBytes(input.substr(i));
    }
    return false;
}

inline bool TakeJsonNumber(Json &input)
{
    TakeJsonChar(input, '-');
    if (input.empty() || !JsonDigit(input.front()))
        return false;
    if (!TakeJsonChar(input, '0')) {
        while (!input.empty() && JsonDigit(input.front()))
            input.remove_prefix(1);
    }
    if (TakeJsonChar(input, '.')) {
        if (input.empty() || !JsonDigit(input.front()))
            return false;
        while (!input.empty() && JsonDigit(input.front()))
            input.remove_prefix(1);
    }
    if (!input.empty() && (input.front() == 'e' || input.front() == 'E')) {
        input.remove_prefix(1);
        if (!TakeJsonChar(input, '+'))
            TakeJsonChar(input, '-');
        if (input.empty() || !JsonDigit(input.front()))
            return false;
        while (!input.empty() && JsonDigit(input.front()))
            input.remove_prefix(1);
    }
    return true;
}

inline bool SkipJsonTrivia(Json &input, bool comments)
{
    for (;;) {
        SkipJsonSpace(input);
        if (comments && input.starts_with("//")) {
            size_t end = input.find_first_of("\r\n");
            input.remove_prefix(end == input.npos ? input.size() : end);
        } else if (comments && input.starts_with("/*")) {
            size_t end = input.find("*/", 2);
            if (end == input.npos)
                return false;
            input.remove_prefix(end + 2);
        } else {
            return true;
        }
    }
}

// File checks report the first syntax error. Protocol reads use strict JSON.
template<bool checkFile>
inline bool ReadJsonValue(Json &input, unsigned depth, const char **error, bool comments)
{
    auto trivia = [&] {
        if constexpr (checkFile)
            return SkipJsonTrivia(input, comments);
        SkipJsonSpace(input);
        return true;
    };

    auto fail = [&](const char *message) {
        if constexpr (checkFile)
            *error = message;
        return false;
    };

    if (!trivia())
        return fail("Unterminated comment.");
    if (depth > (checkFile ? 127u : 128u))
        return fail("JSON is nested too deeply.");
    if (input.empty())
        return fail("Expected a JSON value.");

    char ch = input.front();
    if (ch == '"')
        return TakeJsonString(input) || fail("Expected a JSON value.");

    if (ch == '[' || ch == '{') {
        bool object = ch == '{';
        char closing = object ? '}' : ']';
        input.remove_prefix(1);
        if (!trivia())
            return fail("Unterminated comment.");
        if (TakeJsonChar(input, closing))
            return true;

        for (;;) {
            if (object) {
                if (!TakeJsonString(input))
                    return fail("Expected a property name in double quotes.");
                if (!trivia())
                    return fail("Unterminated comment.");
                if (!TakeJsonChar(input, ':'))
                    return fail("Expected ':' after the property name.");
            }

            if (!ReadJsonValue<checkFile>(input, depth + 1, error, comments))
                return false;
            if (!trivia())
                return fail("Unterminated comment.");
            if (TakeJsonChar(input, closing))
                return true;
            if (!TakeJsonChar(input, ','))
                return fail(object ? "Expected ',' or '}'." : "Expected ',' or ']'.");
            if (!trivia())
                return fail("Unterminated comment.");

            if constexpr (checkFile) {
                if (comments && TakeJsonChar(input, closing))
                    return true;
            }
        }
    }

    Json literal = ch == 't' ? "true" : ch == 'f' ? "false" : ch == 'n' ? "null" : Json{};
    if (literal.empty())
        return TakeJsonNumber(input) || fail("Expected a JSON value.");
    if (!input.starts_with(literal))
        return fail("Expected a JSON value.");

    input.remove_prefix(literal.size());
    return true;
}

inline bool TakeJsonValue(Json &input)
{
    return ReadJsonValue<false>(input, 0, nullptr, false);
}

inline Json JsonContents(Json value)
{
    return value.size() >= 2 ? value.substr(1, value.size() - 2) : Json{};
}

inline Json NextJsonValue(Json &input)
{
    SkipJsonSpace(input);
    Json value = input;
    if (!TakeJsonValue(input)) {
        input = {};
        return {};
    }
    value = value.substr(0, value.size() - input.size());
    SkipJsonSpace(input);
    TakeJsonChar(input, ',');
    return value;
}

inline bool ReadJsonMember(Json &input, Json &key, Json &value)
{
    SkipJsonSpace(input);
    Json name = input;
    if (!TakeJsonString(input))
        return false;
    key = JsonContents(name.substr(0, name.size() - input.size()));
    SkipJsonSpace(input);
    if (!TakeJsonChar(input, ':'))
        return false;
    SkipJsonSpace(input);
    value = input;
    if (!TakeJsonValue(input)) {
        input = {};
        value = {};
        return false;
    }

    value.remove_suffix(input.size());
    return true;
}

inline bool NextJsonMember(Json &input, Json &key, Json &value)
{
    if (!ReadJsonMember(input, key, value))
        return false;

    SkipJsonSpace(input);
    TakeJsonChar(input, ',');
    return true;
}

inline void AppendUTF8(std::string &text, uint32_t scalar)
{
    if (scalar < 0x80) {
        text += char(scalar);
    } else if (scalar < 0x800) {
        text += char(0xc0 | (scalar >> 6));
        text += char(0x80 | (scalar & 63));
    } else if (scalar < 0x10000) {
        text += char(0xe0 | (scalar >> 12));
        text += char(0x80 | ((scalar >> 6) & 63));
        text += char(0x80 | (scalar & 63));
    } else {
        text += char(0xf0 | (scalar >> 18));
        text += char(0x80 | ((scalar >> 12) & 63));
        text += char(0x80 | ((scalar >> 6) & 63));
        text += char(0x80 | (scalar & 63));
    }
}

inline void DecodeJsonString(Json text, std::string &decoded)
{
    decoded.clear();
    decoded.reserve(text.size());
    auto unicode = [](Json digits) {
        uint32_t scalar = 0;
        for (char digit : digits)
            scalar = (scalar << 4) | uint32_t(HexDigit(digit));
        return scalar;
    };
    for (size_t i = 0; i < text.size(); ++i) {
        char ch = text[i];
        if (ch != '\\') {
            decoded += ch;
            continue;
        }
        ch = text[++i];
        switch (ch) {
        case 'b': decoded += '\b'; break;
        case 'f': decoded += '\f'; break;
        case 'n': decoded += '\n'; break;
        case 'r': decoded += '\r'; break;
        case 't': decoded += '\t'; break;
        case 'u': {
            uint32_t scalar = unicode(text.substr(i + 1, 4));
            i += 4;
            if (scalar >= 0xd800 && scalar <= 0xdbff && text.substr(i + 1, 2) == "\\u") {
                uint32_t low = unicode(text.substr(i + 3, 4));
                if (low >= 0xdc00 && low <= 0xdfff) {
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
                    i += 6;
                }
            }
            AppendUTF8(decoded, scalar >= 0xd800 && scalar <= 0xdfff ? 0xfffd : scalar);
            break;
        }
        default: decoded += ch; break;
        }
    }
}

inline std::string DecodeJsonString(Json text)
{
    std::string decoded;
    DecodeJsonString(text, decoded);
    return decoded;
}

inline bool JsonNameEquals(Json name, Json expected)
{
    return name == expected || (name.find('\\') != Json::npos && DecodeJsonString(name) == expected);
}

inline Json JsonField(Json value, Json name)
{
    Json input = IsObject(value) ? JsonContents(value) : Json{};
    Json key, field;
    while (NextJsonMember(input, key, field)) {
        if (JsonNameEquals(key, name))
            return field;
    }
    return {};
}

inline std::optional<int64_t> JsonInteger(Json value)
{
    if (value.empty())
        return {};
    int64_t number;
    const char *end = value.data() + value.size();
    auto result = std::from_chars(value.data(), end, number);
    if (result.ec != std::errc{} || result.ptr != end)
        return {};
    return number;
}

inline void AppendJsonString(std::string &out, Json text)
{
    out += '"';
    while (!text.empty()) {
        size_t length = PlainJsonBytes(text);
        out.append(text.substr(0, length));
        if (length == text.size())
            break;
        unsigned char ch = text[length];
        text.remove_prefix(length + 1);
        switch (ch) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default: {
            constexpr char hex[] = "0123456789abcdef";
            out += "\\u00";
            out += hex[ch >> 4];
            out += hex[ch & 15];
            break;
        }
        }
    }
    out += '"';
}

inline std::string QuoteJson(Json text)
{
    std::string result;
    result.reserve(text.size() + 2);
    AppendJsonString(result, text);
    return result;
}

inline std::string JsonObject(std::initializer_list<std::pair<Json, Json>> fields)
{
    std::string result = "{";
    for (const auto &[name, value] : fields) {
        if (result.size() > 1)
            result += ',';
        AppendJsonString(result, name);
        result += ':';
        result += value;
    }
    result += '}';
    return result;
}

} // namespace lsp