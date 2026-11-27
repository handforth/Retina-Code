#pragma once

#import <AppKit/AppKit.h>
#import <CoreText/CTLine.h>
#include "../Color.h"
#include <span>
#include <vector>

enum class Smoothing { RetinaLCD = 0, System = 2, RetinaWeb = 3 };
enum class WhitespaceMode { None, Boundary, Selection, Trailing, All };

struct RenderSettings {
    Smoothing smoothing = Smoothing::RetinaLCD;
    CGFloat saturation = 1.10;
    CGFloat strokeWeight = 1.05;
    CGFloat fringing = 1.10;
    CGFloat softness = 1.40;
    CGFloat brightness = 1.01;
    WhitespaceMode whitespace = WhitespaceMode::None;
};

NSColor *SRGBColor(Col32 color);
NSColor *RenderedEditorColor(Col32 color, const RenderSettings &settings);

struct EditorFold {
    NSUInteger header;
    NSRange hidden;
};

enum class InlayGapKind : uint8_t { Glyph, Tab, Leading };

struct InlayGap {
    NSUInteger at;
    NSUInteger lineStart, lineEnd;
    NSUInteger glyphStart;
    CGFloat width;
    CGFloat preceding;
    InlayGapKind kind;
};

@protocol EditorInlaySpacing <NSObject>
- (std::span<const InlayGap>)inlayGaps;
@end

@interface CodeLayoutManager : NSLayoutManager <NSLayoutManagerDelegate>
- (void)drawGlyphsForGlyphRange:(NSRange)range atPoint:(NSPoint)origin color:(NSColor *)color;
- (void)drawShapedLine:(CTLineRef)line atPoint:(NSPoint)point color:(NSColor *)color;
- (void)setSelectionColor:(NSColor *)color characterRanges:(std::span<const NSRange>)ranges;
- (void)setDefinitionLinkRange:(NSRange)range;
- (const std::vector<EditorFold> &)editorFolds;
- (const std::vector<NSRange> &)hiddenEditorRanges;
- (void)setEditorFolds:(std::vector<EditorFold>)folds;
- (void)setInlaySpacingSource:(id<EditorInlaySpacing>)source;
- (CGFloat)inlayWidthAfterCharacter:(NSUInteger)character;
@end

void DrawEditorSurface(NSView *view, NSRect dirty, RenderSettings settings, NSColor *paper, CodeLayoutManager *layout,
                       void (^draw)(NSRect));
void DrawEditorWhitespace(NSTextView *view, NSRect dirty, NSFont *font, WhitespaceMode mode, Col32 color,
                          Col32 selectionBackground, std::vector<NSRange> &selections,
                          std::vector<NSRange> &inactiveSelections);