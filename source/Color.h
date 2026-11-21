#pragma once

#include <cstdint>

typedef uint32_t Col32;

#define rgba(r, g, b, a) (Col32(uint8_t(r)) | (Col32(uint8_t(g)) << 8) | \
                          (Col32(uint8_t(b)) << 16) | ((Col32((a) * 255.0f) & 0xFFu) << 24))
#define rgb(r, g, b) rgba((r), (g), (b), 1.0f)

constexpr uint8_t ColorRed(Col32 color)
{
    return uint8_t(color);
}

constexpr uint8_t ColorGreen(Col32 color)
{
    return uint8_t(color >> 8);
}

constexpr uint8_t ColorBlue(Col32 color)
{
    return uint8_t(color >> 16);
}

constexpr uint8_t ColorAlpha(Col32 color)
{
    return uint8_t(color >> 24);
}