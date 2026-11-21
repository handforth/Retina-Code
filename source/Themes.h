#pragma once

#include "Color.h"
#include "Lexer.hpp"

#include <algorithm>
#include <array>
#include <memory>
#include <optional>
#include <span>

constexpr Col32 BlendColor(Col32 first, Col32 second, unsigned percent)
{
    Col32 color = 0;
    for (unsigned shift : {0U, 8U, 16U, 24U}) {
        auto a = (first >> shift) & 255U;
        auto b = (second >> shift) & 255U;
        color |= ((a * (100 - percent) + b * percent + 50) / 100) << shift;
    }
    return color;
}

constexpr int ColorLuma(Col32 color)
{
    return (54 * ColorRed(color) + 183 * ColorGreen(color) + 19 * ColorBlue(color) + 128) >> 8;
}

constexpr Col32 DefaultWhitespaceColor(Col32 paper, Col32 line, Col32 selection,
                                          Col32 lineNumber, bool dark)
{
    Col32 color = BlendColor(paper, lineNumber, dark ? 63 : 60);
    int luma = ColorLuma(color);
    // The same marker also needs to read over the active line and selection.
    if (dark) {
        int target = std::min(255, std::max({ColorLuma(paper), ColorLuma(line), ColorLuma(selection)}) + 46);
        if (luma < target)
            color = BlendColor(color, rgb(255, 255, 255), (100 * (target - luma) + 254 - luma) / (255 - luma));
    } else {
        int target = std::max(0, std::min({ColorLuma(paper), ColorLuma(line), ColorLuma(selection)}) - 55);
        if (luma > target)
            color = BlendColor(color, rgb(0, 0, 0), (100 * (luma - target) + luma - 1) / luma);
    }
    return color;
}

struct EditorAccents {
    Col32 completionPaper;
    Col32 completionBorder = rgb(160, 160, 160);
    Col32 completionSelection = rgb(48, 108, 186);
    Col32 completionSelectedText = rgb(255, 255, 255);
    Col32 wordMatch = rgb(56, 118, 197);
    Col32 bracketMatch = rgb(120, 168, 232);
    Col32 vimFlash = wordMatch;
    Col32 commandCaret = rgb(179, 202, 230);
};

struct Theme {
    const char *name;
    Col32 paper;
    Col32 line;
    Col32 selection;
    Col32 gutter;
    Col32 rule;
    Col32 lineNumber;
    Col32 activeNumber;
    std::array<Col32, size_t(Ink::Count)> ink;
    EditorAccents accents;
    std::optional<Col32> caret = {};
    bool dark = false;
    bool italicTypes = false;
    std::span<const Col32> bracketColors = {};
    Col32 whitespace = DefaultWhitespaceColor(paper, line, selection, lineNumber, dark);
    std::optional<Col32> blockCaretText = {};
    bool italicComments = false;
    bool contrastingSelectionText = false;
};

using ThemeRef = std::shared_ptr<const Theme>;

inline ThemeRef StaticTheme(const Theme *theme)
{
    // Built-in palettes already have static storage.
    return ThemeRef(ThemeRef{}, theme);
}

constexpr Theme ClassicTheme(const char *name, Col32 paper, Col32 line, Col32 selection,
                             std::array<Col32, size_t(Ink::Count)> ink, Col32 accent,
                             Col32 vimFlash, bool dark = false,
                             std::span<const Col32> brackets = {})
{
    Col32 text = ink[size_t(Ink::Text)];
    return {name, paper, line, selection, BlendColor(paper, text, dark ? 5 : 6),
            BlendColor(paper, text, 16), BlendColor(paper, text, 58), text, ink,
            {.completionPaper = BlendColor(paper, text, dark ? 7 : 3),
             .completionBorder = BlendColor(paper, accent, 36),
             .completionSelection = selection, .completionSelectedText = text,
             .wordMatch = accent, .bracketMatch = accent,
             .vimFlash = vimFlash, .commandCaret = BlendColor(paper, accent, 34)},
            {}, dark, false, brackets};
}

constexpr Theme XcodeTheme(const char *name, Col32 paper, Col32 line, Col32 selection,
                           std::array<Col32, size_t(Ink::Count)> ink, Col32 caret,
                           Col32 whitespace, Col32 vimFlash, bool dark = false)
{
    Theme theme = ClassicTheme(name, paper, line, selection, ink, ink[size_t(Ink::Function)], vimFlash, dark);
    theme.caret = caret;
    theme.whitespace = whitespace;
    theme.blockCaretText = paper;
    theme.contrastingSelectionText = true;
    return theme;
}

inline constexpr Col32 darkModernBrackets[] = {rgb(255, 215, 0), rgb(218, 112, 214), rgb(23, 159, 255)};
inline constexpr Col32 codeBlocksBrackets[] = {rgb(37, 39, 161), rgb(147, 34, 116), rgb(22, 112, 75), rgb(146, 90, 6)};
inline constexpr Col32 obsidianBrackets[] = {rgb(130, 206, 241), rgb(213, 168, 237), rgb(240, 185, 107), rgb(172, 217, 118)};
inline constexpr Col32 metroBrackets[] = {rgb(92, 197, 255), rgb(255, 205, 77), rgb(255, 133, 225), rgb(189, 235, 57)};
inline constexpr Col32 gameMakerBrackets[] = {rgb(114, 191, 255)};

inline constexpr std::array<Col32, size_t(Ink::Count)> monokaiInk = {
    rgb(248, 248, 242), rgb(249, 38, 114), rgb(249, 38, 114), rgb(102, 217, 239),
    rgb(166, 226, 46), rgb(248, 248, 242), rgb(230, 219, 116), rgb(174, 129, 255),
    rgb(117, 113, 94), rgb(249, 38, 114), rgb(174, 129, 255), rgb(174, 129, 255),
};

// creator-dark.xml and dark-2024.xml share syntax colors. Lighten the dim number ink.
inline constexpr std::array<Col32, size_t(Ink::Count)> qtCreatorDarkInk = {
    rgb(214, 207, 154), rgb(69, 198, 214), rgb(69, 198, 214), rgb(255, 128, 128),
    rgb(214, 207, 154), rgb(214, 187, 154), rgb(214, 149, 69), rgb(191, 153, 109),
    rgb(168, 171, 176), rgb(255, 106, 173), rgb(214, 197, 64), rgb(154, 167, 214),
};

inline constexpr EditorAccents qtCreatorDarkAccents = {
    .completionPaper = rgb(48, 51, 52), .completionBorder = rgb(81, 88, 91),
    .completionSelection = rgb(29, 84, 92), .completionSelectedText = rgb(214, 207, 154),
    .wordMatch = rgb(138, 64, 44), .bracketMatch = rgb(154, 167, 214), .vimFlash = rgb(66, 124, 134),
     .commandCaret = rgb(69, 198, 214),
};

namespace Base2Tone {

using Shades = std::array<Col32, 8>;

struct ThemePair {
    Theme dark;
    Theme light;
};

// Keep the upstream A through D shade order. The published Prism palettes set the
// syntax inks, and the editor themes supply colors for the gutter and popups.
constexpr ThemePair MakePair(const char *darkName, const char *lightName,
                             const Shades &baseA, const Shades &baseB, const Shades &baseC, const Shades &baseD,
                             Col32 darkPopup)
{
    return {
        {darkName, baseA[0], baseA[1], baseA[2], BlendColor(baseA[0], darkPopup, 39), baseA[2], baseA[3], baseA[6],
         {baseA[7], baseD[7], baseD[7], baseB[3], baseB[3], baseD[7], baseD[7], baseD[2],
          baseA[3], baseD[7], baseB[7], baseD[4]},
         {.completionPaper = baseA[1], .completionBorder = darkPopup,
          .completionSelection = darkPopup, .completionSelectedText = baseC[5],
          .wordMatch = baseB[3], .bracketMatch = baseA[4], .vimFlash = baseD[4], .commandCaret = baseA[3]},
         baseB[3], true, false, {}, baseA[4], baseA[0]},
        {lightName, baseC[7], baseC[6], baseC[5], BlendColor(baseC[7], baseC[6], 39), baseC[5], baseC[3], baseC[1],
         {baseC[0], baseB[2], baseB[2], baseD[2], baseD[2], baseD[0], baseB[2], baseB[0],
          baseC[4], baseB[2], baseD[0], baseD[3]},
         {.completionPaper = baseC[6], .completionBorder = baseC[5],
          .completionSelection = baseC[5], .completionSelectedText = baseC[0],
          .wordMatch = baseD[0], .bracketMatch = baseC[4], .vimFlash = baseD[0], .commandCaret = baseC[5]},
         baseB[0], false, false, {}, baseC[3], baseC[7]},
    };
}

inline constexpr ThemePair cave = MakePair("Base2Tone Cave Dark", "Base2Tone Cave Light",
    {rgb(34, 32, 33), rgb(47, 45, 46), rgb(86, 82, 84), rgb(99, 95, 96),
     rgb(112, 107, 109), rgb(138, 133, 134), rgb(159, 153, 155), rgb(179, 173, 175)},
    {rgb(173, 31, 81), rgb(135, 94, 109), rgb(147, 108, 122), rgb(156, 129, 139),
     rgb(210, 121, 152), rgb(226, 141, 171), rgb(240, 168, 193), rgb(255, 235, 242)},
    {rgb(120, 118, 115), rgb(139, 137, 132), rgb(157, 155, 149), rgb(174, 172, 167),
     rgb(193, 190, 185), rgb(214, 211, 204), rgb(234, 231, 225), rgb(251, 250, 249)},
    {rgb(153, 110, 0), rgb(170, 124, 9), rgb(184, 137, 20), rgb(195, 150, 34),
     rgb(204, 161, 51), rgb(221, 175, 60), rgb(235, 188, 71), rgb(255, 204, 77)},
    rgb(21, 20, 20));

inline constexpr ThemePair desert = MakePair("Base2Tone Desert Dark", "Base2Tone Desert Light",
    {rgb(41, 39, 36), rgb(61, 58, 52), rgb(97, 92, 81), rgb(126, 119, 103),
     rgb(144, 135, 116), rgb(159, 150, 132), rgb(173, 165, 148), rgb(187, 180, 165)},
    {rgb(92, 82, 61), rgb(110, 96, 69), rgb(129, 111, 75), rgb(149, 126, 80),
     rgb(172, 142, 83), rgb(198, 173, 123), rgb(221, 203, 166), rgb(242, 234, 217)},
    {rgb(132, 123, 117), rgb(151, 141, 135), rgb(168, 159, 153), rgb(185, 177, 172),
     rgb(202, 195, 190), rgb(220, 213, 208), rgb(237, 231, 227), rgb(251, 250, 249)},
    {rgb(188, 103, 47), rgb(211, 114, 49), rgb(221, 124, 60), rgb(229, 135, 72),
     rgb(236, 146, 85), rgb(242, 157, 99), rgb(248, 168, 114), rgb(255, 179, 128)},
    rgb(27, 26, 24));

inline constexpr ThemePair drawbridge = MakePair("Base2Tone Drawbridge Dark", "Base2Tone Drawbridge Light",
    {rgb(27, 31, 50), rgb(37, 42, 65), rgb(68, 75, 111), rgb(81, 88, 123),
     rgb(94, 101, 135), rgb(121, 126, 150), rgb(144, 148, 167), rgb(166, 170, 185)},
    {rgb(73, 97, 218), rgb(81, 106, 236), rgb(98, 122, 244), rgb(114, 137, 253),
     rgb(139, 158, 253), rgb(165, 179, 254), rgb(195, 205, 254), rgb(225, 230, 255)},
    {rgb(113, 120, 122), rgb(129, 139, 141), rgb(147, 156, 159), rgb(166, 174, 176),
     rgb(183, 192, 194), rgb(203, 212, 215), rgb(225, 232, 234), rgb(249, 251, 251)},
    {rgb(40, 157, 189), rgb(51, 171, 204), rgb(77, 176, 203), rgb(92, 188, 214),
     rgb(103, 201, 228), rgb(117, 213, 240), rgb(134, 224, 249), rgb(153, 233, 255)},
    rgb(19, 21, 32));

inline constexpr ThemePair earth = MakePair("Base2Tone Earth Dark", "Base2Tone Earth Light",
    {rgb(50, 45, 41), rgb(63, 58, 55), rgb(91, 83, 77), rgb(106, 95, 88),
     rgb(121, 107, 99), rgb(163, 148, 138), rgb(181, 169, 161), rgb(199, 190, 184)},
    {rgb(111, 88, 73), rgb(120, 98, 84), rgb(129, 109, 95), rgb(136, 120, 109),
     rgb(150, 126, 110), rgb(164, 135, 116), rgb(223, 185, 159), rgb(255, 243, 235)},
    {rgb(115, 109, 94), rgb(136, 128, 109), rgb(154, 146, 126), rgb(170, 163, 146),
     rgb(187, 180, 165), rgb(207, 201, 185), rgb(226, 220, 208), rgb(242, 239, 232)},
    {rgb(156, 131, 73), rgb(179, 148, 77), rgb(191, 160, 90), rgb(205, 169, 86),
     rgb(217, 177, 84), rgb(230, 184, 77), rgb(241, 190, 70), rgb(252, 196, 64)},
    rgb(36, 33, 30));

inline constexpr ThemePair evening = MakePair("Base2Tone Evening Dark", "Base2Tone Evening Light",
    {rgb(42, 39, 52), rgb(54, 51, 66), rgb(84, 81, 103), rgb(108, 103, 131),
     rgb(120, 115, 145), rgb(142, 138, 163), rgb(164, 161, 181), rgb(186, 184, 199)},
    {rgb(106, 81, 230), rgb(122, 99, 238), rgb(138, 117, 245), rgb(154, 134, 253),
     rgb(175, 160, 254), rgb(196, 185, 254), rgb(217, 210, 254), rgb(238, 235, 255)},
    {rgb(124, 117, 110), rgb(144, 135, 127), rgb(161, 153, 145), rgb(178, 171, 164),
     rgb(195, 189, 182), rgb(216, 209, 202), rgb(235, 230, 224), rgb(251, 250, 249)},
    {rgb(179, 117, 55), rgb(203, 130, 58), rgb(224, 145, 66), rgb(255, 161, 66),
     rgb(255, 173, 92), rgb(255, 184, 112), rgb(255, 194, 133), rgb(255, 204, 153)},
    rgb(31, 30, 37));

inline constexpr ThemePair field = MakePair("Base2Tone Field Dark", "Base2Tone Field Light",
    {rgb(24, 32, 30), rgb(36, 46, 44), rgb(66, 82, 79), rgb(90, 109, 106),
     rgb(102, 122, 119), rgb(120, 145, 141), rgb(142, 164, 160), rgb(164, 183, 180)},
    {rgb(3, 119, 100), rgb(8, 155, 131), rgb(15, 189, 160), rgb(37, 208, 180),
     rgb(64, 221, 195), rgb(101, 230, 209), rgb(136, 242, 224), rgb(168, 255, 241)},
    {rgb(104, 115, 109), rgb(120, 135, 126), rgb(138, 153, 144), rgb(157, 170, 162),
     rgb(174, 188, 180), rgb(199, 209, 203), rgb(227, 232, 229), rgb(249, 251, 250)},
    {rgb(0, 148, 62), rgb(14, 170, 79), rgb(21, 193, 93), rgb(37, 212, 110),
     rgb(59, 227, 129), rgb(85, 236, 148), rgb(105, 247, 164), rgb(133, 255, 184)},
    rgb(14, 17, 16));

inline constexpr ThemePair forest = MakePair("Base2Tone Forest Dark", "Base2Tone Forest Light",
    {rgb(42, 45, 42), rgb(53, 59, 53), rgb(72, 81, 72), rgb(83, 95, 83),
     rgb(94, 110, 94), rgb(104, 125, 104), rgb(161, 181, 161), rgb(184, 199, 184)},
    {rgb(67, 86, 67), rgb(79, 99, 79), rgb(92, 112, 92), rgb(104, 125, 104),
     rgb(143, 174, 143), rgb(179, 214, 179), rgb(200, 228, 200), rgb(240, 255, 240)},
    {rgb(125, 129, 106), rgb(144, 148, 122), rgb(161, 165, 141), rgb(178, 181, 161),
     rgb(195, 198, 179), rgb(215, 218, 200), rgb(234, 236, 223), rgb(251, 251, 248)},
    {rgb(101, 107, 71), rgb(129, 139, 75), rgb(162, 179, 77), rgb(177, 196, 79),
     rgb(191, 212, 84), rgb(203, 226, 90), rgb(218, 240, 106), rgb(229, 251, 121)},
    rgb(30, 31, 30));

inline constexpr ThemePair garden = MakePair("Base2Tone Garden Dark", "Base2Tone Garden Light",
    {rgb(30, 31, 30), rgb(43, 44, 42), rgb(80, 83, 80), rgb(93, 96, 92),
     rgb(105, 109, 105), rgb(130, 135, 130), rgb(150, 156, 150), rgb(170, 177, 170)},
    {rgb(28, 130, 23), rgb(37, 147, 31), rgb(63, 172, 57), rgb(76, 185, 70),
     rgb(107, 204, 102), rgb(144, 217, 140), rgb(183, 227, 181), rgb(220, 240, 219)},
    {rgb(131, 116, 103), rgb(151, 134, 120), rgb(167, 152, 139), rgb(183, 170, 159),
     rgb(199, 188, 178), rgb(219, 208, 199), rgb(236, 229, 223), rgb(251, 250, 248)},
    {rgb(189, 93, 15), rgb(201, 106, 29), rgb(217, 119, 38), rgb(221, 132, 60),
     rgb(219, 146, 87), rgb(219, 160, 112), rgb(217, 175, 140), rgb(224, 202, 184)},
    rgb(17, 18, 17));

inline constexpr ThemePair heath = MakePair("Base2Tone Heath Dark", "Base2Tone Heath Light",
    {rgb(34, 32, 34), rgb(47, 45, 47), rgb(87, 81, 88), rgb(99, 95, 99),
     rgb(111, 107, 112), rgb(137, 133, 138), rgb(158, 153, 159), rgb(179, 173, 179)},
    {rgb(162, 31, 173), rgb(132, 94, 135), rgb(143, 108, 147), rgb(154, 129, 156),
     rgb(203, 121, 210), rgb(219, 141, 226), rgb(234, 168, 240), rgb(253, 235, 255)},
    {rgb(120, 118, 115), rgb(139, 136, 132), rgb(157, 154, 149), rgb(174, 171, 167),
     rgb(193, 189, 185), rgb(214, 210, 204), rgb(234, 230, 225), rgb(251, 250, 249)},
    {rgb(153, 89, 0), rgb(170, 103, 9), rgb(184, 116, 20), rgb(195, 128, 34),
     rgb(204, 140, 51), rgb(217, 185, 140), rgb(230, 198, 153), rgb(255, 213, 153)},
    rgb(21, 20, 21));

inline constexpr ThemePair lake = MakePair("Base2Tone Lake Dark", "Base2Tone Lake Light",
    {rgb(25, 45, 52), rgb(34, 60, 68), rgb(51, 89, 102), rgb(61, 104, 118),
     rgb(70, 118, 134), rgb(80, 132, 149), rgb(123, 168, 183), rgb(173, 200, 209)},
    {rgb(47, 114, 137), rgb(54, 130, 155), rgb(62, 145, 172), rgb(73, 159, 188),
     rgb(98, 177, 203), rgb(125, 194, 217), rgb(165, 216, 233), rgb(225, 247, 255)},
    {rgb(122, 121, 113), rgb(141, 140, 129), rgb(159, 157, 147), rgb(177, 175, 165),
     rgb(194, 193, 183), rgb(213, 212, 205), rgb(232, 231, 227), rgb(250, 250, 249)},
    {rgb(132, 116, 11), rgb(151, 134, 17), rgb(183, 162, 26), rgb(196, 176, 49),
     rgb(203, 187, 77), rgb(214, 198, 92), rgb(233, 215, 99), rgb(255, 235, 102)},
    rgb(18, 29, 33));

inline constexpr ThemePair lavender = MakePair("Base2Tone Lavender Dark", "Base2Tone Lavender Light",
    {rgb(32, 29, 42), rgb(44, 40, 57), rgb(75, 69, 95), rgb(98, 90, 124),
     rgb(110, 101, 139), rgb(130, 122, 159), rgb(153, 146, 176), rgb(175, 169, 193)},
    {rgb(116, 81, 230), rgb(131, 99, 238), rgb(147, 117, 245), rgb(162, 134, 253),
     rgb(181, 160, 254), rgb(201, 185, 254), rgb(220, 210, 254), rgb(239, 235, 255)},
    {rgb(124, 111, 133), rgb(142, 129, 152), rgb(160, 146, 170), rgb(178, 164, 188),
     rgb(196, 182, 206), rgb(216, 204, 224), rgb(236, 228, 241), rgb(250, 248, 252)},
    {rgb(176, 66, 255), rgb(185, 87, 255), rgb(193, 107, 255), rgb(202, 128, 255),
     rgb(210, 148, 255), rgb(219, 168, 255), rgb(227, 189, 255), rgb(236, 209, 255)},
    rgb(21, 20, 26));

inline constexpr ThemePair mall = MakePair("Base2Tone Mall Dark", "Base2Tone Mall Light",
    {rgb(30, 30, 31), rgb(43, 43, 44), rgb(81, 80, 83), rgb(94, 92, 96),
     rgb(106, 104, 110), rgb(131, 129, 136), rgb(151, 149, 157), rgb(172, 170, 177)},
    {rgb(133, 94, 232), rgb(147, 109, 243), rgb(161, 126, 252), rgb(178, 148, 255),
     rgb(197, 173, 255), rgb(211, 194, 255), rgb(229, 219, 255), rgb(244, 240, 255)},
    {rgb(109, 118, 126), rgb(126, 136, 145), rgb(144, 154, 162), rgb(162, 171, 179),
     rgb(181, 189, 196), rgb(200, 210, 218), rgb(222, 230, 237), rgb(248, 250, 252)},
    {rgb(54, 146, 226), rgb(71, 158, 235), rgb(90, 171, 242), rgb(105, 181, 247),
     rgb(117, 191, 255), rgb(138, 200, 255), rgb(158, 210, 255), rgb(179, 219, 255)},
    rgb(17, 17, 18));

inline constexpr ThemePair meadow = MakePair("Base2Tone Meadow Dark", "Base2Tone Meadow Light",
    {rgb(25, 40, 52), rgb(34, 54, 68), rgb(51, 81, 102), rgb(61, 94, 118),
     rgb(70, 107, 134), rgb(80, 120, 149), rgb(123, 158, 183), rgb(123, 158, 183)},
    {rgb(27, 100, 152), rgb(33, 114, 171), rgb(39, 127, 190), rgb(66, 153, 215),
     rgb(71, 173, 245), rgb(141, 206, 252), rgb(175, 221, 254), rgb(209, 236, 255)},
    {rgb(117, 123, 111), rgb(135, 142, 128), rgb(153, 160, 146), rgb(171, 177, 165),
     rgb(189, 195, 183), rgb(209, 214, 205), rgb(230, 232, 227), rgb(250, 251, 249)},
    {rgb(77, 130, 23), rgb(89, 147, 31), rgb(102, 163, 41), rgb(115, 178, 52),
     rgb(128, 191, 64), rgb(140, 221, 60), rgb(153, 235, 71), rgb(166, 246, 85)},
    rgb(18, 26, 33));

inline constexpr ThemePair morning = MakePair("Base2Tone Morning Dark", "Base2Tone Morning Light",
    {rgb(35, 40, 52), rgb(49, 54, 63), rgb(79, 86, 100), rgb(101, 110, 129),
     rgb(112, 122, 143), rgb(126, 136, 154), rgb(141, 149, 165), rgb(169, 175, 188)},
    {rgb(6, 50, 137), rgb(11, 60, 157), rgb(22, 89, 223), rgb(61, 117, 230),
     rgb(114, 143, 203), rgb(147, 171, 220), rgb(183, 201, 235), rgb(222, 230, 247)},
    {rgb(84, 77, 64), rgb(105, 96, 79), rgb(134, 123, 101), rgb(156, 146, 124),
     rgb(182, 173, 154), rgb(205, 196, 177), rgb(227, 220, 206), rgb(250, 248, 245)},
    {rgb(45, 32, 6), rgb(89, 66, 18), rgb(137, 103, 36), rgb(154, 124, 66),
     rgb(178, 151, 98), rgb(198, 178, 139), rgb(209, 194, 163), rgb(229, 221, 205)},
    rgb(25, 29, 36));

inline constexpr ThemePair motel = MakePair("Base2Tone Motel Dark", "Base2Tone Motel Light",
    {rgb(36, 35, 35), rgb(55, 52, 52), rgb(90, 83, 84), rgb(118, 107, 108),
     rgb(134, 121, 123), rgb(148, 137, 139), rgb(165, 151, 154), rgb(179, 168, 170)},
    {rgb(103, 76, 80), rgb(125, 94, 99), rgb(149, 111, 118), rgb(167, 134, 139),
     rgb(184, 157, 162), rgb(204, 179, 183), rgb(222, 201, 204), rgb(240, 219, 223)},
    {rgb(132, 120, 117), rgb(151, 138, 135), rgb(168, 156, 153), rgb(185, 174, 172),
     rgb(202, 192, 190), rgb(220, 210, 208), rgb(237, 229, 227), rgb(251, 249, 249)},
    {rgb(226, 79, 50), rgb(234, 95, 67), rgb(246, 104, 76), rgb(247, 124, 100),
     rgb(248, 145, 124), rgb(255, 162, 143), rgb(255, 179, 163), rgb(255, 200, 189)},
    rgb(23, 23, 23));

inline constexpr ThemePair pool = MakePair("Base2Tone Pool Dark", "Base2Tone Pool Light",
    {rgb(42, 36, 51), rgb(55, 47, 66), rgb(87, 75, 104), rgb(99, 87, 117),
     rgb(112, 99, 131), rgb(133, 120, 151), rgb(154, 144, 167), rgb(175, 167, 185)},
    {rgb(143, 81, 230), rgb(157, 99, 238), rgb(170, 117, 245), rgb(184, 134, 253),
     rgb(199, 160, 254), rgb(214, 185, 254), rgb(228, 210, 254), rgb(243, 235, 255)},
    {rgb(122, 113, 113), rgb(141, 130, 129), rgb(159, 147, 147), rgb(176, 166, 166),
     rgb(194, 184, 183), rgb(215, 204, 203), rgb(234, 225, 225), rgb(251, 249, 249)},
    {rgb(207, 80, 74), rgb(217, 95, 89), rgb(237, 101, 94), rgb(243, 111, 104),
     rgb(248, 121, 114), rgb(252, 137, 131), rgb(255, 158, 153), rgb(255, 182, 179)},
    rgb(30, 27, 34));

inline constexpr ThemePair porch = MakePair("Base2Tone Porch Dark", "Base2Tone Porch Light",
    {rgb(34, 30, 36), rgb(48, 42, 50), rgb(87, 78, 90), rgb(100, 90, 104),
     rgb(113, 103, 116), rgb(139, 128, 142), rgb(159, 149, 163), rgb(179, 170, 181)},
    {rgb(103, 69, 115), rgb(126, 84, 140), rgb(148, 102, 163), rgb(167, 124, 182),
     rgb(186, 149, 198), rgb(205, 172, 215), rgb(223, 203, 230), rgb(242, 227, 247)},
    {rgb(126, 115, 109), rgb(145, 133, 126), rgb(162, 151, 144), rgb(179, 169, 162),
     rgb(196, 187, 181), rgb(218, 207, 200), rgb(237, 227, 222), rgb(252, 249, 248)},
    {rgb(196, 103, 49), rgb(217, 113, 54), rgb(225, 127, 71), rgb(236, 141, 85),
     rgb(243, 155, 104), rgb(248, 170, 124), rgb(252, 181, 141), rgb(255, 194, 158)},
    rgb(21, 19, 22));

inline constexpr ThemePair sea = MakePair("Base2Tone Sea Dark", "Base2Tone Sea Light",
    {rgb(29, 38, 47), rgb(39, 50, 63), rgb(64, 83, 104), rgb(74, 95, 120),
     rgb(115, 129, 145), rgb(138, 150, 163), rgb(161, 170, 181), rgb(184, 191, 199)},
    {rgb(0, 74, 158), rgb(23, 87, 161), rgb(52, 101, 157), rgb(87, 113, 142),
     rgb(110, 155, 207), rgb(126, 182, 246), rgb(175, 212, 254), rgb(235, 244, 255)},
    {rgb(113, 122, 119), rgb(129, 141, 137), rgb(147, 159, 155), rgb(166, 176, 173),
     rgb(183, 194, 190), rgb(203, 215, 211), rgb(225, 234, 231), rgb(249, 251, 250)},
    {rgb(6, 121, 83), rgb(8, 140, 96), rgb(10, 163, 112), rgb(13, 181, 125),
     rgb(15, 199, 138), rgb(20, 225, 157), rgb(42, 234, 170), rgb(71, 235, 180)},
    rgb(20, 25, 31));

inline constexpr ThemePair space = MakePair("Base2Tone Space Dark", "Base2Tone Space Light",
    {rgb(36, 36, 46), rgb(51, 51, 66), rgb(81, 81, 103), rgb(91, 91, 118),
     rgb(115, 115, 145), rgb(138, 138, 163), rgb(161, 161, 181), rgb(184, 184, 199)},
    {rgb(81, 81, 230), rgb(99, 99, 238), rgb(118, 118, 244), rgb(118, 118, 147),
     rgb(138, 138, 173), rgb(170, 170, 202), rgb(206, 206, 227), rgb(235, 235, 255)},
    {rgb(123, 115, 111), rgb(142, 133, 128), rgb(160, 151, 146), rgb(177, 169, 165),
     rgb(195, 187, 183), rgb(216, 207, 203), rgb(234, 228, 225), rgb(251, 249, 249)},
    {rgb(178, 84, 36), rgb(203, 92, 37), rgb(221, 103, 44), rgb(230, 110, 51),
     rgb(236, 115, 54), rgb(243, 123, 63), rgb(248, 131, 73), rgb(254, 140, 82)},
    rgb(26, 26, 31));

inline constexpr ThemePair suburb = MakePair("Base2Tone Suburb Dark", "Base2Tone Suburb Light",
    {rgb(30, 32, 47), rgb(41, 44, 61), rgb(68, 72, 100), rgb(79, 84, 114),
     rgb(91, 96, 128), rgb(110, 115, 150), rgb(135, 139, 166), rgb(159, 162, 183)},
    {rgb(81, 101, 230), rgb(99, 117, 238), rgb(117, 134, 245), rgb(134, 150, 253),
     rgb(160, 172, 254), rgb(185, 194, 254), rgb(210, 216, 254), rgb(235, 237, 255)},
    {rgb(122, 113, 117), rgb(141, 129, 134), rgb(159, 147, 152), rgb(176, 166, 170),
     rgb(194, 183, 188), rgb(215, 203, 208), rgb(234, 225, 229), rgb(251, 249, 250)},
    {rgb(209, 71, 129), rgb(228, 78, 140), rgb(242, 90, 153), rgb(247, 100, 161),
     rgb(251, 111, 169), rgb(254, 129, 181), rgb(255, 153, 195), rgb(255, 179, 210)},
    rgb(21, 22, 30));

} // namespace Base2Tone

// Preferences use numeric slots based on this order. Append new themes without reordering existing entries.
inline constexpr Theme themes[] = {
    {"Classic", rgb(255, 255, 255), rgb(241, 245, 255), rgb(189, 214, 247),
     rgb(239, 239, 240), rgb(198, 200, 204), rgb(99, 101, 107), rgb(48, 53, 61),
     {rgb(16, 16, 16), rgb(160, 0, 136), rgb(160, 0, 136), rgb(79, 33, 138),
      rgb(43, 49, 145), rgb(16, 16, 16), rgb(184, 29, 24), rgb(28, 0, 207),
      rgb(0, 108, 20), rgb(120, 69, 27), rgb(28, 0, 207), rgb(22, 0, 184)},
     {.completionPaper = rgb(255, 255, 255), .vimFlash = rgb(126, 169, 226)}},

    {"Paper", rgb(255, 251, 234), rgb(243, 232, 190), rgb(234, 211, 139),
     rgb(239, 233, 213), rgb(201, 190, 163), rgb(106, 98, 81), rgb(48, 38, 25),
     {rgb(24, 20, 11), rgb(23, 63, 157), rgb(23, 63, 157), rgb(0, 98, 89),
      rgb(115, 32, 140), rgb(24, 20, 11), rgb(156, 52, 20), rgb(121, 54, 148),
      rgb(56, 96, 32), rgb(141, 23, 71), rgb(0, 60, 148), rgb(104, 32, 139)},
     {.completionPaper = rgb(255, 251, 234), .vimFlash = rgb(135, 174, 145)}},

    {"Dark+ (2019)", rgb(30, 30, 30), rgb(40, 40, 40), rgb(73, 64, 53),
     rgb(30, 30, 30), rgb(51, 51, 51), rgb(133, 133, 133), rgb(198, 198, 198),
     {rgb(212, 212, 212), rgb(86, 156, 214), rgb(197, 134, 192), rgb(78, 201, 176),
      rgb(220, 220, 170), rgb(156, 220, 254), rgb(206, 145, 120), rgb(181, 206, 168),
      rgb(106, 153, 85), rgb(86, 156, 214), rgb(79, 193, 255), rgb(215, 186, 125)},
     {.completionPaper = rgb(41, 38, 32), .completionBorder = rgb(90, 80, 60),
      .completionSelection = rgb(85, 71, 47), .completionSelectedText = rgb(255, 241, 211),
      .wordMatch = rgb(183, 155, 97), .bracketMatch = rgb(217, 181, 117), .vimFlash = rgb(81, 140, 179),
       .commandCaret = rgb(220, 200, 156)},
     rgb(174, 175, 173), true},

    // Monokai.tmTheme from Sublime Text 2.0.2, build 2221.
    {"Monokai", rgb(39, 40, 34), rgb(62, 61, 50), rgb(73, 72, 62),
     rgb(39, 40, 34), rgb(59, 58, 50), rgb(144, 144, 138), rgb(248, 248, 242),
     monokaiInk,
     {.completionPaper = rgb(48, 47, 39), .completionBorder = rgb(90, 89, 70),
      .completionSelection = rgb(75, 80, 53), .completionSelectedText = rgb(245, 243, 214),
      .wordMatch = rgb(162, 168, 106), .bracketMatch = rgb(196, 189, 120), .vimFlash = rgb(130, 138, 79),
       .commandCaret = rgb(201, 208, 158)},
     rgb(248, 248, 240), true, true},

    {"Zen", rgb(33, 43, 36), rgb(43, 55, 45), rgb(52, 69, 55),
     rgb(37, 48, 40), rgb(60, 75, 61), rgb(149, 164, 145), rgb(213, 221, 200),
     {rgb(226, 230, 212), rgb(182, 206, 148), rgb(222, 182, 158), rgb(165, 204, 195),
      rgb(209, 219, 175), rgb(211, 220, 201), rgb(220, 199, 147), rgb(194, 178, 215),
      rgb(160, 182, 160), rgb(156, 201, 183), rgb(219, 186, 155), rgb(236, 195, 171)},
     {.completionPaper = rgb(42, 55, 46), .completionBorder = rgb(83, 101, 79),
      .completionSelection = rgb(65, 84, 66), .completionSelectedText = rgb(242, 235, 210),
      .wordMatch = rgb(162, 199, 153), .bracketMatch = rgb(188, 204, 146), .vimFlash = rgb(119, 156, 118),
       .commandCaret = rgb(170, 188, 151)},
     rgb(214, 224, 188), true},

    {"Lavender Light", rgb(250, 247, 254), rgb(238, 231, 247), rgb(224, 212, 239),
     rgb(240, 234, 246), rgb(215, 203, 228), rgb(109, 92, 129), rgb(76, 56, 104),
     {rgb(40, 32, 51), rgb(103, 44, 155), rgb(140, 44, 120), rgb(33, 99, 107),
      rgb(60, 67, 138), rgb(51, 38, 66), rgb(144, 48, 79), rgb(69, 57, 165),
      rgb(77, 89, 73), rgb(98, 70, 116), rgb(122, 60, 89), rgb(125, 75, 18)},
     {.completionPaper = rgb(246, 240, 251), .completionBorder = rgb(191, 175, 208),
      .completionSelection = rgb(217, 203, 234), .completionSelectedText = rgb(48, 24, 62),
      .wordMatch = rgb(134, 102, 166), .bracketMatch = rgb(137, 86, 173), .vimFlash = rgb(179, 148, 205),
       .commandCaret = rgb(215, 197, 232)},
     rgb(73, 34, 100)},

    // JetBrains Default and Darcula editor schemes.
    {"IntelliJ Classic", rgb(255, 255, 255), rgb(255, 255, 215), rgb(214, 225, 242),
     rgb(240, 240, 240), rgb(211, 211, 208), rgb(128, 0, 0), rgb(84, 21, 21),
     {rgb(0, 0, 0), rgb(0, 0, 128), rgb(0, 0, 128), rgb(0, 0, 128),
      rgb(52, 65, 106), rgb(0, 0, 0), rgb(0, 115, 0), rgb(0, 0, 255),
      rgb(97, 97, 97), rgb(99, 85, 0), rgb(102, 14, 122), rgb(25, 50, 165)},
     {.completionPaper = rgb(250, 250, 243), .completionBorder = rgb(174, 174, 162),
      .completionSelection = rgb(82, 109, 165), .completionSelectedText = rgb(255, 255, 255),
      .wordMatch = rgb(155, 142, 57), .bracketMatch = rgb(119, 136, 166), .vimFlash = rgb(135, 164, 215),
       .commandCaret = rgb(195, 211, 238)}},

    {"Darcula", rgb(43, 43, 43), rgb(50, 50, 50), rgb(52, 65, 80),
     rgb(49, 51, 53), rgb(68, 72, 75), rgb(160, 160, 155), rgb(205, 209, 209),
     {rgb(169, 183, 198), rgb(230, 161, 100), rgb(230, 161, 100), rgb(169, 183, 198),
      rgb(255, 198, 109), rgb(169, 183, 198), rgb(165, 194, 97), rgb(138, 183, 214),
      rgb(172, 173, 163), rgb(199, 183, 85), rgb(196, 166, 213), rgb(230, 170, 114)},
     {.completionPaper = rgb(52, 52, 52), .completionBorder = rgb(85, 85, 76),
      .completionSelection = rgb(81, 69, 55), .completionSelectedText = rgb(244, 217, 165),
      .wordMatch = rgb(192, 161, 106), .bracketMatch = rgb(214, 174, 112), .vimFlash = rgb(80, 107, 133),
       .commandCaret = rgb(216, 191, 150)},
     rgb(187, 187, 187), true},

    {"Eclipse Classic", rgb(255, 255, 255), rgb(232, 242, 254), rgb(202, 221, 239),
     rgb(239, 239, 239), rgb(207, 213, 220), rgb(100, 100, 106), rgb(55, 61, 74),
     {rgb(0, 0, 0), rgb(127, 0, 85), rgb(127, 0, 85), rgb(93, 37, 120),
      rgb(35, 58, 100), rgb(32, 32, 32), rgb(42, 0, 255), rgb(88, 41, 121),
      rgb(46, 104, 76), rgb(96, 89, 51), rgb(0, 0, 192), rgb(128, 0, 128)},
     {.completionPaper = rgb(247, 248, 252), .completionBorder = rgb(162, 173, 189),
      .completionSelection = rgb(203, 216, 234), .completionSelectedText = rgb(23, 39, 67),
      .wordMatch = rgb(82, 137, 181), .bracketMatch = rgb(86, 123, 174), .vimFlash = rgb(182, 124, 179),
       .commandCaret = rgb(191, 210, 235)}},

    {"Visual Studio Light", rgb(255, 255, 255), rgb(244, 244, 244), rgb(208, 229, 253),
     rgb(242, 242, 242), rgb(216, 216, 216), rgb(98, 104, 106), rgb(40, 68, 82),
     {rgb(0, 0, 0), rgb(0, 0, 255), rgb(0, 0, 255), rgb(0, 104, 126),
      rgb(98, 80, 43), rgb(20, 20, 37), rgb(163, 21, 21), rgb(8, 94, 64),
      rgb(0, 109, 0), rgb(91, 28, 119), rgb(0, 76, 153), rgb(129, 31, 63)},
     {.completionPaper = rgb(243, 243, 243), .completionBorder = rgb(160, 167, 176),
      .completionSelection = rgb(205, 223, 239), .completionSelectedText = rgb(16, 48, 84),
      .wordMatch = rgb(66, 130, 187), .bracketMatch = rgb(80, 133, 178), .vimFlash = rgb(120, 169, 219),
       .commandCaret = rgb(190, 216, 244)}},

    // TextMate's Mac Classic, Cobalt, Twilight, and Sunburst.
    {"Mac Classic", rgb(255, 255, 255), rgb(237, 237, 237), rgb(205, 224, 252),
     rgb(239, 239, 241), rgb(210, 211, 214), rgb(101, 101, 107), rgb(51, 52, 58),
     {rgb(0, 0, 0), rgb(0, 0, 255), rgb(0, 0, 255), rgb(0, 0, 173),
      rgb(40, 91, 105), rgb(0, 0, 0), rgb(3, 106, 7), rgb(0, 0, 205),
      rgb(21, 85, 176), rgb(12, 69, 13), rgb(172, 21, 27), rgb(33, 108, 51)},
     {.completionPaper = rgb(247, 248, 251), .completionBorder = rgb(169, 179, 193),
      .completionSelection = rgb(205, 220, 243), .completionSelectedText = rgb(18, 46, 98),
      .wordMatch = rgb(77, 131, 202), .bracketMatch = rgb(70, 116, 180), .vimFlash = rgb(136, 180, 238),
       .commandCaret = rgb(194, 216, 247)}},

    {"Cobalt", rgb(0, 34, 64), rgb(0, 27, 51), rgb(52, 64, 90),
     rgb(0, 24, 44), rgb(23, 66, 102), rgb(135, 162, 187), rgb(198, 229, 255),
     {rgb(255, 255, 255), rgb(255, 157, 0), rgb(255, 170, 55), rgb(255, 238, 128),
      rgb(255, 221, 0), rgb(225, 239, 255), rgb(58, 217, 0), rgb(255, 154, 180),
      rgb(155, 176, 203), rgb(141, 194, 250), rgb(255, 154, 180), rgb(185, 243, 126)},
     {.completionPaper = rgb(12, 43, 72), .completionBorder = rgb(65, 100, 135),
      .completionSelection = rgb(42, 75, 109), .completionSelectedText = rgb(255, 240, 176),
      .wordMatch = rgb(135, 187, 238), .bracketMatch = rgb(255, 202, 113), .vimFlash = rgb(204, 149, 67),
       .commandCaret = rgb(168, 207, 255)},
     rgb(255, 255, 255), true},

    {"Twilight", rgb(24, 24, 24), rgb(35, 33, 35), rgb(53, 60, 66),
     rgb(31, 30, 32), rgb(61, 57, 60), rgb(158, 150, 157), rgb(208, 198, 204),
     {rgb(248, 248, 248), rgb(205, 168, 105), rgb(226, 187, 130), rgb(249, 238, 152),
      rgb(188, 171, 192), rgb(231, 223, 220), rgb(168, 179, 137), rgb(233, 144, 123),
      rgb(172, 166, 171), rgb(168, 185, 187), rgb(233, 144, 123), rgb(208, 192, 140)},
     {.completionPaper = rgb(41, 38, 42), .completionBorder = rgb(85, 75, 83),
      .completionSelection = rgb(72, 64, 57), .completionSelectedText = rgb(255, 234, 204),
      .wordMatch = rgb(191, 166, 116), .bracketMatch = rgb(204, 174, 126), .vimFlash = rgb(124, 104, 141),
       .commandCaret = rgb(219, 191, 152)},
     rgb(218, 218, 218), true},

    {"Sunburst", rgb(0, 0, 0), rgb(26, 26, 26), rgb(44, 53, 64),
     rgb(18, 18, 18), rgb(51, 54, 55), rgb(155, 158, 159), rgb(224, 228, 229),
     {rgb(248, 248, 248), rgb(226, 137, 100), rgb(238, 157, 124), rgb(153, 207, 80),
      rgb(137, 189, 255), rgb(230, 233, 239), rgb(121, 195, 80), rgb(113, 185, 240),
      rgb(174, 174, 174), rgb(175, 196, 219), rgb(137, 189, 255), rgb(233, 192, 98)},
     {.completionPaper = rgb(26, 28, 32), .completionBorder = rgb(72, 75, 88),
      .completionSelection = rgb(50, 56, 68), .completionSelectedText = rgb(231, 239, 250),
      .wordMatch = rgb(131, 177, 222), .bracketMatch = rgb(231, 189, 114), .vimFlash = rgb(181, 107, 82),
       .commandCaret = rgb(185, 203, 225)},
     rgb(221, 221, 221), true},

    {"Railscasts", rgb(43, 43, 43), rgb(53, 49, 45), rgb(71, 59, 50),
     rgb(48, 44, 40), rgb(81, 65, 54), rgb(171, 154, 139), rgb(219, 200, 179),
     {rgb(230, 225, 220), rgb(231, 155, 91), rgb(231, 155, 91), rgb(234, 215, 184),
      rgb(255, 198, 109), rgb(208, 208, 255), rgb(165, 194, 97), rgb(144, 183, 210),
      rgb(198, 167, 126), rgb(225, 169, 121), rgb(144, 183, 210), rgb(242, 182, 121)},
     {.completionPaper = rgb(57, 48, 42), .completionBorder = rgb(101, 84, 69),
      .completionSelection = rgb(89, 70, 54), .completionSelectedText = rgb(255, 228, 182),
      .wordMatch = rgb(193, 148, 102), .bracketMatch = rgb(223, 171, 111), .vimFlash = rgb(130, 152, 86),
       .commandCaret = rgb(229, 191, 146)},
     rgb(236, 227, 211), true},

    // Solarized by Ethan Schoonover. Retain the base tones and adjust small-text contrast.
    {"Solarized Light", rgb(253, 246, 227), rgb(238, 232, 213), rgb(236, 227, 202),
     rgb(238, 232, 213), rgb(214, 206, 184), rgb(83, 105, 110), rgb(55, 77, 83),
     {rgb(69, 92, 99), rgb(73, 102, 0), rgb(110, 88, 0), rgb(98, 84, 154),
      rgb(23, 101, 162), rgb(70, 92, 98), rgb(11, 105, 95), rgb(160, 43, 84),
      rgb(81, 101, 107), rgb(165, 57, 18), rgb(151, 54, 73), rgb(120, 81, 25)},
     {.completionPaper = rgb(246, 239, 221), .completionBorder = rgb(182, 179, 156),
      .completionSelection = rgb(226, 216, 183), .completionSelectedText = rgb(56, 73, 75),
      .wordMatch = rgb(161, 135, 44), .bracketMatch = rgb(139, 114, 52), .vimFlash = rgb(126, 183, 172),
       .commandCaret = rgb(218, 208, 168)},
     rgb(69, 92, 99)},

    {"Solarized Dark", rgb(0, 43, 54), rgb(7, 54, 66), rgb(20, 66, 78),
     rgb(6, 49, 59), rgb(39, 80, 92), rgb(140, 166, 170), rgb(183, 195, 187),
     {rgb(165, 179, 174), rgb(166, 181, 66), rgb(216, 178, 79), rgb(167, 164, 225),
      rgb(105, 183, 230), rgb(165, 179, 174), rgb(101, 188, 173), rgb(232, 145, 176),
      rgb(153, 173, 180), rgb(236, 149, 105), rgb(240, 140, 131), rgb(234, 195, 118)},
     {.completionPaper = rgb(11, 56, 67), .completionBorder = rgb(64, 101, 112),
      .completionSelection = rgb(36, 83, 89), .completionSelectedText = rgb(221, 235, 212),
      .wordMatch = rgb(128, 180, 159), .bracketMatch = rgb(210, 182, 96), .vimFlash = rgb(59, 108, 104),
       .commandCaret = rgb(191, 210, 190)},
     rgb(147, 161, 161), true},

    // Chris Kempson's Tomorrow and Tomorrow Night.
    {"Tomorrow", rgb(255, 255, 255), rgb(239, 239, 239), rgb(228, 228, 227),
     rgb(243, 243, 241), rgb(216, 216, 213), rgb(102, 105, 96), rgb(64, 65, 62),
     {rgb(77, 77, 76), rgb(128, 76, 153), rgb(128, 76, 153), rgb(121, 84, 37),
      rgb(51, 89, 137), rgb(77, 77, 76), rgb(74, 105, 44), rgb(152, 76, 19),
      rgb(98, 101, 94), rgb(50, 106, 101), rgb(169, 42, 44), rgb(111, 83, 32)},
     {.completionPaper = rgb(245, 245, 244), .completionBorder = rgb(170, 170, 166),
      .completionSelection = rgb(217, 224, 229), .completionSelectedText = rgb(49, 73, 88),
      .wordMatch = rgb(86, 120, 153), .bracketMatch = rgb(104, 128, 155), .vimFlash = rgb(141, 170, 203),
       .commandCaret = rgb(203, 218, 231)}},

    {"Tomorrow Night", rgb(29, 31, 33), rgb(40, 42, 46), rgb(55, 59, 65),
     rgb(34, 36, 39), rgb(56, 59, 63), rgb(150, 152, 150), rgb(216, 219, 217),
     {rgb(197, 200, 198), rgb(191, 157, 199), rgb(191, 157, 199), rgb(240, 198, 116),
      rgb(149, 182, 207), rgb(197, 200, 198), rgb(181, 189, 104), rgb(222, 147, 95),
      rgb(165, 167, 164), rgb(138, 190, 183), rgb(234, 144, 138), rgb(240, 198, 116)},
     {.completionPaper = rgb(44, 46, 46), .completionBorder = rgb(85, 90, 88),
      .completionSelection = rgb(68, 75, 64), .completionSelectedText = rgb(227, 230, 206),
      .wordMatch = rgb(166, 175, 126), .bracketMatch = rgb(189, 193, 140), .vimFlash = rgb(100, 126, 157),
       .commandCaret = rgb(203, 210, 174)},
     rgb(197, 200, 198), true},

    // Atom's original Dark syntax and the later One themes.
    {"Atom Dark", rgb(29, 31, 33), rgb(37, 40, 42), rgb(60, 64, 63),
     rgb(40, 43, 46), rgb(53, 58, 63), rgb(152, 157, 160), rgb(197, 200, 198),
     {rgb(197, 200, 198), rgb(150, 203, 254), rgb(150, 203, 254), rgb(141, 198, 254),
      rgb(218, 208, 133), rgb(198, 197, 254), rgb(168, 255, 96), rgb(255, 115, 253),
      rgb(168, 174, 167), rgb(150, 203, 254), rgb(153, 204, 153), rgb(249, 238, 152)},
     {.completionPaper = rgb(42, 46, 38), .completionBorder = rgb(75, 88, 66),
      .completionSelection = rgb(64, 77, 54), .completionSelectedText = rgb(230, 252, 207),
      .wordMatch = rgb(150, 198, 117), .bracketMatch = rgb(182, 215, 136), .vimFlash = rgb(159, 185, 105),
       .commandCaret = rgb(201, 227, 185)},
     rgb(255, 255, 255), true},

    {"One Light", rgb(250, 250, 250), rgb(240, 240, 241), rgb(221, 228, 240),
     rgb(241, 241, 242), rgb(213, 214, 218), rgb(101, 105, 117), rgb(56, 58, 66),
     {rgb(56, 58, 66), rgb(136, 34, 139), rgb(136, 34, 139), rgb(128, 86, 11),
      rgb(37, 87, 182), rgb(56, 58, 66), rgb(54, 111, 51), rgb(128, 84, 0),
      rgb(93, 98, 108), rgb(0, 103, 131), rgb(161, 48, 55), rgb(128, 86, 11)},
     {.completionPaper = rgb(245, 245, 246), .completionBorder = rgb(173, 179, 189),
      .completionSelection = rgb(213, 222, 236), .completionSelectedText = rgb(36, 55, 87),
      .wordMatch = rgb(102, 134, 179), .bracketMatch = rgb(107, 129, 170), .vimFlash = rgb(150, 172, 221),
       .commandCaret = rgb(202, 216, 240)}},

    {"One Dark", rgb(40, 44, 52), rgb(48, 53, 62), rgb(55, 62, 73),
     rgb(35, 39, 47), rgb(61, 68, 79), rgb(149, 160, 174), rgb(206, 213, 225),
     {rgb(171, 178, 191), rgb(210, 149, 230), rgb(210, 149, 230), rgb(229, 192, 123),
      rgb(117, 185, 241), rgb(171, 178, 191), rgb(152, 195, 121), rgb(220, 170, 121),
      rgb(162, 171, 184), rgb(119, 197, 209), rgb(237, 160, 165), rgb(129, 215, 205)},
     {.completionPaper = rgb(50, 54, 65), .completionBorder = rgb(84, 93, 107),
      .completionSelection = rgb(68, 72, 84), .completionSelectedText = rgb(228, 213, 233),
      .wordMatch = rgb(165, 168, 200), .bracketMatch = rgb(199, 171, 215), .vimFlash = rgb(110, 96, 143),
       .commandCaret = rgb(200, 185, 217)},
     rgb(188, 201, 227), true},

    {"Gruvbox Dark", rgb(40, 40, 40), rgb(50, 48, 47), rgb(64, 59, 54),
     rgb(48, 45, 41), rgb(73, 65, 58), rgb(178, 162, 138), rgb(235, 219, 178),
     {rgb(235, 219, 178), rgb(251, 134, 109), rgb(254, 153, 62), rgb(250, 189, 47),
      rgb(184, 187, 38), rgb(235, 219, 178), rgb(184, 187, 38), rgb(228, 155, 174),
      rgb(184, 168, 145), rgb(165, 189, 131), rgb(156, 186, 195), rgb(250, 189, 47)},
     {.completionPaper = rgb(53, 48, 43), .completionBorder = rgb(93, 80, 68),
      .completionSelection = rgb(82, 67, 54), .completionSelectedText = rgb(248, 223, 177),
      .wordMatch = rgb(196, 160, 103), .bracketMatch = rgb(217, 170, 100), .vimFlash = rgb(98, 137, 133),
       .commandCaret = rgb(227, 191, 124)},
     rgb(235, 219, 178), true},

    {"Dracula", rgb(40, 42, 54), rgb(52, 55, 71), rgb(64, 67, 90),
     rgb(35, 37, 49), rgb(60, 64, 83), rgb(157, 169, 201), rgb(227, 229, 242),
     {rgb(248, 248, 242), rgb(255, 150, 212), rgb(255, 150, 212), rgb(139, 233, 253),
      rgb(80, 250, 123), rgb(248, 248, 242), rgb(241, 250, 140), rgb(201, 167, 254),
      rgb(167, 179, 217), rgb(255, 184, 108), rgb(201, 167, 254), rgb(255, 184, 108)},
     {.completionPaper = rgb(52, 54, 71), .completionBorder = rgb(84, 88, 114),
      .completionSelection = rgb(73, 65, 93), .completionSelectedText = rgb(246, 229, 252),
      .wordMatch = rgb(203, 161, 236), .bracketMatch = rgb(235, 167, 214), .vimFlash = rgb(184, 147, 205),
       .commandCaret = rgb(220, 197, 245)},
     rgb(248, 248, 242), true},

    // Highlight.js Zenburn from the RustConf 2018 slides, with the Notepad++ Zenburn caret and line.
    {"Zenburn (Notepad++)", rgb(63, 63, 63), rgb(16, 16, 16), rgb(76, 84, 77),
     rgb(54, 58, 54), rgb(87, 92, 84), rgb(172, 180, 169), rgb(220, 220, 220),
     {rgb(220, 220, 220), rgb(227, 206, 171), rgb(227, 206, 171), rgb(239, 239, 143),
      rgb(239, 239, 143), rgb(220, 220, 220), rgb(204, 147, 147), rgb(140, 208, 211),
      rgb(127, 159, 127), rgb(127, 159, 127), rgb(239, 239, 175), rgb(220, 163, 163)},
     {.completionPaper = rgb(69, 71, 66), .completionBorder = rgb(101, 107, 95),
      .completionSelection = rgb(87, 100, 85), .completionSelectedText = rgb(243, 241, 208),
      .wordMatch = rgb(163, 189, 146), .bracketMatch = rgb(211, 213, 160), .vimFlash = rgb(132, 172, 137),
       .commandCaret = rgb(206, 208, 175)},
     rgb(143, 175, 159), true, false, {}, rgb(132, 137, 130), rgb(16, 16, 16)},

    // VS Code Dark Modern inherits the Dark+ syntax palette.
    ClassicTheme("Dark Modern", rgb(31, 31, 31), rgb(40, 40, 40), rgb(41, 67, 97),
        {rgb(204, 204, 204), rgb(86, 156, 214), rgb(197, 134, 192), rgb(78, 201, 176),
         rgb(220, 220, 170), rgb(156, 220, 254), rgb(206, 145, 120), rgb(181, 206, 168),
         rgb(106, 153, 85), rgb(86, 156, 214), rgb(79, 193, 255), rgb(215, 186, 125)}, rgb(112, 174, 233),
          rgb(71, 126, 185), true, darkModernBrackets),

    ClassicTheme("IntelliJ Light", rgb(255, 255, 255), rgb(255, 251, 227), rgb(203, 225, 251),
        {rgb(0, 0, 0), rgb(0, 0, 128), rgb(126, 24, 125), rgb(89, 36, 128),
         rgb(113, 66, 14), rgb(102, 14, 122), rgb(6, 125, 23), rgb(0, 0, 255),
         rgb(99, 114, 96), rgb(128, 128, 0), rgb(135, 16, 148), rgb(0, 55, 160)}, rgb(129, 81, 132),
          rgb(197, 150, 216)),
    ClassicTheme("WebStorm Classic", rgb(255, 255, 255), rgb(242, 246, 252), rgb(214, 222, 244),
        {rgb(27, 27, 34), rgb(0, 0, 128), rgb(125, 25, 118), rgb(87, 90, 2),
         rgb(116, 76, 0), rgb(102, 14, 122), rgb(0, 128, 0), rgb(23, 80, 235),
         rgb(100, 105, 111), rgb(118, 104, 23), rgb(157, 32, 105), rgb(81, 75, 179)}, rgb(129, 113, 152),
          rgb(174, 148, 200)),
    ClassicTheme("Darcula (2013)", rgb(43, 43, 43), rgb(50, 50, 50), rgb(53, 68, 90),
        {rgb(169, 183, 198), rgb(204, 120, 50), rgb(204, 120, 50), rgb(169, 183, 198),
         rgb(255, 198, 109), rgb(152, 118, 170), rgb(106, 135, 89), rgb(104, 151, 187),
         rgb(128, 128, 128), rgb(187, 181, 41), rgb(152, 118, 170), rgb(204, 120, 50)}, rgb(217, 165, 87),
          rgb(71, 104, 132), true),

    // Ghidra's light decompiler roles, mapped to the editor's lexical tokens.
    ClassicTheme("Ghidra Light", rgb(255, 255, 255), rgb(255, 252, 239), rgb(176, 196, 222),
        {rgb(0, 0, 0), rgb(0, 0, 255), rgb(0, 0, 255), rgb(0, 0, 255),
         rgb(255, 0, 255), rgb(128, 128, 0), rgb(0, 128, 0), rgb(0, 128, 0),
         rgb(138, 43, 226), rgb(0, 139, 139), rgb(0, 128, 0), rgb(128, 0, 128)}, rgb(147, 112, 219),
          rgb(168, 141, 223)),

    // Classic macOS ANSI colors on the dark Terminal background.
    ClassicTheme("Terminal Vim", rgb(0, 0, 0), rgb(25, 25, 25), rgb(53, 53, 53),
        {rgb(191, 191, 191), rgb(153, 153, 0), rgb(191, 191, 0), rgb(0, 166, 0),
         rgb(0, 166, 178), rgb(191, 191, 191), rgb(153, 0, 0), rgb(178, 0, 178),
         rgb(110, 154, 154), rgb(92, 92, 255), rgb(191, 0, 191), rgb(224, 90, 90)}, rgb(166, 146, 69),
          rgb(51, 122, 121), true),
    ClassicTheme("Vim Desert", rgb(51, 51, 51), rgb(65, 65, 65), rgb(83, 103, 45),
        {rgb(255, 255, 255), rgb(240, 230, 140), rgb(240, 230, 140), rgb(189, 183, 107),
         rgb(137, 251, 152), rgb(255, 255, 255), rgb(255, 160, 160), rgb(255, 160, 160),
         rgb(109, 206, 235), rgb(228, 123, 123), rgb(255, 160, 160), rgb(255, 222, 155)}, rgb(157, 163, 75), rgb(116, 151, 86), true),
    ClassicTheme("Vim Evening", rgb(51, 51, 51), rgb(68, 68, 68), rgb(86, 86, 86),
        {rgb(255, 255, 255), rgb(255, 255, 96), rgb(255, 255, 96), rgb(88, 239, 88),
         rgb(64, 255, 255), rgb(255, 255, 255), rgb(255, 160, 160), rgb(255, 160, 160),
         rgb(142, 171, 255), rgb(255, 128, 255), rgb(255, 160, 160), rgb(255, 165, 0)}, rgb(219, 174, 100), rgb(106, 130, 183), true),
    ClassicTheme("Vim Torte", rgb(0, 0, 0), rgb(33, 33, 33), rgb(65, 66, 68),
        {rgb(204, 204, 204), rgb(255, 255, 96), rgb(255, 255, 96), rgb(96, 255, 96),
         rgb(64, 255, 255), rgb(204, 204, 204), rgb(255, 160, 160), rgb(255, 160, 160),
         rgb(128, 160, 255), rgb(255, 128, 255), rgb(255, 160, 160), rgb(255, 165, 0)}, rgb(104, 187, 215), rgb(57, 127, 149), true),
    ClassicTheme("Vim Slate", rgb(38, 38, 38), rgb(51, 51, 51), rgb(63, 74, 53),
        {rgb(255, 255, 255), rgb(139, 177, 235), rgb(139, 177, 235), rgb(131, 162, 216),
         rgb(255, 135, 135), rgb(234, 230, 227), rgb(255, 175, 175), rgb(255, 175, 175),
         rgb(150, 145, 140), rgb(215, 135, 95), rgb(215, 215, 135), rgb(215, 215, 135)}, rgb(165, 169, 127), rgb(171, 98, 105), true),
    ClassicTheme("Vim Peachpuff", rgb(255, 218, 185), rgb(245, 202, 165), rgb(234, 182, 25),
        {rgb(33, 22, 15), rgb(165, 42, 42), rgb(165, 42, 42), rgb(28, 98, 68),
         rgb(0, 105, 110), rgb(33, 22, 15), rgb(166, 0, 79), rgb(166, 0, 79),
         rgb(64, 89, 120), rgb(158, 24, 140), rgb(166, 0, 79), rgb(95, 77, 166)}, rgb(130, 83, 69),
          rgb(205, 130, 111)),

    ClassicTheme("Emacs Light", rgb(255, 255, 255), rgb(242, 240, 232), rgb(222, 211, 236),
        {rgb(22, 22, 22), rgb(134, 36, 112), rgb(134, 36, 112), rgb(34, 107, 88),
         rgb(0, 0, 166), rgb(124, 77, 4), rgb(156, 63, 51), rgb(72, 56, 161),
         rgb(163, 38, 38), rgb(123, 61, 152), rgb(0, 111, 133), rgb(136, 96, 3)}, rgb(132, 97, 163),
          rgb(178, 139, 204)),
    ClassicTheme("Emacs Wombat", rgb(36, 36, 36), rgb(48, 48, 48), rgb(68, 68, 68),
        {rgb(246, 243, 232), rgb(138, 198, 242), rgb(138, 198, 242), rgb(146, 166, 94),
         rgb(202, 230, 130), rgb(202, 230, 130), rgb(149, 228, 84), rgb(229, 120, 109),
         rgb(153, 150, 139), rgb(229, 120, 109), rgb(229, 120, 109), rgb(221, 170, 111)}, rgb(165, 162, 123), rgb(116, 142, 76), true),
    ClassicTheme("Emacs Tango Dark", rgb(46, 52, 54), rgb(59, 68, 71), rgb(79, 87, 91),
        {rgb(238, 238, 236), rgb(180, 250, 112), rgb(180, 250, 112), rgb(140, 196, 255),
         rgb(252, 233, 79), rgb(239, 239, 175), rgb(233, 185, 110), rgb(230, 168, 223),
         rgb(147, 161, 161), rgb(173, 127, 168), rgb(233, 178, 245), rgb(252, 140, 131)}, rgb(128, 184, 220), rgb(93, 145, 196), true),
    ClassicTheme("Emacs Leuven", rgb(255, 255, 255), rgb(255, 255, 224), rgb(228, 235, 244),
        {rgb(51, 51, 51), rgb(104, 0, 160), rgb(104, 0, 160), rgb(56, 80, 154),
         rgb(23, 75, 151), rgb(64, 33, 0), rgb(0, 128, 0), rgb(138, 65, 0),
         rgb(101, 124, 80), rgb(83, 89, 162), rgb(149, 68, 117), rgb(105, 101, 19)}, rgb(102, 133, 181),
          rgb(136, 165, 212)),

    ClassicTheme("Code::Blocks Classic", rgb(255, 255, 255), rgb(232, 241, 254), rgb(201, 223, 248),
        {rgb(16, 16, 16), rgb(0, 0, 170), rgb(0, 0, 170), rgb(40, 87, 95),
         rgb(43, 40, 117), rgb(26, 26, 26), rgb(154, 24, 46), rgb(22, 110, 128),
         rgb(40, 122, 56), rgb(128, 96, 0), rgb(106, 20, 83), rgb(135, 59, 17)}, rgb(73, 103, 150),
          rgb(121, 166, 212), false, codeBlocksBrackets),
    ClassicTheme("Code::Blocks Obsidian", rgb(34, 40, 42), rgb(43, 52, 52), rgb(58, 73, 72),
        {rgb(224, 226, 228), rgb(147, 199, 99), rgb(241, 164, 97), rgb(149, 186, 220),
         rgb(228, 209, 137), rgb(217, 221, 221), rgb(236, 157, 96), rgb(184, 161, 205),
         rgb(155, 170, 161), rgb(163, 190, 206), rgb(226, 171, 205), rgb(213, 187, 131)}, rgb(147, 199, 99), rgb(101, 140, 72), true, obsidianBrackets),
    ClassicTheme("Borland Turbo C++", rgb(0, 0, 168), rgb(23, 23, 181), rgb(51, 51, 194),
        {rgb(255, 255, 87), rgb(255, 255, 255), rgb(255, 255, 255), rgb(85, 255, 255),
         rgb(255, 255, 87), rgb(255, 255, 87), rgb(85, 255, 85), rgb(245, 221, 150),
         rgb(100, 234, 236), rgb(255, 183, 255), rgb(255, 255, 255), rgb(255, 181, 170)}, rgb(115, 216, 235), rgb(43, 137, 174), true),
    ClassicTheme("Visual Studio 2010", rgb(255, 255, 255), rgb(245, 245, 250), rgb(173, 214, 255),
        {rgb(0, 0, 0), rgb(0, 0, 255), rgb(0, 0, 255), rgb(43, 145, 175),
         rgb(68, 60, 89), rgb(0, 0, 0), rgb(163, 21, 21), rgb(0, 0, 0),
         rgb(0, 128, 0), rgb(119, 119, 119), rgb(101, 31, 116), rgb(143, 50, 26)}, rgb(88, 134, 186),
          rgb(155, 167, 219)),
    ClassicTheme("Visual Studio 2012 Dark", rgb(30, 30, 30), rgb(37, 37, 37), rgb(38, 79, 120),
        {rgb(220, 220, 220), rgb(86, 156, 214), rgb(86, 156, 214), rgb(78, 201, 176),
         rgb(220, 220, 220), rgb(220, 220, 220), rgb(214, 157, 133), rgb(181, 206, 168),
         rgb(120, 164, 101), rgb(155, 155, 155), rgb(171, 188, 216), rgb(224, 191, 134)}, rgb(113, 165, 215), rgb(74, 142, 130), true),
    ClassicTheme("GitHub Classic", rgb(255, 255, 255), rgb(245, 246, 247), rgb(216, 234, 254),
        {rgb(32, 32, 32), rgb(23, 23, 23), rgb(112, 31, 53), rgb(68, 85, 136),
         rgb(153, 0, 0), rgb(22, 76, 112), rgb(196, 20, 71), rgb(0, 128, 128),
         rgb(105, 105, 82), rgb(96, 78, 132), rgb(0, 128, 128), rgb(148, 55, 83)}, rgb(82, 120, 156),
          rgb(117, 169, 221)),
    ClassicTheme("GitHub Gist", rgb(250, 251, 252), rgb(240, 244, 248), rgb(217, 232, 247),
        {rgb(36, 41, 46), rgb(167, 29, 93), rgb(167, 29, 93), rgb(121, 93, 163),
         rgb(121, 93, 163), rgb(36, 41, 46), rgb(24, 54, 145), rgb(0, 134, 179),
         rgb(101, 116, 127), rgb(117, 84, 141), rgb(0, 134, 179), rgb(117, 72, 111)}, rgb(88, 115, 148),
          rgb(169, 145, 207)),

    // Casey Muratori's shipped 4coder scheme.
    ClassicTheme("Handmade Hero", rgb(22, 22, 22), rgb(18, 30, 18), rgb(112, 52, 25),
        {rgb(160, 133, 99), rgb(205, 149, 12), rgb(205, 149, 12), rgb(160, 133, 99),
         rgb(160, 133, 99), rgb(160, 133, 99), rgb(107, 142, 35), rgb(107, 142, 35),
         rgb(125, 125, 125), rgb(218, 185, 143), rgb(107, 142, 35), rgb(255, 91, 66)}, rgb(183, 142, 94),
          rgb(57, 77, 48), true),
    // The Witness Emacs palette, mapped to the available token roles.
    ClassicTheme("Blow Teal", rgb(7, 38, 38), rgb(17, 51, 51), rgb(25, 47, 131),
        {rgb(211, 181, 141), rgb(255, 255, 255), rgb(255, 255, 255), rgb(144, 238, 144),
         rgb(255, 255, 255), rgb(200, 212, 236), rgb(15, 223, 175), rgb(128, 240, 224),
         rgb(63, 223, 31), rgb(176, 255, 176), rgb(128, 240, 224), rgb(240, 204, 129)}, rgb(144, 192, 144), rgb(49, 123, 111), true),

    // Grass and dirt, torchlit Overworld, and the Halloween Nether.
    {"Minecraft Grass", rgb(77, 50, 33), rgb(54, 70, 25), rgb(67, 85, 30),
     rgb(59, 37, 24), rgb(131, 181, 61), rgb(208, 169, 119), rgb(188, 246, 90),
     {rgb(255, 237, 208), rgb(170, 237, 80), rgb(255, 177, 139), rgb(142, 218, 255),
      rgb(255, 218, 101), rgb(255, 237, 208), rgb(206, 242, 138), rgb(134, 242, 223),
      rgb(216, 194, 154), rgb(255, 189, 113), rgb(134, 242, 223), rgb(255, 213, 108)},
     {.completionPaper = rgb(83, 55, 31), .completionBorder = rgb(131, 181, 61),
      .completionSelection = rgb(143, 208, 68), .completionSelectedText = rgb(37, 50, 19),
      .wordMatch = rgb(145, 211, 76), .bracketMatch = rgb(170, 237, 80), .vimFlash = rgb(125, 166, 65),
       .commandCaret = rgb(164, 214, 91)},
     rgb(171, 230, 76), true, false, {}, rgb(185, 162, 115), rgb(48, 32, 18)},

    {"Minecraft 2012", rgb(17, 28, 50), rgb(27, 43, 72), rgb(34, 60, 99),
     rgb(23, 33, 57), rgb(48, 71, 114), rgb(133, 157, 194), rgb(204, 250, 118),
     {rgb(238, 245, 255), rgb(255, 192, 70), rgb(255, 150, 83), rgb(101, 236, 216),
      rgb(255, 241, 121), rgb(194, 221, 248), rgb(153, 249, 77), rgb(194, 167, 255),
      rgb(151, 172, 200), rgb(255, 137, 145), rgb(114, 198, 255), rgb(255, 146, 204)},
     {.completionPaper = rgb(25, 43, 72), .completionBorder = rgb(77, 121, 189),
      .completionSelection = rgb(46, 79, 120), .completionSelectedText = rgb(255, 241, 194),
      .wordMatch = rgb(90, 187, 239), .bracketMatch = rgb(108, 241, 206), .vimFlash = rgb(81, 140, 208),
       .commandCaret = rgb(77, 102, 142)},
     rgb(255, 226, 120), true, false, {}, rgb(120, 149, 183)},

    {"Minecraft Nether", rgb(37, 10, 19), rgb(58, 19, 32), rgb(85, 32, 64),
     rgb(50, 16, 24), rgb(101, 45, 62), rgb(196, 154, 165), rgb(255, 171, 108),
     {rgb(255, 240, 228), rgb(255, 116, 83), rgb(255, 153, 69), rgb(198, 168, 255),
      rgb(255, 206, 88), rgb(255, 208, 171), rgb(255, 154, 216), rgb(224, 167, 255),
      rgb(186, 161, 170), rgb(255, 119, 150), rgb(255, 182, 109), rgb(255, 255, 138)},
     {.completionPaper = rgb(60, 21, 35), .completionBorder = rgb(168, 73, 100),
      .completionSelection = rgb(100, 38, 76), .completionSelectedText = rgb(255, 229, 184),
      .wordMatch = rgb(255, 98, 69), .bracketMatch = rgb(226, 160, 255), .vimFlash = rgb(255, 156, 56),
       .commandCaret = rgb(131, 60, 100)},
     rgb(255, 182, 75), true, false, {}, rgb(174, 121, 144)},

    ClassicTheme("TextMate Blackboard", rgb(12, 16, 33), rgb(20, 26, 48), rgb(52, 59, 96),
        {rgb(248, 248, 248), rgb(251, 222, 45), rgb(251, 222, 45), rgb(141, 166, 206),
         rgb(255, 140, 81), rgb(248, 248, 248), rgb(97, 206, 60), rgb(216, 250, 60),
         rgb(174, 174, 174), rgb(251, 222, 45), rgb(216, 250, 60), rgb(230, 170, 228)}, rgb(131, 156, 207),
          rgb(82, 111, 163), true),
    ClassicTheme("TextMate Espresso Libre", rgb(42, 33, 28), rgb(57, 43, 35), rgb(82, 63, 50),
        {rgb(189, 174, 157), rgb(67, 168, 237), rgb(108, 192, 251), rgb(130, 184, 208),
         rgb(255, 172, 96), rgb(201, 183, 163), rgb(163, 198, 93), rgb(231, 139, 103),
         rgb(154, 171, 190), rgb(220, 169, 152), rgb(219, 147, 111), rgb(202, 208, 131)}, rgb(191, 150, 94), rgb(66, 104, 131), true),
    ClassicTheme("TextMate All Hallows Eve", rgb(0, 0, 0), rgb(26, 21, 26), rgb(66, 53, 72),
        {rgb(255, 255, 255), rgb(226, 138, 73), rgb(226, 138, 73), rgb(239, 220, 124),
         rgb(238, 231, 119), rgb(255, 255, 255), rgb(102, 204, 51), rgb(104, 172, 228),
         rgb(186, 138, 240), rgb(242, 189, 104), rgb(104, 172, 228), rgb(185, 224, 115)}, rgb(214, 163, 119), rgb(147, 106, 173), true),
    ClassicTheme("TextMate iPlastic", rgb(238, 238, 238), rgb(228, 231, 243), rgb(206, 217, 248),
        {rgb(34, 34, 34), rgb(0, 65, 168), rgb(60, 33, 141), rgb(107, 40, 144),
         rgb(0, 99, 87), rgb(38, 40, 59), rgb(163, 49, 42), rgb(68, 81, 163),
         rgb(76, 89, 102), rgb(98, 86, 24), rgb(157, 44, 100), rgb(26, 96, 144)}, rgb(94, 120, 164),
          rgb(133, 156, 205)),
    XcodeTheme("Xcode Dusk", rgb(30, 32, 40), rgb(45, 45, 45), rgb(84, 85, 74),
        {rgb(255, 255, 255), rgb(178, 24, 137), rgb(178, 24, 137), rgb(0, 160, 190),
         rgb(131, 192, 87), rgb(255, 255, 255), rgb(219, 44, 56), rgb(120, 109, 196),
         rgb(65, 182, 69), rgb(198, 124, 72), rgb(131, 192, 87), rgb(120, 109, 196)}, rgb(255, 255, 255),
          rgb(77, 77, 77), rgb(86, 134, 95), true),
    ClassicTheme("IDLE Classic", rgb(255, 255, 255), rgb(255, 247, 229), rgb(227, 227, 227),
        {rgb(0, 0, 0), rgb(180, 78, 0), rgb(180, 78, 0), rgb(144, 0, 144),
         rgb(0, 0, 255), rgb(0, 0, 0), rgb(0, 119, 0), rgb(72, 32, 154),
         rgb(181, 0, 0), rgb(144, 0, 144), rgb(111, 41, 134), rgb(152, 89, 26)}, rgb(107, 100, 161),
          rgb(178, 149, 206)),
    ClassicTheme("Geany", rgb(255, 255, 255), rgb(240, 241, 244), rgb(211, 223, 239),
        {rgb(32, 32, 32), rgb(0, 0, 127), rgb(0, 0, 127), rgb(104, 47, 165),
         rgb(19, 69, 130), rgb(51, 51, 51), rgb(155, 37, 59), rgb(32, 110, 69),
         rgb(97, 106, 102), rgb(108, 76, 25), rgb(115, 36, 100), rgb(36, 87, 141)}, rgb(108, 136, 169),
          rgb(136, 162, 201)),

    // The 16-color monitor from Notch's DCPU-16 project.
    ClassicTheme("Notch DCPU-16", rgb(0, 0, 0), rgb(21, 21, 21), rgb(40, 40, 72),
        {rgb(170, 170, 170), rgb(85, 255, 255), rgb(85, 85, 255), rgb(85, 255, 85),
         rgb(255, 255, 255), rgb(170, 170, 170), rgb(255, 255, 85), rgb(255, 85, 255),
         rgb(0, 170, 0), rgb(255, 85, 85), rgb(255, 85, 255), rgb(85, 255, 255)}, rgb(0, 170, 170),
          rgb(49, 111, 140), true),

    {"Mirror's Edge Light", rgb(255, 255, 255), rgb(248, 248, 248), rgb(255, 220, 224),
     rgb(245, 245, 245), rgb(221, 221, 221), rgb(98, 98, 104), rgb(200, 0, 25),
     {rgb(0, 0, 0), rgb(200, 0, 25), rgb(200, 0, 25), rgb(43, 45, 49),
      rgb(0, 0, 0), rgb(0, 0, 0), rgb(59, 66, 72), rgb(141, 35, 48),
      rgb(98, 98, 104), rgb(200, 0, 25), rgb(141, 35, 48), rgb(200, 0, 25)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(213, 183, 189),
      .completionSelection = rgb(189, 0, 28), .completionSelectedText = rgb(255, 255, 255),
      .wordMatch = rgb(204, 16, 37), .bracketMatch = rgb(217, 0, 32), .vimFlash = rgb(237, 33, 53),
       .commandCaret = rgb(255, 183, 192)},
     rgb(0, 0, 0), false, true, {}, rgb(129, 129, 134), rgb(255, 255, 255)},

    {"Mirror's Edge Dark", rgb(0, 0, 0), rgb(16, 16, 17), rgb(58, 16, 22),
     rgb(11, 11, 12), rgb(40, 40, 42), rgb(146, 146, 152), rgb(255, 53, 70),
     {rgb(255, 255, 255), rgb(255, 53, 70), rgb(255, 53, 70), rgb(214, 214, 218),
      rgb(255, 255, 255), rgb(255, 255, 255), rgb(186, 195, 203), rgb(255, 130, 138),
      rgb(146, 146, 152), rgb(255, 53, 70), rgb(255, 130, 138), rgb(255, 53, 70)},
     {.completionPaper = rgb(18, 18, 19), .completionBorder = rgb(128, 52, 62),
      .completionSelection = rgb(188, 0, 26), .completionSelectedText = rgb(255, 255, 255),
      .wordMatch = rgb(255, 53, 70), .bracketMatch = rgb(255, 53, 70), .vimFlash = rgb(255, 53, 70),
       .commandCaret = rgb(157, 32, 49)},
     rgb(255, 255, 255), true, true, {}, rgb(119, 119, 125), rgb(0, 0, 0)},

    {"Windows 8.1 Metro", rgb(24, 0, 82), rgb(43, 9, 113), rgb(59, 33, 133),
     rgb(22, 0, 71), rgb(84, 39, 174), rgb(179, 160, 233), rgb(255, 255, 255),
     {rgb(252, 248, 255), rgb(92, 197, 255), rgb(255, 157, 70), rgb(189, 235, 57),
      rgb(255, 224, 66), rgb(252, 248, 255), rgb(86, 232, 150), rgb(255, 133, 225),
      rgb(186, 172, 224), rgb(255, 115, 94), rgb(137, 180, 255), rgb(86, 235, 215)},
     {.completionPaper = rgb(38, 10, 102), .completionBorder = rgb(120, 68, 218),
      .completionSelection = rgb(0, 80, 239), .completionSelectedText = rgb(255, 255, 255),
      .wordMatch = rgb(73, 197, 255), .bracketMatch = rgb(189, 235, 57), .vimFlash = rgb(70, 159, 218),
       .commandCaret = rgb(180, 138, 247)},
     rgb(255, 255, 255), true, false, metroBrackets, rgb(170, 152, 216), rgb(24, 0, 82)},

    // Wes Bos's Sublime Text palette with brighter blue comments.
    {"Cobalt2", rgb(25, 53, 73), rgb(31, 70, 98), rgb(0, 80, 164),
     rgb(21, 35, 45), rgb(59, 83, 100), rgb(160, 183, 204), rgb(255, 198, 0),
     {rgb(255, 255, 255), rgb(255, 157, 0), rgb(255, 157, 0), rgb(128, 255, 187),
      rgb(255, 198, 0), rgb(225, 239, 255), rgb(58, 217, 0), rgb(255, 98, 140),
      rgb(86, 183, 255), rgb(175, 196, 219), rgb(255, 98, 140), rgb(255, 238, 128)},
     {.completionPaper = rgb(21, 35, 45), .completionBorder = rgb(90, 123, 146),
      .completionSelection = rgb(0, 80, 164), .completionSelectedText = rgb(255, 198, 0),
      .wordMatch = rgb(83, 152, 245), .bracketMatch = rgb(255, 198, 0), .vimFlash = rgb(255, 198, 0),
       .commandCaret = rgb(255, 204, 66)},
     rgb(255, 198, 0), true, false, {}, rgb(157, 181, 197), rgb(25, 53, 73), true},

    {"Aperture Science", rgb(255, 255, 255), rgb(242, 242, 242), rgb(220, 234, 255),
     rgb(240, 240, 240), rgb(202, 202, 202), rgb(85, 85, 85), rgb(0, 0, 0),
     {rgb(0, 0, 0), rgb(0, 78, 206), rgb(0, 78, 206), rgb(0, 0, 0),
      rgb(183, 65, 0), rgb(0, 0, 0), rgb(183, 65, 0), rgb(0, 0, 0),
      rgb(0, 62, 117), rgb(0, 78, 206), rgb(0, 0, 0), rgb(0, 78, 206)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(0, 125, 223),
      .completionSelection = rgb(255, 120, 0), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(0, 125, 223), .bracketMatch = rgb(230, 92, 8), .vimFlash = rgb(255, 114, 0),
       .commandCaret = rgb(255, 178, 102)},
     rgb(0, 0, 0), false, true, {}, rgb(115, 115, 115), rgb(255, 255, 255), true},

    {"Wii Party Light", rgb(255, 255, 255), rgb(255, 242, 248), rgb(255, 212, 231),
     rgb(243, 243, 245), rgb(216, 216, 223), rgb(92, 92, 102), rgb(182, 0, 95),
     {rgb(0, 0, 0), rgb(182, 0, 95), rgb(182, 0, 95), rgb(23, 63, 103),
      rgb(0, 89, 154), rgb(0, 0, 0), rgb(148, 38, 77), rgb(0, 89, 154),
      rgb(0, 109, 0), rgb(182, 0, 95), rgb(0, 89, 154), rgb(0, 89, 154)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(221, 60, 133),
      .completionSelection = rgb(255, 140, 189), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(236, 80, 157), .bracketMatch = rgb(206, 16, 106), .vimFlash = rgb(255, 98, 166),
       .commandCaret = rgb(253, 169, 208)},
     rgb(0, 0, 0), false, false, {}, rgb(123, 113, 119), rgb(255, 255, 255)},

    {"Wii Party Dark", rgb(0, 0, 0), rgb(23, 23, 23), rgb(255, 53, 157),
     rgb(13, 13, 13), rgb(48, 48, 48), rgb(157, 157, 157), rgb(255, 53, 157),
     {rgb(255, 255, 255), rgb(255, 134, 189), rgb(255, 134, 189), rgb(255, 255, 255),
      rgb(255, 255, 255), rgb(255, 255, 255), rgb(255, 134, 189), rgb(255, 255, 255),
      rgb(255, 53, 157), rgb(255, 134, 189), rgb(255, 255, 255), rgb(255, 53, 157)},
     {.completionPaper = rgb(0, 0, 0), .completionBorder = rgb(255, 53, 157),
      .completionSelection = rgb(255, 53, 157), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(255, 53, 157), .bracketMatch = rgb(255, 53, 157), .vimFlash = rgb(255, 53, 157),
       .commandCaret = rgb(255, 134, 189)},
     rgb(255, 255, 255), true, false, {}, rgb(146, 146, 146), rgb(0, 0, 0), true, true},

    {"Xbox 360 Light", rgb(255, 255, 255), rgb(241, 247, 233), rgb(150, 207, 35),
     rgb(242, 244, 240), rgb(208, 213, 203), rgb(85, 91, 82), rgb(32, 91, 21),
     {rgb(0, 0, 0), rgb(32, 91, 21), rgb(32, 91, 21), rgb(0, 0, 0),
      rgb(0, 0, 0), rgb(0, 0, 0), rgb(76, 97, 0), rgb(0, 0, 0),
      rgb(0, 117, 0), rgb(32, 91, 21), rgb(0, 0, 0), rgb(32, 91, 21)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(83, 133, 18),
      .completionSelection = rgb(150, 207, 35), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(118, 171, 34), .bracketMatch = rgb(83, 133, 18), .vimFlash = rgb(150, 207, 35),
       .commandCaret = rgb(150, 207, 35)},
     rgb(0, 0, 0), false, false, {}, rgb(97, 103, 91), rgb(255, 255, 255), false, true},

    {"Media Molecule Light", rgb(255, 255, 255), rgb(245, 245, 245), rgb(247, 70, 155),
     rgb(243, 243, 243), rgb(215, 215, 215), rgb(86, 86, 86), rgb(173, 0, 93),
     {rgb(0, 0, 0), rgb(173, 0, 93), rgb(173, 0, 93), rgb(0, 0, 0),
      rgb(0, 0, 0), rgb(0, 0, 0), rgb(135, 29, 83), rgb(0, 0, 0),
      rgb(0, 77, 188), rgb(173, 0, 93), rgb(0, 0, 0), rgb(173, 0, 93)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(173, 0, 93),
      .completionSelection = rgb(247, 70, 155), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(247, 70, 155), .bracketMatch = rgb(173, 0, 93), .vimFlash = rgb(247, 70, 155),
       .commandCaret = rgb(247, 70, 155)},
     rgb(0, 0, 0), false, false, {}, rgb(85, 85, 85), rgb(255, 255, 255), true, true},

    {"Media Molecule Dark", rgb(0, 0, 0), rgb(23, 23, 23), rgb(247, 70, 155),
     rgb(13, 13, 13), rgb(48, 48, 48), rgb(157, 157, 157), rgb(255, 114, 182),
     {rgb(255, 255, 255), rgb(255, 114, 182), rgb(255, 114, 182), rgb(255, 255, 255),
      rgb(255, 255, 255), rgb(255, 255, 255), rgb(255, 167, 210), rgb(255, 255, 255),
      rgb(68, 173, 255), rgb(255, 114, 182), rgb(255, 255, 255), rgb(255, 114, 182)},
     {.completionPaper = rgb(0, 0, 0), .completionBorder = rgb(247, 70, 155),
      .completionSelection = rgb(247, 70, 155), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(247, 70, 155), .bracketMatch = rgb(247, 70, 155), .vimFlash = rgb(247, 70, 155),
       .commandCaret = rgb(255, 114, 182)},
     rgb(255, 255, 255), true, false, {}, rgb(146, 146, 146), rgb(0, 0, 0), true, true},

    // Imported palettes are credited in THEME_CREDITS.txt.
    // GitHub Theme 6.3.5
    {"GitHub Light Default", rgb(255, 255, 255), rgb(244, 246, 248), rgb(206, 225, 248),
     rgb(255, 255, 255), rgb(228, 228, 229), rgb(140, 149, 159), rgb(31, 35, 40),
     {rgb(31, 35, 40), rgb(207, 34, 46), rgb(207, 34, 46), rgb(149, 56, 0),
      rgb(130, 80, 223), rgb(31, 35, 40), rgb(10, 48, 105), rgb(5, 80, 174),
      rgb(110, 119, 129), rgb(207, 34, 46), rgb(5, 80, 174), rgb(207, 34, 46)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(208, 215, 222),
      .completionSelection = rgb(239, 241, 243), .completionSelectedText = rgb(31, 35, 40),
      .wordMatch = rgb(175, 184, 193), .bracketMatch = rgb(74, 194, 107), .vimFlash = rgb(121, 185, 140),
       .commandCaret = rgb(9, 105, 218)},
     rgb(9, 105, 218), false, false, {}, rgb(175, 184, 193), rgb(255, 255, 255)},

    {"GitHub Light High Contrast", rgb(255, 255, 255), rgb(231, 236, 240), rgb(14, 17, 22),
     rgb(255, 255, 255), rgb(226, 226, 227), rgb(136, 146, 157), rgb(14, 17, 22),
     {rgb(14, 17, 22), rgb(160, 17, 31), rgb(160, 17, 31), rgb(112, 44, 0),
      rgb(98, 44, 188), rgb(14, 17, 22), rgb(3, 37, 99), rgb(2, 59, 149),
      rgb(102, 112, 123), rgb(160, 17, 31), rgb(2, 59, 149), rgb(160, 17, 31)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(32, 37, 44),
      .completionSelection = rgb(238, 240, 242), .completionSelectedText = rgb(14, 17, 22),
      .wordMatch = rgb(172, 182, 192), .bracketMatch = rgb(38, 161, 72), .vimFlash = rgb(97, 168, 121),
       .commandCaret = rgb(3, 73, 180)},
     rgb(3, 73, 180), false, false, {}, rgb(172, 182, 192), rgb(255, 255, 255), false, true},

    {"GitHub Light Colorblind (Beta)", rgb(255, 255, 255), rgb(244, 246, 248), rgb(206, 225, 248),
     rgb(255, 255, 255), rgb(228, 229, 230), rgb(140, 149, 159), rgb(36, 41, 47),
     {rgb(36, 41, 47), rgb(179, 89, 0), rgb(179, 89, 0), rgb(138, 70, 0),
      rgb(130, 80, 223), rgb(36, 41, 47), rgb(10, 48, 105), rgb(5, 80, 174),
      rgb(110, 119, 129), rgb(179, 89, 0), rgb(5, 80, 174), rgb(179, 89, 0)},
     {.completionPaper = rgb(255, 255, 255), .completionBorder = rgb(208, 215, 222),
      .completionSelection = rgb(239, 241, 243), .completionSelectedText = rgb(36, 41, 47),
      .wordMatch = rgb(175, 184, 193), .bracketMatch = rgb(84, 174, 255), .vimFlash = rgb(129, 171, 218),
       .commandCaret = rgb(9, 105, 218)},
     rgb(9, 105, 218), false, false, {}, rgb(175, 184, 193), rgb(255, 255, 255)},

    {"GitHub Dark Default", rgb(13, 17, 23), rgb(23, 27, 34), rgb(20, 39, 68),
     rgb(13, 17, 23), rgb(39, 44, 50), rgb(110, 118, 129), rgb(230, 237, 243),
     {rgb(230, 237, 243), rgb(255, 123, 114), rgb(255, 123, 114), rgb(255, 166, 87),
      rgb(210, 168, 255), rgb(230, 237, 243), rgb(165, 214, 255), rgb(121, 192, 255),
      rgb(139, 148, 158), rgb(255, 123, 114), rgb(121, 192, 255), rgb(255, 123, 114)},
     {.completionPaper = rgb(22, 27, 34), .completionBorder = rgb(48, 54, 61),
      .completionSelection = rgb(57, 63, 72), .completionSelectedText = rgb(230, 237, 243),
      .wordMatch = rgb(110, 118, 129), .bracketMatch = rgb(63, 185, 80), .vimFlash = rgb(67, 138, 96),
       .commandCaret = rgb(47, 129, 247)},
     rgb(47, 129, 247), true, false, {}, rgb(72, 79, 88), rgb(13, 17, 23)},

    {"GitHub Dark High Contrast", rgb(10, 12, 16), rgb(25, 28, 33), rgb(255, 255, 255),
     rgb(10, 12, 16), rgb(38, 40, 44), rgb(158, 167, 179), rgb(240, 243, 246),
     {rgb(240, 243, 246), rgb(255, 148, 146), rgb(255, 148, 146), rgb(255, 183, 87),
      rgb(219, 183, 255), rgb(240, 243, 246), rgb(173, 220, 255), rgb(145, 203, 255),
      rgb(189, 196, 204), rgb(255, 148, 146), rgb(145, 203, 255), rgb(255, 148, 146)},
     {.completionPaper = rgb(39, 43, 51), .completionBorder = rgb(122, 130, 142),
      .completionSelection = rgb(87, 93, 102), .completionSelectedText = rgb(240, 243, 246),
      .wordMatch = rgb(158, 167, 179), .bracketMatch = rgb(38, 205, 77), .vimFlash = rgb(54, 168, 100),
       .commandCaret = rgb(113, 183, 255)},
     rgb(113, 183, 255), true, false, {}, rgb(122, 130, 142), rgb(10, 12, 16), false, true},

    {"GitHub Dark Colorblind (Beta)", rgb(13, 17, 23), rgb(23, 27, 34), rgb(28, 47, 69),
     rgb(13, 17, 23), rgb(36, 40, 47), rgb(110, 118, 129), rgb(201, 209, 217),
     {rgb(201, 209, 217), rgb(236, 142, 44), rgb(236, 142, 44), rgb(253, 172, 84),
      rgb(210, 168, 255), rgb(201, 209, 217), rgb(165, 214, 255), rgb(121, 192, 255),
      rgb(139, 148, 158), rgb(236, 142, 44), rgb(121, 192, 255), rgb(236, 142, 44)},
     {.completionPaper = rgb(22, 27, 34), .completionBorder = rgb(48, 54, 61),
      .completionSelection = rgb(57, 63, 72), .completionSelectedText = rgb(201, 209, 217),
      .wordMatch = rgb(110, 118, 129), .bracketMatch = rgb(88, 166, 255), .vimFlash = rgb(77, 136, 199),
       .commandCaret = rgb(88, 166, 255)},
     rgb(88, 166, 255), true, false, {}, rgb(72, 79, 88), rgb(13, 17, 23)},

    {"GitHub Dark Dimmed", rgb(34, 39, 46), rgb(41, 46, 54), rgb(44, 62, 86),
     rgb(34, 39, 46), rgb(51, 57, 65), rgb(99, 110, 123), rgb(173, 186, 199),
     {rgb(173, 186, 199), rgb(244, 112, 103), rgb(244, 112, 103), rgb(246, 157, 80),
      rgb(220, 189, 251), rgb(173, 186, 199), rgb(150, 208, 255), rgb(108, 182, 255),
      rgb(118, 131, 144), rgb(244, 112, 103), rgb(108, 182, 255), rgb(244, 112, 103)},
     {.completionPaper = rgb(45, 51, 59), .completionBorder = rgb(68, 76, 86),
      .completionSelection = rgb(67, 75, 85), .completionSelectedText = rgb(173, 186, 199),
      .wordMatch = rgb(99, 110, 123), .bracketMatch = rgb(87, 171, 90), .vimFlash = rgb(73, 109, 87),
       .commandCaret = rgb(83, 155, 245)},
     rgb(83, 155, 245), true, false, {}, rgb(84, 93, 104), rgb(34, 39, 46)},

    {"GitHub Light", rgb(255, 255, 255), rgb(246, 248, 250), rgb(218, 233, 249),
     rgb(255, 255, 255), rgb(239, 242, 246), rgb(186, 187, 189), rgb(36, 41, 46),
     {rgb(36, 41, 46), rgb(215, 58, 73), rgb(215, 58, 73), rgb(111, 66, 193),
      rgb(111, 66, 193), rgb(36, 41, 46), rgb(3, 47, 98), rgb(0, 92, 197),
      rgb(106, 115, 125), rgb(215, 58, 73), rgb(0, 92, 197), rgb(0, 92, 197)},
     {.completionPaper = rgb(246, 248, 250), .completionBorder = rgb(225, 228, 232),
      .completionSelection = rgb(226, 229, 233), .completionSelectedText = rgb(47, 54, 61),
      .wordMatch = rgb(36, 148, 62), .bracketMatch = rgb(52, 208, 88), .vimFlash = rgb(129, 173, 223),
       .commandCaret = rgb(4, 66, 137)},
     rgb(4, 66, 137), false, false, {}, rgb(209, 213, 218), rgb(255, 255, 255)},

    {"GitHub Dark", rgb(36, 41, 46), rgb(43, 48, 54), rgb(40, 69, 102),
     rgb(36, 41, 46), rgb(47, 54, 61), rgb(68, 77, 86), rgb(225, 228, 232),
     {rgb(225, 228, 232), rgb(249, 117, 131), rgb(249, 117, 131), rgb(179, 146, 240),
      rgb(179, 146, 240), rgb(225, 228, 232), rgb(158, 203, 255), rgb(121, 184, 255),
      rgb(106, 115, 125), rgb(249, 117, 131), rgb(121, 184, 255), rgb(121, 184, 255)},
     {.completionPaper = rgb(31, 36, 40), .completionBorder = rgb(27, 31, 35),
      .completionSelection = rgb(57, 65, 74), .completionSelectedText = rgb(225, 228, 232),
      .wordMatch = rgb(23, 229, 230), .bracketMatch = rgb(23, 229, 230), .vimFlash = rgb(67, 137, 158),
       .commandCaret = rgb(200, 225, 255)},
     rgb(200, 225, 255), true, false, {}, rgb(68, 77, 86), rgb(36, 41, 46)},

    // Gruvbox Theme 1.29.2
    {"Gruvbox Dark Medium", rgb(40, 40, 40), rgb(48, 46, 45), rgb(56, 69, 57),
     rgb(40, 40, 40), rgb(72, 68, 63), rgb(102, 92, 84), rgb(235, 219, 178),
     {rgb(235, 219, 178), rgb(251, 73, 52), rgb(251, 73, 52), rgb(250, 189, 47),
      rgb(250, 189, 47), rgb(131, 165, 152), rgb(184, 187, 38), rgb(211, 134, 155),
      rgb(146, 131, 116), rgb(254, 128, 25), rgb(211, 134, 155), rgb(211, 134, 155)},
     {.completionPaper = rgb(40, 40, 40), .completionBorder = rgb(60, 56, 54),
      .completionSelection = rgb(48, 46, 45), .completionSelectedText = rgb(142, 192, 124),
      .wordMatch = rgb(250, 189, 47), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(131, 165, 152),
       .commandCaret = rgb(235, 219, 178)},
     rgb(235, 219, 178), true, false, {}, rgb(56, 54, 52), rgb(40, 40, 40), true},

    {"Gruvbox Dark Hard", rgb(29, 32, 33), rgb(41, 41, 41), rgb(48, 63, 51),
     rgb(29, 32, 33), rgb(64, 62, 58), rgb(102, 92, 84), rgb(235, 219, 178),
     {rgb(235, 219, 178), rgb(251, 73, 52), rgb(251, 73, 52), rgb(250, 189, 47),
      rgb(250, 189, 47), rgb(131, 165, 152), rgb(184, 187, 38), rgb(211, 134, 155),
      rgb(146, 131, 116), rgb(254, 128, 25), rgb(211, 134, 155), rgb(211, 134, 155)},
     {.completionPaper = rgb(29, 32, 33), .completionBorder = rgb(60, 56, 54),
      .completionSelection = rgb(41, 41, 41), .completionSelectedText = rgb(142, 192, 124),
      .wordMatch = rgb(250, 189, 47), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(131, 165, 152),
       .commandCaret = rgb(235, 219, 178)},
     rgb(235, 219, 178), true, false, {}, rgb(46, 47, 45), rgb(29, 32, 33), true},

    {"Gruvbox Dark Soft", rgb(50, 48, 47), rgb(54, 51, 50), rgb(64, 75, 62),
     rgb(50, 48, 47), rgb(80, 74, 68), rgb(102, 92, 84), rgb(235, 219, 178),
     {rgb(235, 219, 178), rgb(251, 73, 52), rgb(251, 73, 52), rgb(250, 189, 47),
      rgb(250, 189, 47), rgb(131, 165, 152), rgb(184, 187, 38), rgb(211, 134, 155),
      rgb(146, 131, 116), rgb(254, 128, 25), rgb(211, 134, 155), rgb(211, 134, 155)},
     {.completionPaper = rgb(50, 48, 47), .completionBorder = rgb(60, 56, 54),
      .completionSelection = rgb(54, 51, 50), .completionSelectedText = rgb(142, 192, 124),
      .wordMatch = rgb(250, 189, 47), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(131, 165, 152),
       .commandCaret = rgb(235, 219, 178)},
     rgb(235, 219, 178), true, false, {}, rgb(65, 61, 58), rgb(50, 48, 47), true},

    {"Gruvbox Light Medium", rgb(251, 241, 199), rgb(245, 233, 191), rgb(214, 220, 176),
     rgb(251, 241, 199), rgb(219, 208, 174), rgb(189, 174, 147), rgb(60, 56, 54),
     {rgb(60, 56, 54), rgb(157, 0, 6), rgb(157, 0, 6), rgb(181, 118, 20),
      rgb(181, 118, 20), rgb(7, 102, 120), rgb(121, 116, 14), rgb(143, 63, 113),
      rgb(146, 131, 116), rgb(175, 58, 3), rgb(143, 63, 113), rgb(143, 63, 113)},
     {.completionPaper = rgb(251, 241, 199), .completionBorder = rgb(235, 219, 178),
      .completionSelection = rgb(245, 233, 191), .completionSelectedText = rgb(66, 123, 88),
      .wordMatch = rgb(181, 118, 20), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(7, 102, 120),
       .commandCaret = rgb(60, 56, 54)},
     rgb(60, 56, 54), false, false, {}, rgb(235, 225, 187), rgb(251, 241, 199), true},

    {"Gruvbox Light Hard", rgb(249, 245, 215), rgb(244, 235, 201), rgb(213, 223, 188),
     rgb(249, 245, 215), rgb(218, 211, 186), rgb(189, 174, 147), rgb(60, 56, 54),
     {rgb(60, 56, 54), rgb(157, 0, 6), rgb(157, 0, 6), rgb(181, 118, 20),
      rgb(181, 118, 20), rgb(7, 102, 120), rgb(121, 116, 14), rgb(143, 63, 113),
      rgb(146, 131, 116), rgb(175, 58, 3), rgb(143, 63, 113), rgb(143, 63, 113)},
     {.completionPaper = rgb(249, 245, 215), .completionBorder = rgb(235, 219, 178),
      .completionSelection = rgb(244, 235, 201), .completionSelectedText = rgb(66, 123, 88),
      .wordMatch = rgb(181, 118, 20), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(7, 102, 120),
       .commandCaret = rgb(60, 56, 54)},
     rgb(60, 56, 54), false, false, {}, rgb(233, 228, 201), rgb(249, 245, 215), true},

    {"Gruvbox Light Soft", rgb(242, 229, 188), rgb(239, 225, 184), rgb(207, 211, 167),
     rgb(242, 229, 188), rgb(212, 199, 166), rgb(189, 174, 147), rgb(60, 56, 54),
     {rgb(60, 56, 54), rgb(157, 0, 6), rgb(157, 0, 6), rgb(181, 118, 20),
      rgb(181, 118, 20), rgb(7, 102, 120), rgb(121, 116, 14), rgb(143, 63, 113),
      rgb(146, 131, 116), rgb(175, 58, 3), rgb(143, 63, 113), rgb(143, 63, 113)},
     {.completionPaper = rgb(242, 229, 188), .completionBorder = rgb(235, 219, 178),
      .completionSelection = rgb(239, 225, 184), .completionSelectedText = rgb(66, 123, 88),
      .wordMatch = rgb(181, 118, 20), .bracketMatch = rgb(146, 131, 116), .vimFlash = rgb(7, 102, 120),
       .commandCaret = rgb(60, 56, 54)},
     rgb(60, 56, 54), false, false, {}, rgb(227, 214, 177), rgb(242, 229, 188), true},

    // Tokyo Night 1.1.2
    {"Tokyo Night", rgb(26, 27, 38), rgb(30, 32, 46), rgb(43, 47, 65),
     rgb(26, 27, 38), rgb(16, 16, 20), rgb(54, 59, 84), rgb(120, 124, 153),
     {rgb(169, 177, 214), rgb(187, 154, 247), rgb(187, 154, 247), rgb(13, 185, 215),
      rgb(122, 162, 247), rgb(192, 202, 245), rgb(158, 206, 106), rgb(255, 158, 100),
      rgb(81, 89, 125), rgb(115, 218, 202), rgb(255, 158, 100), rgb(137, 221, 255)},
     {.completionPaper = rgb(22, 22, 30), .completionBorder = rgb(16, 16, 20),
      .completionSelection = rgb(32, 34, 44), .completionSelectedText = rgb(169, 177, 214),
      .wordMatch = rgb(81, 92, 126), .bracketMatch = rgb(66, 70, 93), .vimFlash = rgb(61, 89, 161),
       .commandCaret = rgb(192, 202, 245)},
     rgb(192, 202, 245), true, false, {}, rgb(54, 59, 84), rgb(26, 27, 38), true},

    {"Tokyo Night Storm", rgb(36, 40, 59), rgb(41, 46, 66), rgb(55, 61, 90),
     rgb(36, 40, 59), rgb(27, 30, 46), rgb(59, 66, 97), rgb(128, 137, 179),
     {rgb(169, 177, 214), rgb(187, 154, 247), rgb(187, 154, 247), rgb(42, 195, 222),
      rgb(122, 162, 247), rgb(192, 202, 245), rgb(158, 206, 106), rgb(255, 158, 100),
      rgb(95, 105, 150), rgb(115, 218, 202), rgb(255, 158, 100), rgb(137, 221, 255)},
     {.completionPaper = rgb(31, 35, 53), .completionBorder = rgb(27, 30, 46),
      .completionSelection = rgb(40, 46, 68), .completionSelectedText = rgb(169, 177, 214),
      .wordMatch = rgb(111, 123, 182), .bracketMatch = rgb(84, 92, 126), .vimFlash = rgb(61, 89, 161),
       .commandCaret = rgb(192, 202, 245)},
     rgb(192, 202, 245), true, false, {}, rgb(59, 66, 97), rgb(36, 40, 59), true},

    {"Tokyo Night Light", rgb(230, 231, 237), rgb(220, 222, 227), rgb(215, 217, 225),
     rgb(230, 231, 237), rgb(193, 194, 199), rgb(157, 160, 171), rgb(54, 60, 77),
     {rgb(52, 59, 89), rgb(101, 53, 157), rgb(101, 53, 157), rgb(0, 108, 134),
      rgb(41, 89, 170), rgb(52, 59, 88), rgb(56, 95, 13), rgb(150, 80, 39),
      rgb(136, 139, 148), rgb(51, 99, 92), rgb(150, 80, 39), rgb(54, 60, 77)},
     {.completionPaper = rgb(220, 222, 227), .completionBorder = rgb(193, 194, 199),
      .completionSelection = rgb(232, 233, 237), .completionSelectedText = rgb(54, 60, 77),
      .wordMatch = rgb(154, 165, 206), .bracketMatch = rgb(220, 222, 227), .vimFlash = rgb(45, 156, 145),
       .commandCaret = rgb(54, 60, 77)},
     rgb(54, 60, 77), false, false, {}, rgb(173, 176, 190), rgb(230, 231, 237), true},

    // Min Theme 1.5.0
    {"Min Dark", rgb(31, 31, 31), rgb(48, 48, 48), rgb(38, 79, 120),
     rgb(31, 31, 31), rgb(42, 42, 42), rgb(114, 114, 114), rgb(198, 198, 198),
     {rgb(187, 187, 187), rgb(249, 117, 131), rgb(249, 117, 131), rgb(179, 146, 240),
      rgb(179, 146, 240), rgb(187, 187, 187), rgb(255, 171, 112), rgb(248, 248, 248),
      rgb(107, 115, 124), rgb(249, 117, 131), rgb(121, 184, 255), rgb(248, 248, 248)},
     {.completionPaper = rgb(26, 26, 26), .completionBorder = rgb(42, 42, 42),
      .completionSelection = rgb(33, 33, 33), .completionSelectedText = rgb(245, 245, 245),
      .wordMatch = rgb(174, 175, 173), .bracketMatch = rgb(174, 175, 173), .vimFlash = rgb(174, 175, 173),
       .commandCaret = rgb(174, 175, 173)},
     rgb(174, 175, 173), true, false, {}, rgb(89, 89, 89), rgb(31, 31, 31)},

    {"Min Light", rgb(255, 255, 255), rgb(242, 242, 242), rgb(173, 214, 255),
     rgb(255, 255, 255), rgb(238, 238, 238), rgb(204, 204, 204), rgb(117, 117, 117),
     {rgb(36, 41, 46), rgb(211, 47, 47), rgb(211, 47, 47), rgb(111, 66, 193),
      rgb(111, 66, 193), rgb(36, 41, 46), rgb(34, 134, 58), rgb(25, 118, 210),
      rgb(194, 195, 197), rgb(211, 47, 47), rgb(25, 118, 210), rgb(25, 118, 210)},
     {.completionPaper = rgb(243, 243, 243), .completionBorder = rgb(238, 238, 238),
      .completionSelection = rgb(238, 238, 238), .completionSelectedText = rgb(33, 33, 33),
      .wordMatch = rgb(36, 41, 46), .bracketMatch = rgb(200, 225, 255), .vimFlash = rgb(36, 41, 46),
       .commandCaret = rgb(36, 41, 46)},
     rgb(36, 41, 46), false, false, {}, rgb(185, 187, 188), rgb(255, 255, 255)},

    // Alabaster 0.2.9
    {"Alabaster", rgb(247, 247, 247), rgb(240, 240, 240), rgb(191, 219, 254),
     rgb(247, 247, 247), rgb(215, 215, 215), rgb(157, 163, 154), rgb(0, 0, 0),
     {rgb(0, 0, 0), rgb(0, 0, 0), rgb(0, 0, 0), rgb(50, 92, 192),
      rgb(50, 92, 192), rgb(0, 0, 0), rgb(68, 140, 39), rgb(122, 62, 157),
      rgb(170, 55, 49), rgb(0, 0, 0), rgb(122, 62, 157), rgb(119, 119, 119)},
     {.completionPaper = rgb(247, 247, 247), .completionBorder = rgb(215, 215, 215),
      .completionSelection = rgb(221, 221, 221), .completionSelectedText = rgb(0, 0, 0),
      .wordMatch = rgb(207, 207, 207), .bracketMatch = rgb(0, 122, 204), .vimFlash = rgb(156, 191, 145),
       .commandCaret = rgb(0, 122, 204)},
     rgb(0, 122, 204), false, false, {}, rgb(168, 168, 168), rgb(247, 247, 247)},

    // GameMaker's dark code editor colors, mapped to the editor's syntax groups.
    {"GameMaker Dark", rgb(34, 34, 34), rgb(48, 50, 51), rgb(57, 75, 93),
     rgb(50, 58, 65), rgb(80, 92, 101), rgb(130, 164, 178), rgb(203, 213, 221),
     {rgb(189, 189, 189), rgb(255, 184, 113), rgb(255, 184, 113), rgb(88, 229, 90),
      rgb(255, 184, 113), rgb(178, 177, 255), rgb(255, 255, 0), rgb(255, 128, 128),
      rgb(91, 153, 91), rgb(184, 113, 255), rgb(255, 128, 128), rgb(255, 128, 128)},
     {.completionPaper = rgb(27, 27, 27), .completionBorder = rgb(66, 71, 74),
      .completionSelection = rgb(78, 88, 105), .completionSelectedText = rgb(245, 245, 245),
      .wordMatch = rgb(108, 142, 159), .bracketMatch = rgb(114, 191, 255), .vimFlash = rgb(255, 184, 113),
       .commandCaret = rgb(157, 175, 195)},
     rgb(245, 245, 245), true, false, gameMakerBrackets, rgb(104, 119, 129), rgb(34, 34, 34)},

    // Qt Creator's default_classic.xml.
    {"Qt Creator Classic", rgb(255, 255, 255), rgb(193, 221, 238), rgb(48, 140, 198),
     rgb(239, 235, 231), rgb(209, 205, 201), rgb(159, 157, 154), rgb(128, 128, 128),
     {rgb(0, 0, 0), rgb(128, 128, 0), rgb(128, 128, 0), rgb(128, 0, 128),
      rgb(0, 0, 0), rgb(0, 0, 0), rgb(0, 128, 0), rgb(0, 0, 128),
      rgb(0, 128, 0), rgb(0, 0, 128), rgb(128, 0, 128), rgb(0, 0, 128)},
     {.completionPaper = rgb(247, 244, 241), .completionBorder = rgb(198, 194, 190),
      .completionSelection = rgb(192, 192, 255), .completionSelectedText = rgb(0, 0, 128),
      .wordMatch = rgb(180, 180, 180), .bracketMatch = rgb(0, 128, 0), .vimFlash = rgb(169, 134, 210),
       .commandCaret = rgb(48, 140, 198)},
     rgb(0, 0, 0), false, false, {}, rgb(192, 192, 192), rgb(255, 255, 255), false, true},

    {"Qt Creator Dark", rgb(46, 47, 48), rgb(55, 55, 55), rgb(29, 84, 92),
     rgb(64, 66, 68), rgb(81, 83, 85), rgb(190, 192, 194), rgb(214, 197, 64),
     qtCreatorDarkInk, qtCreatorDarkAccents,
     rgb(214, 207, 154), true, false, {}, rgb(108, 109, 112), rgb(46, 47, 48), true, true},

    {"Qt Creator Dark (2024)", rgb(31, 31, 31), rgb(55, 55, 55), rgb(63, 63, 63),
     rgb(38, 38, 38), rgb(54, 54, 54), rgb(174, 174, 174), rgb(30, 201, 116),
     qtCreatorDarkInk, qtCreatorDarkAccents,
     rgb(214, 207, 154), true, false, {}, rgb(108, 109, 112), rgb(31, 31, 31), true, true},

    // light-2024.xml inherits Qt Creator's built-in syntax colors from fontsettings.cpp.
    {"Qt Creator Light (2024)", rgb(252, 252, 252), rgb(241, 241, 241), rgb(205, 205, 205),
     rgb(242, 242, 242), rgb(216, 216, 216), rgb(89, 89, 89), rgb(18, 167, 93),
     {rgb(10, 10, 10), rgb(128, 128, 0), rgb(128, 128, 0), rgb(128, 0, 128),
      rgb(0, 103, 124), rgb(9, 46, 100), rgb(0, 128, 0), rgb(0, 0, 128),
      rgb(0, 128, 0), rgb(0, 0, 128), rgb(128, 0, 128), rgb(0, 103, 124)},
     {.completionPaper = rgb(248, 248, 248), .completionBorder = rgb(216, 216, 216),
      .completionSelection = rgb(205, 205, 205), .completionSelectedText = rgb(10, 10, 10),
      .wordMatch = rgb(174, 174, 174), .bracketMatch = rgb(18, 167, 93), .vimFlash = rgb(130, 190, 153),
       .commandCaret = rgb(18, 167, 93)},
     rgb(10, 10, 10), false, false, {}, rgb(153, 153, 153), rgb(252, 252, 252), false, true},

    // Chris Kempson's Tomorrow Night variants, using the original full-color palettes.
    {"Tomorrow Night Blue", rgb(0, 36, 81), rgb(0, 52, 110), rgb(0, 63, 142),
     rgb(8, 42, 85), rgb(36, 71, 117), rgb(114, 133, 183), rgb(187, 218, 255),
     {rgb(255, 255, 255), rgb(235, 187, 255), rgb(235, 187, 255), rgb(255, 238, 173),
      rgb(187, 218, 255), rgb(255, 255, 255), rgb(209, 241, 169), rgb(255, 197, 143),
      rgb(114, 133, 183), rgb(153, 255, 255), rgb(255, 157, 164), rgb(255, 238, 173)},
     {.completionPaper = rgb(8, 44, 89), .completionBorder = rgb(49, 84, 134),
      .completionSelection = rgb(0, 63, 142), .completionSelectedText = rgb(255, 255, 255),
      .wordMatch = rgb(114, 133, 183), .bracketMatch = rgb(153, 255, 255), .vimFlash = rgb(66, 138, 184),
       .commandCaret = rgb(187, 218, 255)},
     rgb(255, 255, 255), true, false, {}, rgb(90, 113, 156), rgb(0, 36, 81)},

    {"Tomorrow Night Bright", rgb(0, 0, 0), rgb(42, 42, 42), rgb(66, 66, 66),
     rgb(13, 13, 13), rgb(48, 48, 48), rgb(150, 152, 150), rgb(234, 234, 234),
     {rgb(234, 234, 234), rgb(195, 151, 216), rgb(195, 151, 216), rgb(231, 197, 71),
      rgb(122, 166, 218), rgb(234, 234, 234), rgb(185, 202, 74), rgb(231, 140, 69),
      rgb(150, 152, 150), rgb(112, 192, 177), rgb(213, 78, 83), rgb(231, 197, 71)},
     {.completionPaper = rgb(19, 19, 19), .completionBorder = rgb(66, 66, 66),
      .completionSelection = rgb(66, 66, 66), .completionSelectedText = rgb(234, 234, 234),
      .wordMatch = rgb(122, 166, 218), .bracketMatch = rgb(112, 192, 177), .vimFlash = rgb(83, 142, 135),
       .commandCaret = rgb(234, 234, 234)},
     rgb(234, 234, 234), true, false, {}, rgb(116, 118, 116), rgb(0, 0, 0)},

    {"Tomorrow Night Eighties", rgb(45, 45, 45), rgb(57, 57, 57), rgb(81, 81, 81),
     rgb(51, 51, 51), rgb(72, 72, 72), rgb(153, 153, 153), rgb(204, 204, 204),
     {rgb(204, 204, 204), rgb(204, 153, 204), rgb(204, 153, 204), rgb(255, 204, 102),
      rgb(102, 153, 204), rgb(204, 204, 204), rgb(153, 204, 153), rgb(249, 145, 87),
      rgb(153, 153, 153), rgb(102, 204, 204), rgb(242, 119, 122), rgb(255, 204, 102)},
     {.completionPaper = rgb(53, 53, 53), .completionBorder = rgb(83, 83, 83),
      .completionSelection = rgb(81, 81, 81), .completionSelectedText = rgb(204, 204, 204),
      .wordMatch = rgb(102, 153, 204), .bracketMatch = rgb(102, 204, 204), .vimFlash = rgb(164, 105, 105),
       .commandCaret = rgb(204, 204, 204)},
     rgb(204, 204, 204), true, false, {}, rgb(125, 125, 125), rgb(45, 45, 45)},

    // Legacy color presets from Xcode's bundled FontAndColorThemes.
    XcodeTheme("Xcode Bare", rgb(255, 255, 255), rgb(243, 243, 244), rgb(164, 205, 255),
        {rgb(0, 0, 0), rgb(0, 0, 204), rgb(0, 0, 204), rgb(153, 0, 102),
         rgb(0, 0, 204), rgb(0, 0, 0), rgb(255, 51, 153), rgb(0, 0, 204),
         rgb(85, 85, 85), rgb(0, 0, 204), rgb(0, 0, 204), rgb(0, 0, 204)}, rgb(0, 0, 0), rgb(179, 179, 179),
          rgb(144, 135, 214)),
    XcodeTheme("Xcode Basic", rgb(255, 255, 255), rgb(243, 243, 244), rgb(164, 205, 255),
        {rgb(0, 0, 0), rgb(0, 0, 255), rgb(0, 0, 255), rgb(43, 131, 159),
         rgb(43, 131, 159), rgb(0, 0, 0), rgb(163, 21, 21), rgb(0, 0, 0),
         rgb(0, 128, 0), rgb(0, 0, 255), rgb(43, 131, 159), rgb(0, 0, 0)}, rgb(0, 0, 0), rgb(204, 204, 204),
          rgb(128, 191, 194)),
    XcodeTheme("Xcode Civic", rgb(31, 32, 41), rgb(40, 41, 56), rgb(53, 64, 78),
        {rgb(225, 226, 231), rgb(215, 0, 143), rgb(215, 0, 143), rgb(37, 144, 141),
         rgb(29, 169, 162), rgb(225, 226, 231), rgb(211, 35, 46), rgb(20, 156, 146),
         rgb(69, 187, 62), rgb(199, 122, 75), rgb(29, 169, 162), rgb(116, 109, 176)}, rgb(255, 255, 255),
          rgb(77, 77, 77), rgb(55, 143, 133), true),
    XcodeTheme("Xcode Classic (Dark)", rgb(31, 31, 36), rgb(35, 37, 43), rgb(81, 91, 112),
        {rgb(221, 221, 222), rgb(252, 95, 163), rgb(252, 95, 163), rgb(208, 168, 255),
         rgb(103, 183, 164), rgb(221, 221, 222), rgb(252, 106, 93), rgb(208, 191, 105),
         rgb(115, 167, 78), rgb(253, 143, 63), rgb(103, 183, 164), rgb(208, 191, 105)}, rgb(255, 255, 255), rgb(66, 77, 91), rgb(83, 150, 137), true),
    XcodeTheme("Xcode Classic (Light)", rgb(255, 255, 255), rgb(232, 242, 255), rgb(164, 205, 255),
        {rgb(38, 38, 38), rgb(155, 35, 147), rgb(155, 35, 147), rgb(57, 0, 160),
         rgb(50, 109, 116), rgb(38, 38, 38), rgb(196, 26, 22), rgb(28, 0, 207),
         rgb(38, 117, 7), rgb(100, 56, 32), rgb(50, 109, 116), rgb(28, 0, 207)}, rgb(0, 0, 0),
          rgb(204, 204, 204), rgb(125, 175, 188)),
    XcodeTheme("Xcode Default (Dark)", rgb(31, 31, 36), rgb(35, 37, 43), rgb(81, 91, 112),
        {rgb(221, 221, 222), rgb(252, 95, 163), rgb(252, 95, 163), rgb(208, 168, 255),
         rgb(103, 183, 164), rgb(221, 221, 222), rgb(252, 106, 93), rgb(208, 191, 105),
         rgb(108, 121, 134), rgb(253, 143, 63), rgb(103, 183, 164), rgb(208, 191, 105)}, rgb(255, 255, 255), rgb(66, 77, 91), rgb(83, 150, 137), true),
    XcodeTheme("Xcode Default (Light)", rgb(255, 255, 255), rgb(232, 242, 255), rgb(164, 205, 255),
        {rgb(38, 38, 38), rgb(155, 35, 147), rgb(155, 35, 147), rgb(57, 0, 160),
         rgb(50, 109, 116), rgb(38, 38, 38), rgb(196, 26, 22), rgb(28, 0, 207),
         rgb(93, 108, 121), rgb(100, 56, 32), rgb(50, 109, 116), rgb(28, 0, 207)}, rgb(0, 0, 0),
          rgb(204, 204, 204), rgb(125, 175, 188)),
    XcodeTheme("Xcode High Contrast (Dark)", rgb(24, 23, 27), rgb(35, 37, 43), rgb(52, 60, 75),
        {rgb(255, 255, 255), rgb(252, 107, 170), rgb(252, 107, 170), rgb(222, 193, 255),
         rgb(114, 191, 174), rgb(255, 255, 255), rgb(252, 116, 103), rgb(208, 188, 86),
         rgb(124, 181, 84), rgb(253, 143, 63), rgb(114, 191, 174), rgb(208, 188, 86)}, rgb(255, 255, 255),
          rgb(66, 77, 91), rgb(64, 167, 151), true),
    XcodeTheme("Xcode High Contrast (Light)", rgb(255, 255, 255), rgb(232, 242, 255), rgb(164, 205, 255),
        {rgb(0, 0, 0), rgb(136, 0, 126), rgb(136, 0, 126), rgb(51, 0, 144),
         rgb(41, 75, 78), rgb(0, 0, 0), rgb(155, 5, 9), rgb(28, 2, 207),
         rgb(26, 83, 1), rgb(100, 56, 32), rgb(41, 75, 78), rgb(28, 2, 207)}, rgb(0, 0, 0),
          rgb(204, 204, 204), rgb(103, 159, 203)),
    XcodeTheme("Xcode Low Key", rgb(255, 255, 255), rgb(243, 245, 244), rgb(207, 213, 209),
        {rgb(0, 0, 0), rgb(38, 44, 106), rgb(38, 44, 106), rgb(71, 106, 151),
         rgb(71, 106, 151), rgb(0, 0, 0), rgb(112, 44, 81), rgb(38, 44, 106),
         rgb(67, 81, 56), rgb(0, 0, 0), rgb(71, 106, 151), rgb(38, 44, 106)}, rgb(0, 0, 0),
          rgb(179, 179, 179), rgb(156, 174, 183)),
    XcodeTheme("Xcode Midnight", rgb(0, 0, 0), rgb(26, 25, 25), rgb(75, 71, 64),
        {rgb(255, 255, 255), rgb(211, 24, 149), rgb(211, 24, 149), rgb(0, 160, 255),
         rgb(35, 255, 131), rgb(255, 255, 255), rgb(255, 44, 56), rgb(120, 109, 255),
         rgb(65, 204, 69), rgb(228, 124, 72), rgb(35, 255, 131), rgb(120, 109, 255)}, rgb(255, 255, 255),
          rgb(51, 51, 51), rgb(50, 137, 92), true),
    XcodeTheme("Xcode Printing", rgb(255, 255, 255), rgb(255, 255, 255), rgb(196, 196, 196),
        {rgb(0, 0, 0), rgb(89, 89, 89), rgb(89, 89, 89), rgb(69, 69, 69),
         rgb(65, 65, 65), rgb(0, 0, 0), rgb(93, 93, 93), rgb(55, 55, 55),
         rgb(93, 93, 93), rgb(67, 67, 67), rgb(65, 65, 65), rgb(55, 55, 55)}, rgb(0, 0, 0),
          rgb(179, 179, 179), rgb(171, 171, 171)),
    XcodeTheme("Xcode Spartan", rgb(255, 255, 255), rgb(237, 237, 239), rgb(164, 205, 255),
        {rgb(0, 0, 0), rgb(211, 22, 121), rgb(211, 22, 121), rgb(71, 106, 151),
         rgb(71, 106, 151), rgb(0, 0, 0), rgb(102, 102, 102), rgb(0, 0, 0),
         rgb(178, 0, 0), rgb(0, 0, 0), rgb(71, 106, 151), rgb(0, 0, 0)}, rgb(0, 0, 0), rgb(128, 128, 128),
          rgb(145, 174, 207)),
    XcodeTheme("Xcode Sunset", rgb(255, 252, 229), rgb(253, 245, 211), rgb(249, 223, 156),
        {rgb(0, 0, 0), rgb(41, 66, 119), rgb(41, 66, 119), rgb(180, 69, 0),
         rgb(71, 106, 151), rgb(0, 0, 0), rgb(223, 7, 0), rgb(41, 66, 119),
         rgb(195, 116, 28), rgb(100, 100, 133), rgb(71, 106, 151), rgb(41, 66, 119)}, rgb(0, 0, 0),
          rgb(209, 197, 164), rgb(216, 157, 134)),

    // Qt Creator's console-style dark.xml.
    {"Qt Creator Dark Classic", rgb(0, 0, 0), rgb(35, 35, 35), rgb(170, 170, 170),
     rgb(35, 35, 35), rgb(55, 55, 55), rgb(136, 136, 136), rgb(170, 170, 170),
     {rgb(170, 170, 170), rgb(255, 255, 85), rgb(255, 255, 85), rgb(85, 255, 85),
      rgb(170, 170, 170), rgb(170, 170, 170), rgb(255, 85, 255), rgb(255, 85, 255),
      rgb(85, 255, 255), rgb(85, 85, 255), rgb(255, 85, 255), rgb(255, 85, 85)},
     {.completionPaper = rgb(23, 23, 23), .completionBorder = rgb(69, 69, 69),
      .completionSelection = rgb(51, 51, 51), .completionSelectedText = rgb(160, 160, 255),
      .wordMatch = rgb(170, 170, 170), .bracketMatch = rgb(255, 85, 85), .vimFlash = rgb(135, 76, 150),
       .commandCaret = rgb(170, 170, 170)},
     rgb(255, 255, 255), true, false, {}, rgb(64, 64, 64), rgb(0, 0, 0), false, true},

    {"Serial Experiments Lain", rgb(21, 21, 37), rgb(34, 34, 56), rgb(51, 56, 94),
     rgb(25, 25, 43), rgb(47, 48, 77), rgb(130, 135, 167), rgb(137, 245, 215),
     {rgb(119, 241, 211), rgb(156, 255, 225), rgb(156, 255, 225), rgb(109, 221, 208),
      rgb(135, 246, 215), rgb(119, 241, 211), rgb(142, 233, 203), rgb(170, 247, 218),
      rgb(160, 158, 206), rgb(133, 212, 215), rgb(170, 247, 218), rgb(163, 234, 223)},
     {.completionPaper = rgb(28, 28, 50), .completionBorder = rgb(68, 69, 99),
      .completionSelection = rgb(51, 56, 94), .completionSelectedText = rgb(168, 255, 231),
      .wordMatch = rgb(121, 149, 202), .bracketMatch = rgb(129, 221, 219), .vimFlash = rgb(166, 160, 215),
       .commandCaret = rgb(138, 214, 220)},
     rgb(147, 255, 225), true, false, {}, rgb(121, 129, 159), rgb(21, 21, 37)},

    {"Serial Experiments Lain Lisp", rgb(0, 0, 0), rgb(17, 27, 32), rgb(164, 80, 137),
     rgb(11, 16, 21), rgb(36, 44, 57), rgb(126, 150, 156), rgb(161, 229, 223),
     {rgb(132, 212, 208), rgb(162, 233, 225), rgb(162, 233, 225), rgb(124, 212, 218),
      rgb(145, 220, 214), rgb(132, 212, 208), rgb(152, 221, 204), rgb(168, 232, 216),
      rgb(179, 154, 218), rgb(130, 190, 201), rgb(168, 232, 216), rgb(175, 220, 231)},
     {.completionPaper = rgb(16, 23, 29), .completionBorder = rgb(79, 61, 102),
      .completionSelection = rgb(164, 80, 137), .completionSelectedText = rgb(255, 244, 253),
      .wordMatch = rgb(181, 135, 208), .bracketMatch = rgb(153, 219, 216), .vimFlash = rgb(177, 132, 208),
       .commandCaret = rgb(173, 142, 210)},
     rgb(183, 240, 234), true, false, {}, rgb(136, 149, 163), rgb(0, 0, 0), false, true},

    // Gruber Darker 0.7, as used in Tsoding's Emacs configuration.
    {"Tsoding (Gruber Darker)", rgb(24, 24, 24), rgb(40, 40, 40), rgb(72, 72, 72),
     rgb(24, 24, 24), rgb(69, 61, 65), rgb(82, 73, 78), rgb(255, 221, 51),
     {rgb(228, 228, 239), rgb(255, 221, 51), rgb(255, 221, 51), rgb(149, 169, 159),
      rgb(150, 166, 200), rgb(244, 244, 255), rgb(115, 201, 54), rgb(158, 149, 199),
      rgb(204, 140, 60), rgb(149, 169, 159), rgb(149, 169, 159), rgb(255, 221, 51)},
     {.completionPaper = rgb(40, 40, 40), .completionBorder = rgb(69, 61, 65),
      .completionSelection = rgb(72, 72, 72), .completionSelectedText = rgb(244, 244, 255),
      .wordMatch = rgb(150, 166, 200), .bracketMatch = rgb(204, 140, 60), .vimFlash = rgb(255, 221, 51),
       .commandCaret = rgb(255, 221, 51)},
     rgb(255, 221, 51), true, false, {}, rgb(125, 116, 120), rgb(24, 24, 24)},

    // Monokai Soda.tmTheme from Ian Hill's colour-schemes.zip.
    {"Monokai Soda", rgb(34, 34, 34), rgb(51, 51, 51), rgb(68, 68, 68),
     rgb(34, 34, 34), rgb(59, 58, 50), rgb(144, 144, 138), rgb(248, 248, 242),
     monokaiInk,
     {.completionPaper = rgb(43, 43, 43), .completionBorder = rgb(85, 85, 85),
      .completionSelection = rgb(68, 68, 68), .completionSelectedText = rgb(248, 248, 242),
      .wordMatch = rgb(255, 231, 146), .bracketMatch = rgb(230, 219, 116), .vimFlash = rgb(120, 152, 75),
       .commandCaret = rgb(248, 248, 240)},
     rgb(248, 248, 240), true, true, {}, rgb(59, 58, 50)},

    Base2Tone::cave.dark, Base2Tone::cave.light,
    Base2Tone::desert.dark, Base2Tone::desert.light,
    Base2Tone::drawbridge.dark, Base2Tone::drawbridge.light,
    Base2Tone::earth.dark, Base2Tone::earth.light,
    Base2Tone::evening.dark, Base2Tone::evening.light,
    Base2Tone::field.dark, Base2Tone::field.light,
    Base2Tone::forest.dark, Base2Tone::forest.light,
    Base2Tone::garden.dark, Base2Tone::garden.light,
    Base2Tone::heath.dark, Base2Tone::heath.light,
    Base2Tone::lake.dark, Base2Tone::lake.light,
    Base2Tone::lavender.dark, Base2Tone::lavender.light,
    Base2Tone::mall.dark, Base2Tone::mall.light,
    Base2Tone::meadow.dark, Base2Tone::meadow.light,
    Base2Tone::morning.dark, Base2Tone::morning.light,
    Base2Tone::motel.dark, Base2Tone::motel.light,
    Base2Tone::pool.dark, Base2Tone::pool.light,
    Base2Tone::porch.dark, Base2Tone::porch.light,
    Base2Tone::sea.dark, Base2Tone::sea.light,
    Base2Tone::space.dark, Base2Tone::space.light,
    Base2Tone::suburb.dark, Base2Tone::suburb.light,

    // Dark olive paper and warm syntax colors from the projected RustConf slides.
    {"Zenburn (Catherine West 2018)", rgb(35, 33, 24), rgb(41, 39, 29), rgb(69, 69, 50),
     rgb(28, 27, 19), rgb(56, 55, 38), rgb(137, 133, 113), rgb(210, 206, 195),
     {rgb(210, 206, 195), rgb(203, 185, 154), rgb(203, 185, 154), rgb(218, 209, 154),
      rgb(224, 209, 133), rgb(210, 206, 195), rgb(201, 144, 131), rgb(138, 189, 180),
      rgb(121, 132, 99), rgb(121, 132, 99), rgb(216, 207, 161), rgb(222, 169, 154)},
     {.completionPaper = rgb(44, 42, 30), .completionBorder = rgb(83, 82, 58),
      .completionSelection = rgb(69, 69, 50), .completionSelectedText = rgb(228, 221, 195),
      .wordMatch = rgb(163, 170, 112), .bracketMatch = rgb(211, 198, 124), .vimFlash = rgb(132, 172, 137),
       .commandCaret = rgb(224, 224, 224)},
     rgb(224, 224, 224), true, false, {}, rgb(116, 115, 93), rgb(0, 0, 0)},
};