#pragma once

#include <cstdint>

// A packed color: red in the low byte, then green, blue, and alpha in the high byte.
typedef uint32_t Col32;

// Each channel keeps only its low 8 bits. Alpha runs from 0 to 1.
constexpr Col32 rgba(uint32_t red, uint32_t green, uint32_t blue, float alpha)
{
    return Col32(uint8_t(red)) | (Col32(uint8_t(green)) << 8) | (Col32(uint8_t(blue)) << 16) |
           ((Col32(alpha * 255.0f) & 0xFFu) << 24);
}

constexpr Col32 rgb(uint32_t red, uint32_t green, uint32_t blue)
{
    return rgba(red, green, blue, 1.0f);
}

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