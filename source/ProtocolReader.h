#pragma once

#include <algorithm>
#include <charconv>
#include <string>
#include <string_view>
#include <vector>

struct ProtocolReader {
    std::vector<char> partial;
    size_t bodyLength = 0;
};

enum class ProtocolReadResult { Valid, InvalidHeader, Rejected };

inline void AppendProtocolMessage(std::string &bytes, std::string_view body)
{
    char length[24];
    auto end = std::to_chars(length, length + sizeof(length), body.size()).ptr;
    bytes += "Content-Length: ";
    bytes.append(length, end);
    bytes += "\r\n\r\n";
    bytes += body;
}

static inline size_t ProtocolContentLength(std::string_view header, size_t limit)
{
    constexpr std::string_view name = "content-length:";
    while (!header.empty()) {
        size_t end = header.find("\r\n");
        auto line = header.substr(0, end);
        if (line.size() >= name.size() && std::equal(name.begin(), name.end(), line.begin(),
            [](char lower, char byte) {
                if (byte >= 'A' && byte <= 'Z')
                    byte += 'a' - 'A';
                return lower == byte;
            })) {
            line.remove_prefix(name.size());
            size_t start = line.find_first_not_of(" \t");
            if (start == std::string_view::npos)
                return 0;
            line = line.substr(start, line.find_last_not_of(" \t") - start + 1);
            size_t length = 0;
            const char *last = line.data() + line.size();
            auto result = std::from_chars(line.data(), last, length);
            return result.ec == std::errc{} && result.ptr == last && length <= limit ? length : 0;
        }
        if (end == std::string_view::npos)
            break;
        header.remove_prefix(end + 2);
    }
    return 0;
}

template<class Receive>
ProtocolReadResult ReadProtocolMessages(ProtocolReader &reader, std::string_view input,
                                        size_t headerLimit, size_t bodyLimit, Receive receive)
{
    bool buffered = !reader.partial.empty();
    if (buffered) {
        reader.partial.insert(reader.partial.end(), input.begin(), input.end());
        input = {reader.partial.data(), reader.partial.size()};
    }
    while (!input.empty()) {
        if (!reader.bodyLength) {
            size_t end = input.find("\r\n\r\n");
            if (end == std::string_view::npos && input.size() <= headerLimit)
                break;
            if (end > headerLimit || !(reader.bodyLength = ProtocolContentLength(input.substr(0, end), bodyLimit)))
                return ProtocolReadResult::InvalidHeader;
            input.remove_prefix(end + 4);
        }
        if (input.size() < reader.bodyLength)
            break;
        if (!receive(input.substr(0, reader.bodyLength)))
            return ProtocolReadResult::Rejected;
        input.remove_prefix(reader.bodyLength);
        reader.bodyLength = 0;
    }

    // Complete packets can be parsed from the pipe's buffer. Save only a partial packet.
    if (buffered) {
        if (reader.partial.capacity() > 256 * 1024 && input.size() < 4096)
            reader.partial = std::vector<char>(input.begin(), input.end());
        else
            reader.partial.erase(reader.partial.begin(), reader.partial.end() - input.size());
    } else if (!input.empty()) {
        reader.partial.assign(input.begin(), input.end());
    }
    return ProtocolReadResult::Valid;
}