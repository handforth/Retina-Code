#pragma once

#import <AppKit/AppKit.h>
#include <span>
#include <vector>

enum class Smoothing { RetinaLCD = 0, System = 2, RetinaWeb = 3 };
enum class WhitespaceMode { None, Boundary, Selection, Trailing, All };

struct RenderSettings {
    Smoothing smoothing = Smoothing::RetinaLCD;
    CGFloat saturation = 1.10;
    CGFloat strokeWeight = 1.07;
    CGFloat fringing = 1.10;
    CGFloat softness = 1.40;
    CGFloat brightness = 1.01;
    WhitespaceMode whitespace = WhitespaceMode::None;
};

NSColor *SRGBHex(uint32_t rgb);
NSColor *RenderedEditorColor(uint32_t rgb, const RenderSettings &settings);

struct EditorFold {
    NSUInteger header;
    NSRange hidden;
};

@interface CodeLayoutManager : NSLayoutManager <NSLayoutManagerDelegate>
- (void)drawGlyphsForGlyphRange:(NSRange)range atPoint:(NSPoint)origin color:(NSColor *)color;
- (void)setSelectionColor:(NSColor *)color characterRanges:(std::span<const NSRange>)ranges;
- (const std::vector<EditorFold> &)editorFolds;
- (const std::vector<NSRange> &)hiddenEditorRanges;
- (void)setEditorFolds:(std::vector<EditorFold>)folds;
@end

void DrawEditorSurface(NSView *view, NSRect dirty, RenderSettings settings, NSColor *paper, CodeLayoutManager *layout,
                       void (^draw)(NSRect));
void DrawEditorWhitespace(NSTextView *view, NSRect dirty, NSFont *font, WhitespaceMode mode, uint32_t color,
                          uint32_t selectionBackground, std::vector<NSRange> &selections,
                          std::vector<NSRange> &inactiveSelections);