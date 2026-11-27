#pragma once

#include "Themes.h"

#include <algorithm>
#include <cmath>

struct PopupColors {
    Col32 paper, border, selection, text, selectedText;
    bool operator==(const PopupColors &) const = default;
};

inline Col32 PopupFill(Col32 color, Col32 underneath)
{
    if (ColorAlpha(color) == 255)
        return color;
    return BlendColor(underneath, color, (ColorAlpha(color) * 100 + 127) / 255) | rgb(0, 0, 0);
}

inline Col32 PopupText(Col32 ink, Col32 paper)
{
    auto luminance = [](Col32 color) {
        auto linear = [](uint8_t channel) {
            double value = channel / 255.0;
            return value <= 0.04045 ? value / 12.92 : std::pow((value + 0.055) / 1.055, 2.4);
        };
        return 0.2126 * linear(ColorRed(color)) + 0.7152 * linear(ColorGreen(color)) + 0.0722 * linear(ColorBlue(color));
    };
    ink = PopupFill(ink, paper);
    double background = luminance(paper) + 0.05;
    double foreground = luminance(ink) + 0.05;
    if (std::max(background, foreground) >= 4.5 * std::min(background, foreground))
        return ink;
    return background < 0.22913 ? rgb(255, 255, 255) : rgb(0, 0, 0);
}

inline PopupColors EditorPopupColors(const Theme &theme)
{
    const EditorAccents &accents = theme.accents;
    Col32 paper = PopupFill(accents.completionPaper, theme.paper | rgb(0, 0, 0));
    Col32 text = PopupText(theme.ink[size_t(Ink::Text)], paper);
    Col32 selection = PopupFill(accents.completionSelection, paper);
    int difference = std::max({std::abs(ColorRed(selection) - ColorRed(paper)),
                               std::abs(ColorGreen(selection) - ColorGreen(paper)),
                               std::abs(ColorBlue(selection) - ColorBlue(paper))});
    if (difference < 16)
        selection = BlendColor(selection, text, 17);

    return {paper, accents.completionBorder, selection, text, PopupText(accents.completionSelectedText, selection)};
}
