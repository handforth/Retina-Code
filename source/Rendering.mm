#import "Rendering.h"

#import <CoreText/CoreText.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <list>
#include <optional>
#include <unordered_map>
#include <utility>
#include <vector>

NSColor *SRGBColor(Col32 color)
{
    return [NSColor colorWithSRGBRed:ColorRed(color) / 255.0
                              green:ColorGreen(color) / 255.0
                               blue:ColorBlue(color) / 255.0
                              alpha:ColorAlpha(color) / 255.0];
}

struct GlyphMask {
    int left = 0;
    int bottom = 0;
    int width = 0;
    int height = 0;
    std::vector<uint8_t> coverage;
};

class GlyphCache {
    struct Entry {
        uint64_t key;
        size_t bytes;
        GlyphMask mask;
    };

    static constexpr size_t memoryLimit = 3 * 1024 * 1024;
    size_t _bytes = 0;
    std::list<Entry> _entries;
    std::unordered_map<uint64_t, std::list<Entry>::iterator> _index;

public:
    const GlyphMask *find(uint64_t key)
    {
        auto entry = _index.find(key);
        if (entry == _index.end())
            return nullptr;
        _entries.splice(_entries.begin(), _entries, entry->second);
        return &entry->second->mask;
    }

    const GlyphMask *insert(uint64_t key, GlyphMask &mask)
    {
        size_t cost = mask.coverage.capacity() + sizeof(Entry) + 64;
        if (cost > memoryLimit)
            return &mask;
        while (_bytes + cost > memoryLimit) {
            const Entry &oldest = _entries.back();
            _bytes -= oldest.bytes;
            _index.erase(oldest.key);
            _entries.pop_back();
        }
        _entries.push_front({key, cost, std::move(mask)});
        _index.emplace(key, _entries.begin());
        _bytes += cost;
        return &_entries.front().mask;
    }

    void clear()
    {
        _entries.clear();
        _index.clear();
        _bytes = 0;
    }
};

static GlyphCache &SharedGlyphMasks()
{
    // Tabs and split views rasterize the same fonts on the AppKit drawing thread.
    static GlyphCache masks;
    return masks;
}

struct MaskFont {
    NSFont *font = nil;
    bool hasColorGlyphs = false;
};

static const MaskFont &CachedMaskFont(NSFont *font, uint32_t &slot)
{
    static MaskFont fonts[32];
    static uint32_t count, last;
    if (count && fonts[last].font == font) {
        slot = last;
        return fonts[last];
    }

    for (uint32_t i = 0; i < count; ++i) {
        if ([fonts[i].font isEqual:font]) {
            slot = last = i;
            return fonts[i];
        }
    }

    if (count == std::size(fonts)) {
        for (auto &entry : fonts)
            entry = {};
        SharedGlyphMasks().clear();
        count = 0;
    }

    CTFontRef coreFont = (__bridge CTFontRef)font;
    slot = last = count++;
    fonts[slot] = {font, (CTFontGetSymbolicTraits(coreFont) & kCTFontTraitColorGlyphs) != 0};
    return fonts[slot];
}

struct GlyphStyle {
    Smoothing smoothing;
    CGFloat strokeWeight;
    CGFloat fringing;
    CGFloat softness;
    bool darkPaper;

    bool operator==(const GlyphStyle &) const = default;
};

static uint32_t GlyphStyleSlot(const RenderSettings &settings, bool darkPaper)
{
    static std::array<GlyphStyle, 8> styles;
    static size_t count;
    GlyphStyle style{settings.smoothing, settings.strokeWeight, settings.fringing, settings.softness, darkPaper};
    auto found = std::find(styles.begin(), styles.begin() + count, style);
    if (found != styles.begin() + count)
        return uint32_t(found - styles.begin());
    if (count == styles.size()) {
        SharedGlyphMasks().clear();
        count = 0;
    }
    styles[count] = style;
    return uint32_t(count++);
}

static constexpr int phases = 12;
static constexpr int verticalSamples = 4;
static constexpr int maxGlyphSize = 1024;
static constexpr int maxPaddedGlyphSize = maxGlyphSize + 6; // Pixel rounding and two pixels on each side.

using CoverageCurve = std::array<uint8_t, 9>;

static constexpr CoverageCurve webCurve = {0, 40, 74, 126, 158, 186, 213, 236, 255};
// Increase partial coverage on light paper to give dark ink a denser edge.
static constexpr CoverageCurve lightLCDCurve = {0, 61, 107, 146, 184, 223, 248, 255, 255};
static constexpr CoverageCurve darkLCDCurve = {0, 47, 87, 132, 177, 204, 227, 247, 255};
static constexpr int lcdFilter[] = {12, 62, 108, 62, 12};

static uint8_t AdjustCoverage(int coverage, const CoverageCurve &curve)
{
    int position = coverage * int(curve.size() - 1);
    int index = position / 255;
    int fraction = position % 255;
    int lower = curve[index];
    int upper = curve[std::min(index + 1, int(curve.size() - 1))];
    return uint8_t((lower * (255 - fraction) + upper * fraction + 127) / 255);
}

static void AddEdgeSpill(GlyphMask &mask, int opacity)
{
    size_t pixels = size_t(mask.width) * mask.height;
    std::vector<uint8_t> neutral(pixels);
    for (size_t pixel = 0; pixel < pixels; ++pixel) {
        const uint8_t *alpha = mask.coverage.data() + pixel * 4;
        neutral[pixel] = uint8_t((alpha[0] + 2 * alpha[1] + alpha[2] + 2) / 4);
    }

    // Spread a faint trace of ink one backing pixel from the stroke.
    for (int y = 1; y < mask.height - 1; ++y) {
        for (int x = 1; x < mask.width - 1; ++x) {
            size_t pixel = size_t(y) * mask.width + x;
            int neighbor = std::max({neutral[pixel - 1], neutral[pixel + 1],
                                     neutral[pixel - mask.width], neutral[pixel + mask.width]});
            int spill = (neighbor * opacity + 127) / 255;
            uint8_t *alpha = mask.coverage.data() + pixel * 4;
            for (int channel = 0; channel < 3; ++channel)
                alpha[channel] += uint8_t(((255 - alpha[channel]) * spill + 127) / 255);
        }
    }
}

static GlyphMask MakeMask(CTFontRef font, CGGlyph glyph, int phaseX, int phaseY, int scale,
                          const RenderSettings &settings, bool darkPaper)
{
    GlyphMask mask;
    CGPathRef outline = CTFontCreatePathForGlyph(font, glyph, nullptr);
    if (!outline)
        return mask;
    if (CGPathIsEmpty(outline)) {
        CGPathRelease(outline);
        return mask;
    }

    bool web = settings.smoothing == Smoothing::RetinaWeb;
    const CoverageCurve &curve = web ? webCurve : (darkPaper ? darkLCDCurve : lightLCDCurve);
    CGFloat stroke = CTFontGetSize(font) * (web ? 0.025 : (darkPaper ? 0.037 : 0.036)) * settings.strokeWeight;
    CGRect bounds = CGRectInset(CGPathGetPathBoundingBox(outline), -stroke / 2, -stroke / 2);
    if (bounds.size.width * scale > maxGlyphSize || bounds.size.height * scale > maxGlyphSize) {
        CGPathRelease(outline);
        mask.width = -1;
        return mask;
    }
    CGFloat x = CGFloat(phaseX) / phases;
    CGFloat y = CGFloat(phaseY) / phases;
    int padding = web ? 1 : 2;
    mask.left = int(std::floor(CGRectGetMinX(bounds) * scale + x)) - padding;
    mask.bottom = int(std::floor(CGRectGetMinY(bounds) * scale + y)) - padding;
    mask.width = int(std::ceil(CGRectGetMaxX(bounds) * scale + x)) + padding - mask.left;
    mask.height = int(std::ceil(CGRectGetMaxY(bounds) * scale + y)) + padding - mask.bottom;

    int samples = mask.width * 3;
    size_t stride = (size_t(samples) + 15) & ~size_t(15);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef raster = CGBitmapContextCreate(nullptr, samples, mask.height * verticalSamples, 8, stride,
                                                gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!raster) {
        CGPathRelease(outline);
        mask.width = -1;
        return mask;
    }

    // The three horizontal samples represent the red, green and blue stripes of a pixel.
    CGContextScaleCTM(raster, 3, verticalSamples);
    CGContextTranslateCTM(raster, x - mask.left, y - mask.bottom);
    CGContextScaleCTM(raster, scale, scale);
    CGContextSetShouldAntialias(raster, true);
    CGContextSetGrayFillColor(raster, 1, 1);
    CGContextSetGrayStrokeColor(raster, 1, 1);
    CGContextSetLineWidth(raster, stroke);
    CGContextSetLineJoin(raster, kCGLineJoinRound);
    CGContextAddPath(raster, outline);
    CGContextDrawPath(raster, stroke > 0 ? kCGPathFillStroke : kCGPathFill);
    CGPathRelease(outline);

    const auto *pixels = static_cast<const uint8_t *>(CGBitmapContextGetData(raster));
    mask.coverage.resize(size_t(mask.width) * mask.height * 4);
    int columns[maxPaddedGlyphSize * 3];
    int fringing = int(std::lround(settings.fringing * 256));
    for (int row = 0; row < mask.height; ++row) {
        const uint8_t *source = pixels + size_t(row * verticalSamples) * stride;
        for (int sample = 0; sample < samples; ++sample) {
            int coverage = 0;
            for (int y = 0; y < verticalSamples; ++y)
                coverage += source[size_t(y) * stride + sample];
            columns[sample] = coverage;
        }

        uint8_t *output = mask.coverage.data() + size_t(row) * mask.width * 4;
        for (int column = 0; column < samples; column += 3) {
            uint8_t *rgb = output + column / 3 * 4;
            if (web) {
                int coverage = (columns[column] + columns[column + 1] + columns[column + 2] +
                                verticalSamples * 3 / 2) / (verticalSamples * 3);
                uint8_t gray = AdjustCoverage(coverage, curve);
                rgb[0] = gray;
                rgb[1] = gray;
                rgb[2] = gray;
                continue;
            }

            for (int channel = 0; channel < 3; ++channel) {
                int coverage = 0;
                for (int tap = 0; tap < 5; ++tap) {
                    int sample = column + channel + tap - 2;
                    if (sample >= 0 && sample < samples)
                        coverage += lcdFilter[tap] * columns[sample];
                }
                coverage = (coverage + verticalSamples * 128) / (verticalSamples * 256);
                rgb[channel] = AdjustCoverage(coverage, curve);
            }

            if (darkPaper || fringing != 256) {
                int neutral = (rgb[0] + 2 * rgb[1] + rgb[2] + 2) / 4;
                for (int channel = 0; channel < 3; ++channel) {
                    int difference = rgb[channel] - neutral;
                    if (darkPaper)
                        difference += difference / 6;
                    rgb[channel] = uint8_t(std::clamp(neutral + difference * fringing / 256, 0, 255));
                }
            }
        }
    }
    CGContextRelease(raster);
    if (!web && settings.softness > 0)
        AddEdgeSpill(mask, int(std::lround((darkPaper ? 21 : 17) * settings.softness)));
    return mask;
}

static int PixelAndPhase(CGFloat position, int &phase)
{
    int pixel = int(std::floor(position));
    phase = int(std::lround((position - pixel) * phases));
    if (phase == phases) {
        ++pixel;
        phase = 0;
    }
    return pixel;
}

struct Surface {
    CGContextRef context = nullptr;
    uint8_t *data = nullptr;
    size_t stride = 0;
    int width = 0;
    int height = 0;
};

// Two RGBX pixels fit in eight 16-bit lanes. The unused byte has zero coverage.
using PixelBytes = uint8_t __attribute__((ext_vector_type(8)));
using PixelLanes = uint16_t __attribute__((ext_vector_type(8)));

static PixelLanes Divide255(PixelLanes value)
{
    return (value + (value >> 8) + 1) >> 8;
}

template<bool translucent>
static void BlendMask(const Surface &surface, const GlyphMask &mask, int x, int y,
                      CGRect clip, const std::array<int, 3> &ink, int opacity)
{
    int left = x + mask.left;
    int top = surface.height - (y + mask.bottom + mask.height);
    int firstX = std::max({0, -left, int(CGRectGetMinX(clip)) - left});
    int lastX = std::min({mask.width, surface.width - left, int(CGRectGetMaxX(clip)) - left});
    int firstY = std::max({0, -top, surface.height - int(CGRectGetMaxY(clip)) - top});
    int lastY = std::min({mask.height, surface.height - top,
                        surface.height - int(CGRectGetMinY(clip)) - top});
    if (firstX >= lastX || firstY >= lastY)
        return;

    PixelLanes color = {uint16_t(ink[0]), uint16_t(ink[1]), uint16_t(ink[2]), 0,
                        uint16_t(ink[0]), uint16_t(ink[1]), uint16_t(ink[2]), 0};
    for (int row = firstY; row < lastY; ++row) {
        uint8_t *pixel = surface.data + size_t(top + row) * surface.stride + (left + firstX) * 4;
        const uint8_t *alpha = mask.coverage.data() + (size_t(row) * mask.width + firstX) * 4;
        int column = firstX;
        for (; column + 1 < lastX; column += 2, pixel += 8, alpha += 8) {
            PixelBytes source, coverage;
            std::memcpy(&source, pixel, sizeof(source));
            std::memcpy(&coverage, alpha, sizeof(coverage));
            PixelLanes samples = __builtin_convertvector(coverage, PixelLanes);
            if constexpr (translucent)
                samples = Divide255(samples * uint16_t(opacity) + 127);
            PixelLanes background = __builtin_convertvector(source, PixelLanes);
            auto mixed = Divide255(background * (255 - samples) + color * samples + 127);
            auto packed = __builtin_convertvector(mixed, PixelBytes);
            std::memcpy(pixel, &packed, sizeof(packed));
        }

        if (column < lastX) {
            for (int channel = 0; channel < 3; ++channel) {
                int coverage = alpha[channel];
                if constexpr (translucent)
                    coverage = (coverage * opacity + 127) / 255;
                pixel[channel] = uint8_t((pixel[channel] * (255 - coverage) + ink[channel] * coverage + 127) / 255);
            }
        }
    }
}

static void DrawCoreText(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions,
                         size_t count, CGAffineTransform textMatrix, CGContextRef context)
{
    textMatrix.tx = 0;
    textMatrix.ty = 0;
    CGAffineTransform oldMatrix = CGContextGetTextMatrix(context);
    CGContextSaveGState(context);
    CGContextConcatCTM(context, textMatrix);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);

    // Core Text draws in an upright text space. Transform the supplied baselines along with it.
    CGAffineTransform inverse = CGAffineTransformInvert(textMatrix);
    CGPoint points[256];
    while (count) {
        size_t length = std::min(count, std::size(points));
        for (size_t i = 0; i < length; ++i)
            points[i] = CGPointApplyAffineTransform(positions[i], inverse);
        CTFontDrawGlyphs(font, glyphs, points, length, context);
        count -= length;
        glyphs += length;
        positions += length;
    }

    CGContextRestoreGState(context);
    CGContextSetTextMatrix(context, oldMatrix);
}

static void MergeRanges(std::vector<NSRange> &ranges)
{
    if (ranges.size() < 2)
        return;
    std::sort(ranges.begin(), ranges.end(), [](NSRange a, NSRange b) { return a.location < b.location; });
    size_t count = 0;
    for (NSRange range : ranges) {
        if (count && range.location <= NSMaxRange(ranges[count - 1]))
            ranges[count - 1] = NSUnionRange(ranges[count - 1], range);
        else
            ranges[count++] = range;
    }
    ranges.resize(count);
}

@interface CodeLayoutManager ()
- (void)beginSurface:(CGContextRef)context scale:(int)scale
            settings:(RenderSettings)settings darkPaper:(BOOL)darkPaper;
- (void)endSurface;
@end

@implementation CodeLayoutManager {
    Surface _surface;
    int _scale;
    RenderSettings _settings;
    BOOL _darkPaper;
    uint32_t _styleSlot;
    NSColor *_glyphColor;
    NSColor *_selectionColor;
    NSRange _definitionLink;
    std::vector<NSRange> _selectionRanges;
    std::vector<EditorFold> _folds;
    std::vector<NSRange> _hidden;
    __weak id<EditorInlaySpacing> _inlaySpacing;
}

- (const std::vector<EditorFold> &)editorFolds { return _folds; }
- (const std::vector<NSRange> &)hiddenEditorRanges { return _hidden; }

- (void)updateHiddenRanges
{
    _hidden.clear();
    for (const auto &fold : _folds) {
        if (!_hidden.empty() && fold.hidden.location <= NSMaxRange(_hidden.back()))
            _hidden.back() = NSUnionRange(_hidden.back(), fold.hidden);
        else
            _hidden.push_back(fold.hidden);
    }
    self.delegate = _hidden.empty() && !_inlaySpacing ? nil : self;
}

- (void)setInlaySpacingSource:(id<EditorInlaySpacing>)source
{
    _inlaySpacing = source;
    self.delegate = _hidden.empty() && !source ? nil : self;
}

- (CGFloat)inlayWidthAfterCharacter:(NSUInteger)character
{
    id<EditorInlaySpacing> source = _inlaySpacing;
    if (!source)
        return 0;
    auto gaps = [source inlayGaps];
    auto gap = std::ranges::lower_bound(gaps, character + 1, {}, &InlayGap::at);
    return gap != gaps.end() && gap->kind != InlayGapKind::Leading && character >= gap->glyphStart ? gap->width : 0;
}

- (BOOL)layoutManager:(NSLayoutManager *)layout shouldSetLineFragmentRect:(inout NSRect *)fragment
   lineFragmentUsedRect:(inout NSRect *)used baselineOffset:(inout CGFloat *)baseline
        inTextContainer:(NSTextContainer *)container forGlyphRange:(NSRange)range
{
    (void)baseline;
    (void)container;
    id<EditorInlaySpacing> source = _inlaySpacing;
    if (!source || !range.length)
        return NO;

    auto gaps = [source inlayGaps];
    NSUInteger at = [layout characterIndexForGlyphAtIndex:range.location];
    auto indent = std::ranges::lower_bound(gaps, at, {}, &InlayGap::at);
    if (indent == gaps.end() || indent->at != at || indent->kind != InlayGapKind::Leading)
        return NO;
    fragment->origin.x += indent->width;
    used->origin.x += indent->width;
    return YES;
}

static const InlayGap *InlayGapForTab(std::span<const InlayGap> gaps, NSUInteger character)
{
    auto gap = std::ranges::upper_bound(gaps, character + 1, {}, &InlayGap::at);
    if (gap == gaps.begin())
        return nullptr;
    --gap;
    return gap->kind != InlayGapKind::Leading && character >= gap->lineStart && character < gap->lineEnd ? &*gap : nullptr;
}

- (NSControlCharacterAction)layoutManager:(NSLayoutManager *)layout shouldUseAction:(NSControlCharacterAction)action
               forControlCharacterAtIndex:(NSUInteger)character
{
    (void)layout;
    id<EditorInlaySpacing> source = _inlaySpacing;
    if (!source || action != NSControlCharacterActionHorizontalTab)
        return action;
    return InlayGapForTab([source inlayGaps], character) ? NSControlCharacterActionWhitespace : action;
}

- (NSRect)layoutManager:(NSLayoutManager *)layout boundingBoxForControlGlyphAtIndex:(NSUInteger)glyph
       forTextContainer:(NSTextContainer *)container proposedLineFragment:(NSRect)fragment
          glyphPosition:(NSPoint)position characterIndex:(NSUInteger)character
{
    (void)glyph;
    (void)container;
    id<EditorInlaySpacing> source = _inlaySpacing;
    if (!source)
        return NSZeroRect;
    auto gap = InlayGapForTab([source inlayGaps], character);
    if (!gap)
        return NSZeroRect;

    NSParagraphStyle *style = [layout.textStorage attribute:NSParagraphStyleAttributeName
                                                     atIndex:character effectiveRange:nullptr];
    CGFloat interval = style.defaultTabInterval;
    if (interval <= 0)
        interval = 28;
    // Advance to the tab stop the source would have used before inserting the hints.
    bool attached = gap->at == character + 1 && gap->kind == InlayGapKind::Tab;
    CGFloat before = gap->preceding + (attached ? 0 : gap->width);
    CGFloat sourceX = std::max(0.0, position.x - NSMinX(fragment) - before);
    CGFloat stop = (std::floor((sourceX + 0.001) / interval) + 1) * interval;
    return NSMakeRect(0, 0, stop - sourceX + (attached ? gap->width : 0), 0);
}

- (void)setEditorFolds:(std::vector<EditorFold>)folds
{
    std::sort(folds.begin(), folds.end(), [](const auto &a, const auto &b) {
        return a.hidden.location < b.hidden.location ||
               (a.hidden.location == b.hidden.location && a.hidden.length < b.hidden.length);
    });
    auto same = [](const EditorFold &a, const EditorFold &b) {
        return a.header == b.header && NSEqualRanges(a.hidden, b.hidden);
    };
    NSUInteger first = 0;
    NSUInteger oldEnd = _folds.size(), newEnd = folds.size();
    while (first < oldEnd && first < newEnd && same(_folds[first], folds[first]))
        ++first;
    if (first == oldEnd && first == newEnd)
        return;
    while (oldEnd > first && newEnd > first && same(_folds[oldEnd - 1], folds[newEnd - 1])) {
        --oldEnd;
        --newEnd;
    }
    NSUInteger start = self.textStorage.length;
    NSUInteger end = 0;
    for (NSUInteger i = first; i < oldEnd; ++i) {
        start = std::min(start, _folds[i].header);
        end = std::max(end, NSMaxRange(_folds[i].hidden));
    }
    for (NSUInteger i = first; i < newEnd; ++i) {
        start = std::min(start, folds[i].header);
        end = std::max(end, NSMaxRange(folds[i].hidden));
    }
    _folds = std::move(folds);
    [self updateHiddenRanges];
    end = std::min(end, self.textStorage.length);
    if (end > start) {
        NSRange range = [self.textStorage.string paragraphRangeForRange:NSMakeRange(start, end - start)];
        [self invalidateGlyphsForCharacterRange:range changeInLength:0 actualCharacterRange:nullptr];
        [self invalidateLayoutForCharacterRange:range actualCharacterRange:nullptr];
    }
}

- (NSUInteger)layoutManager:(NSLayoutManager *)layout shouldGenerateGlyphs:(const CGGlyph *)glyphs
                 properties:(const NSGlyphProperty *)properties characterIndexes:(const NSUInteger *)indexes
                       font:(NSFont *)font forGlyphRange:(NSRange)range
{
    std::vector<NSGlyphProperty> flags;
    if (_hidden.empty())
        return 0;
    for (NSUInteger i = 0; i < range.length; ++i) {
        auto fold = std::upper_bound(_hidden.begin(), _hidden.end(), indexes[i],
                                     [](NSUInteger at, NSRange hidden) { return at < hidden.location; });
        if (fold != _hidden.begin() && NSLocationInRange(indexes[i], *(fold - 1))) {
            if (flags.empty())
                flags.assign(properties, properties + range.length);
            flags[i] = NSGlyphPropertyNull;
        }
    }
    if (flags.empty())
        return 0;
    [layout setGlyphs:glyphs properties:flags.data() characterIndexes:indexes font:font forGlyphRange:range];
    return range.length;
}

- (void)processEditingForTextStorage:(NSTextStorage *)storage edited:(NSTextStorageEditActions)actions
                               range:(NSRange)range changeInLength:(NSInteger)delta
                    invalidatedRange:(NSRange)invalidated
{
    if ((actions & NSTextStorageEditedCharacters) && !_folds.empty()) {
        NSUInteger oldEnd = NSUInteger(NSInteger(NSMaxRange(range)) - delta);
        std::erase_if(_folds, [&](EditorFold &fold) {
            if (range.location >= NSMaxRange(fold.hidden))
                return false;
            if (oldEnd <= fold.header && range.location < fold.header) {
                fold.header = NSUInteger(NSInteger(fold.header) + delta);
                fold.hidden.location = NSUInteger(NSInteger(fold.hidden.location) + delta);
                return false;
            }
            NSUInteger end = NSMaxRange(range);
            if (oldEnd < NSMaxRange(fold.hidden))
                end = NSUInteger(NSInteger(NSMaxRange(fold.hidden)) + delta);
            NSUInteger start = std::min(fold.header, range.location);
            invalidated = NSUnionRange(invalidated, NSMakeRange(start, end - start));
            return true;
        });
        [self updateHiddenRanges];
    }
    if ((actions & NSTextStorageEditedCharacters) && storage.length) {
        // A split or join can change which paragraph owns the glyphs at either edge of the edit.
        NSUInteger start = invalidated.location - (invalidated.location != 0);
        NSUInteger end = std::min(NSMaxRange(invalidated) + 1, storage.length);
        invalidated = [storage.string paragraphRangeForRange:NSMakeRange(start, end - start)];
    }
    [super processEditingForTextStorage:storage edited:actions range:range changeInLength:delta
                       invalidatedRange:invalidated];
}

- (void)beginSurface:(CGContextRef)context scale:(int)scale
            settings:(RenderSettings)settings darkPaper:(BOOL)darkPaper
{
    _scale = scale;
    _settings = settings;
    _darkPaper = darkPaper;
    _styleSlot = GlyphStyleSlot(settings, darkPaper);
    _surface = {context, static_cast<uint8_t *>(CGBitmapContextGetData(context)),
                CGBitmapContextGetBytesPerRow(context), int(CGBitmapContextGetWidth(context)),
                int(CGBitmapContextGetHeight(context))};
}

- (void)endSurface
{
    _surface = {};
}

- (void)drawGlyphsForGlyphRange:(NSRange)range atPoint:(NSPoint)origin color:(NSColor *)color
{
    _glyphColor = color;
    [super drawGlyphsForGlyphRange:range atPoint:origin];
    _glyphColor = nil;
}

- (void)setSelectionColor:(NSColor *)color characterRanges:(std::span<const NSRange>)ranges
{
    _selectionColor = color;
    if (color) {
        _selectionRanges.assign(ranges.begin(), ranges.end());
        MergeRanges(_selectionRanges);
    } else {
        _selectionRanges.clear();
    }
}

- (void)setDefinitionLinkRange:(NSRange)range
{
    if (NSEqualRanges(_definitionLink, range))
        return;
    if (_definitionLink.length)
        [self invalidateDisplayForCharacterRange:_definitionLink];
    _definitionLink = range;
    if (range.length)
        [self invalidateDisplayForCharacterRange:range];
}

- (void)drawSelectionGlyphs:(NSRange)range atPoint:(NSPoint)origin
{
    if (_selectionRanges.empty()) {
        [super drawGlyphsForGlyphRange:range atPoint:origin];
        return;
    }

    // Draw each run once and lay out only the part of the selection AppKit is painting.
    NSRange characters = [self characterRangeForGlyphRange:range actualGlyphRange:nullptr];
    auto selection = std::lower_bound(_selectionRanges.begin(), _selectionRanges.end(), characters.location,
        [](NSRange selected, NSUInteger at) { return NSMaxRange(selected) <= at; });
    NSUInteger drawn = range.location;
    NSUInteger end = NSMaxRange(range);
    for (; selection != _selectionRanges.end() && selection->location < NSMaxRange(characters); ++selection) {
        NSRange selected = NSIntersectionRange(characters, *selection);
        NSRange glyphs = [self glyphRangeForCharacterRange:selected actualCharacterRange:nullptr];
        NSUInteger first = std::max(drawn, glyphs.location);
        NSUInteger last = std::min(end, NSMaxRange(glyphs));
        if (last <= first)
            continue;
        if (drawn < first)
            [super drawGlyphsForGlyphRange:NSMakeRange(drawn, first - drawn) atPoint:origin];
        [self drawGlyphsForGlyphRange:NSMakeRange(first, last - first) atPoint:origin color:_selectionColor];
        drawn = last;
    }
    if (drawn < end)
        [super drawGlyphsForGlyphRange:NSMakeRange(drawn, end - drawn) atPoint:origin];
}

- (void)drawDefinitionUnderline:(NSRange)range atPoint:(NSPoint)origin color:(NSColor *)color
{
    NSTextContainer *container = [self textContainerForGlyphAtIndex:range.location effectiveRange:nullptr];
    NSRect glyphRect = [self boundingRectForGlyphRange:range inTextContainer:container];
    NSRect lineRect = [self lineFragmentRectForGlyphAtIndex:range.location effectiveRange:nullptr];
    NSPoint glyph = [self locationForGlyphAtIndex:range.location];
    NSFont *font = [self.textStorage attribute:NSFontAttributeName atIndex:[self characterIndexForGlyphAtIndex:range.location]
                                 effectiveRange:nullptr];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGFloat pixel = 1.0 / std::max<CGFloat>(1.0, std::abs(CGContextGetCTM(context).d));
    CGFloat baseline = origin.y + NSMinY(lineRect) + glyph.y;
    CGFloat y = std::round((baseline - font.underlinePosition) / pixel) * pixel;
    [color setFill];
    NSRectFill(NSMakeRect(origin.x + NSMinX(glyphRect), y, NSWidth(glyphRect), pixel));
}

- (void)drawGlyphsForGlyphRange:(NSRange)range atPoint:(NSPoint)origin
{
    if (!_definitionLink.length && _selectionRanges.empty()) {
        [super drawGlyphsForGlyphRange:range atPoint:origin];
        return;
    }
    if (_definitionLink.length) {
        NSRange chars = [self characterRangeForGlyphRange:range actualGlyphRange:nullptr];
        NSRange link = NSIntersectionRange(chars, _definitionLink);
        if (link.length) {
            NSRange glyphs = NSIntersectionRange(range, [self glyphRangeForCharacterRange:link actualCharacterRange:nullptr]);
            NSUInteger end = NSMaxRange(range);
            if (glyphs.length) {
                if (range.location < glyphs.location)
                    [self drawSelectionGlyphs:NSMakeRange(range.location, glyphs.location - range.location) atPoint:origin];
                NSColor *color = NSColor.linkColor;
                [self drawGlyphsForGlyphRange:glyphs atPoint:origin color:color];
                [self drawDefinitionUnderline:glyphs atPoint:origin color:color];
                if (NSMaxRange(glyphs) < end)
                    [self drawSelectionGlyphs:NSMakeRange(NSMaxRange(glyphs), end - NSMaxRange(glyphs)) atPoint:origin];
                return;
            }
        }
    }
    [self drawSelectionGlyphs:range atPoint:origin];
}

- (BOOL)drawGlyphMasks:(const CGGlyph *)glyphs positions:(const CGPoint *)positions count:(NSInteger)count
                  font:(NSFont *)font color:(NSColor *)color inContext:(CGContextRef)context
{
    CGAffineTransform transform = CGContextGetCTM(context);
    if (context != _surface.context ||
        transform.a != _scale || transform.d != -_scale || transform.b != 0 || transform.c != 0)
        return NO;

    uint32_t fontSlot;
    const auto &entry = CachedMaskFont(font, fontSlot);
    if (entry.hasColorGlyphs)
        return NO;
    CTFontRef coreFont = (__bridge CTFontRef)entry.font;

    color = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color)
        color = SRGBColor(rgb(0, 0, 0));
    int opacity = int(std::lround(color.alphaComponent * 255));
    if (!opacity)
        return YES;
    std::array<int, 3> ink = {int(std::lround(color.redComponent * 255)),
                             int(std::lround(color.greenComponent * 255)),
                             int(std::lround(color.blueComponent * 255))};
    // Use the same bitmap transform for clipping and glyph placement. AppKit's
    // device-space conversion can include a separate offset during overscroll.
    CGRect clip = CGRectIntegral(CGRectApplyAffineTransform(CGContextGetClipBoundingBox(context), transform));
    if (CGRectIsEmpty(clip))
        return YES;

    GlyphCache &masks = SharedGlyphMasks();
    uint64_t style = uint64_t(_styleSlot) << 32;
    for (NSInteger i = 0; i < count; ++i) {
        if (!glyphs[i])
            continue;
        CGPoint point = CGPointApplyAffineTransform(positions[i], transform);
        int phaseX, phaseY;
        int x = PixelAndPhase(point.x, phaseX);
        int y = PixelAndPhase(point.y, phaseY);
        uint32_t glyphKey = (((fontSlot * 65536 + glyphs[i]) * phases + phaseX) * phases + phaseY) *
                            4 + (_scale - 1);
        uint64_t key = style | glyphKey;
        const GlyphMask *mask = masks.find(key);
        GlyphMask uncached;
        if (!mask) {
            uncached = MakeMask(coreFont, glyphs[i], phaseX, phaseY, _scale, _settings, _darkPaper);
            mask = masks.insert(key, uncached);
        }
        if (mask->width < 0) {
            [color setFill];
            DrawCoreText(coreFont, glyphs + i, positions + i, 1, CGAffineTransformMakeScale(1, -1), context);
        } else if (opacity == 255) {
            BlendMask<false>(_surface, *mask, x, y, clip, ink, opacity);
        } else {
            BlendMask<true>(_surface, *mask, x, y, clip, ink, opacity);
        }
    }
    return YES;
}

- (void)showCGGlyphs:(const CGGlyph *)glyphs positions:(const CGPoint *)positions
              count:(NSInteger)count font:(NSFont *)font textMatrix:(CGAffineTransform)textMatrix
         attributes:(NSDictionary<NSAttributedStringKey, id> *)attributes inContext:(CGContextRef)context
{
    if (context == _surface.context && textMatrix.a == 1 && textMatrix.d == -1 && textMatrix.b == 0 && textMatrix.c == 0) {
        NSColor *color = _glyphColor ? _glyphColor : attributes[NSForegroundColorAttributeName];
        if ([self drawGlyphMasks:glyphs positions:positions count:count font:font color:color inContext:context])
            return;
    }

    if (_glyphColor) {
        CGContextSaveGState(context);
        CGContextSetFillColorWithColor(context, _glyphColor.CGColor);
    }
    DrawCoreText((__bridge CTFontRef)font, glyphs, positions, count, textMatrix, context);
    if (_glyphColor)
        CGContextRestoreGState(context);
}

- (void)drawShapedLine:(CTLineRef)line atPoint:(NSPoint)point color:(NSColor *)color
{
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    auto drawNative = [&](CTRunRef run, CFIndex start) {
        CGAffineTransform matrix = CGContextGetTextMatrix(context);
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, point.x, point.y);
        CGContextScaleCTM(context, 1, -1);
        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        CGContextSetTextPosition(context, 0, 0);
        CGContextSetFillColorWithColor(context, color.CGColor);
        if (run)
            CTRunDraw(run, context, CFRangeMake(start, 0));
        else
            CTLineDraw(line, context);
        CGContextRestoreGState(context);
        CGContextSetTextMatrix(context, matrix);
    };

    if (context != _surface.context) {
        drawNative(nullptr, 0);
        return;
    }

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CGGlyph glyphs[128];
    CGPoint positions[128];
    for (CFIndex index = 0, runCount = CFArrayGetCount(runs); index < runCount; ++index) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, index);
        NSFont *font = (__bridge NSFont *)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex count = CTRunGetGlyphCount(run);
        CFIndex drawn = 0;
        if (font && !(CTRunGetStatus(run) & kCTRunStatusHasNonIdentityMatrix)) {
            while (drawn < count) {
                CFIndex length = std::min(count - drawn, CFIndex(std::size(glyphs)));
                CFRange range = CFRangeMake(drawn, length);
                CTRunGetGlyphs(run, range, glyphs);
                CTRunGetPositions(run, range, positions);
                // Core Text's run positions are relative to the baseline, with y pointing up.
                for (CFIndex i = 0; i < length; ++i)
                    positions[i] = NSMakePoint(point.x + positions[i].x, point.y - positions[i].y);
                if (![self drawGlyphMasks:glyphs positions:positions count:length font:font color:color inContext:context])
                    break;
                drawn += length;
            }
        }

        if (drawn < count)
            drawNative(run, drawn);
    }
}

@end

template<class Pixel>
static Pixel ClampByte(Pixel value)
{
    return __builtin_elementwise_min(__builtin_elementwise_max(value, (Pixel)0), (Pixel)255);
}

static uint8_t BrightnessLevel(int channel, int brightness)
{
    return uint8_t(ClampByte((channel * brightness + 128) >> 8));
}

template<bool adjustBrightness, class Pixel>
static Pixel FilterPixels(Pixel color, int saturation, int brightness)
{
    Pixel red = color & 255;
    Pixel green = (color >> 8) & 255;
    Pixel blue = (color >> 16) & 255;
    Pixel gray = (54 * red + 183 * green + 19 * blue + 128) >> 8;
    auto filter = [&](Pixel channel) {
        channel = ClampByte((channel * saturation + gray * (256 - saturation) + 128) >> 8);
        if constexpr (adjustBrightness)
            channel = ClampByte((channel * brightness + 128) >> 8);
        return channel;
    };
    return (color & (Pixel)0xff000000U) | filter(red) | (filter(green) << 8) | (filter(blue) << 16);
}

NSColor *RenderedEditorColor(Col32 color, const RenderSettings &settings)
{
    int saturation = int(std::lround(settings.saturation * 256));
    int brightness = int(std::lround(settings.brightness * 256));
    return SRGBColor(Col32(FilterPixels<true>(int32_t(color), saturation, brightness)));
}

template<bool adjustBrightness>
static void SaturatePixels(uint8_t *data, size_t width, size_t height, size_t stride, int saturation, int brightness)
{
    using Pixels = int32_t __attribute__((ext_vector_type(4)));
    for (size_t row = 0; row < height; ++row) {
        uint8_t *pixel = data + row * stride;
        size_t column = 0;
        for (; column + 4 <= width; column += 4, pixel += sizeof(Pixels)) {
            Pixels color;
            std::memcpy(&color, pixel, sizeof(color));
            Pixels filtered = FilterPixels<adjustBrightness>(color, saturation, brightness);
            std::memcpy(pixel, &filtered, sizeof(filtered));
        }
        for (; column < width; ++column, pixel += 4) {
            int32_t color;
            std::memcpy(&color, pixel, sizeof(color));
            int32_t filtered = FilterPixels<adjustBrightness>(color, saturation, brightness);
            std::memcpy(pixel, &filtered, sizeof(filtered));
        }
    }
}

static void ApplyColorFilters(CGContextRef bitmap, const RenderSettings &settings)
{
    int saturation = int(std::lround(settings.saturation * 256));
    int brightness = int(std::lround(settings.brightness * 256));
    if (saturation == 256 && brightness == 256)
        return;

    auto *data = static_cast<uint8_t *>(CGBitmapContextGetData(bitmap));
    size_t stride = CGBitmapContextGetBytesPerRow(bitmap);
    size_t width = CGBitmapContextGetWidth(bitmap);
    size_t height = CGBitmapContextGetHeight(bitmap);
    if (saturation == 256) {
        for (size_t row = 0; row < height; ++row) {
            uint8_t *pixel = data + row * stride;
            for (size_t byte = 0; byte < width * 4; ++byte)
                pixel[byte] = BrightnessLevel(pixel[byte], brightness);
        }
    } else if (brightness == 256) {
        SaturatePixels<false>(data, width, height, stride, saturation, brightness);
    } else {
        SaturatePixels<true>(data, width, height, stride, saturation, brightness);
    }
}

static std::optional<Col32> SolidSurfaceColor(CGContextRef bitmap, size_t width, size_t height, size_t stride)
{
    auto *pixels = static_cast<const uint8_t *>(CGBitmapContextGetData(bitmap));
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = pixels + y * stride;
        if (std::memcmp(row, pixels, 4) || std::memcmp(row, row + 4, (width - 1) * 4))
            return {};
    }
    return rgb(pixels[0], pixels[1], pixels[2]);
}

static void DrawSurfaceBand(CGContextRef target, CGColorSpaceRef space, NSRect band, NSRect raster,
                            size_t width, size_t stride, int scale, RenderSettings settings,
                            CodeLayoutManager *layout, BOOL darkPaper, void (^draw)(NSRect))
{
    bool customGlyphs = settings.smoothing != Smoothing::System;
    size_t height = size_t(std::lround(NSHeight(raster) * scale));
    CGBitmapInfo format = CGBitmapInfo(kCGImageAlphaNoneSkipLast) | kCGBitmapByteOrder32Big;
    CGContextRef bitmap = CGBitmapContextCreate(nullptr, width, height, 8, stride, space, format);
    if (!bitmap) {
        draw(band);
        return;
    }

    CGContextTranslateCTM(bitmap, -NSMinX(raster) * scale, NSMaxY(raster) * scale);
    CGContextScaleCTM(bitmap, scale, -scale);

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:YES];
    if (customGlyphs)
        [layout beginSurface:bitmap scale:scale settings:settings darkPaper:darkPaper];
    draw(raster);
    if (customGlyphs)
        [layout endSurface];
    [NSGraphicsContext restoreGraphicsState];

    ApplyColorFilters(bitmap, settings);
    if (auto color = SolidSurfaceColor(bitmap, width, height, stride)) {
        // Empty bands can go straight to AppKit without a viewport-sized image.
        CGContextRelease(bitmap);
        CGFloat components[] = {ColorRed(*color) / 255.0, ColorGreen(*color) / 255.0,
                                ColorBlue(*color) / 255.0, 1.0};
        CGContextSaveGState(target);
        CGContextSetBlendMode(target, kCGBlendModeCopy);
        CGContextSetFillColorSpace(target, space);
        CGContextSetFillColor(target, components);
        CGContextFillRect(target, band);
        CGContextRestoreGState(target);
        return;
    }
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (!image) {
        draw(band);
        return;
    }

    CGContextSaveGState(target);
    CGContextSetBlendMode(target, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(target, kCGInterpolationNone);
    if (!NSEqualRects(band, raster))
        CGContextClipToRect(target, band);
    CGContextTranslateCTM(target, NSMinX(raster), NSMaxY(raster));
    CGContextScaleCTM(target, 1, -1);
    CGContextDrawImage(target, CGRectMake(0, 0, NSWidth(raster), NSHeight(raster)), image);
    CGContextRestoreGState(target);
    CGImageRelease(image);
}

void DrawEditorSurface(NSView *view, NSRect dirty, RenderSettings settings, NSColor *paper, CodeLayoutManager *layout,
                       void (^draw)(NSRect))
{
    bool customGlyphs = settings.smoothing != Smoothing::System;
    if ((!customGlyphs && settings.saturation == 1 && settings.brightness == 1) || NSIsEmptyRect(dirty)) {
        draw(dirty);
        return;
    }

    CGContextRef target = NSGraphicsContext.currentContext.CGContext;
    NSWindow *window = view.window;
    BOOL onScreen = window.screen != nil;
    CGFloat backing = onScreen ? window.backingScaleFactor : std::abs(CGContextGetCTM(target).a);
    int scale = int(std::lround(backing));
    if (scale < 1 || scale > 4 || std::abs(backing - scale) > 0.001) {
        draw(dirty);
        return;
    }

    NSRect aligned;
    if (onScreen) {
        // AppKit's backing grid includes the clip view's scroll offset.
        aligned = [view backingAlignedRect:dirty options:NSAlignAllEdgesOutward];
    } else {
        NSRect pixels = NSIntegralRect(NSMakeRect(NSMinX(dirty) * scale, NSMinY(dirty) * scale,
                                                  NSWidth(dirty) * scale, NSHeight(dirty) * scale));
        aligned = NSMakeRect(NSMinX(pixels) / scale, NSMinY(pixels) / scale,
                             NSWidth(pixels) / scale, NSHeight(pixels) / scale);
    }
    size_t width = size_t(std::lround(NSWidth(aligned) * scale));
    size_t height = size_t(std::lround(NSHeight(aligned) * scale));
    if (!width || !height || width > 8192 || height > 8192 || width * height > 16 * 1024 * 1024) {
        draw(dirty);
        return;
    }

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSColor *rgb = [paper colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    BOOL darkPaper = rgb && (rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 +
                             rgb.blueComponent * 0.0722) < 0.45;
    size_t stride = (width * 4 + 63) & ~size_t(63);
    // Limit the scratch bitmap, even when a Retina viewport is repainted in full.
    size_t maximumRows = (4 * 1024 * 1024) / stride;
    size_t overlap = 0;
    if (height > maximumRows && layout) {
        NSFont *font = layout.textContainers.firstObject.textView.font;
        CGFloat lineHeight = font ? [layout defaultLineHeightForFont:font] : 16;
        overlap = std::min(maximumRows / 4, size_t(std::ceil((lineHeight + 4) * scale)));
    }
    size_t bandRows = maximumRows - 2 * overlap;
    for (size_t row = 0; row < height; row += bandRows) {
        size_t rows = std::min(bandRows, height - row);
        NSRect band = NSMakeRect(NSMinX(aligned), NSMinY(aligned) + CGFloat(row) / scale,
                                 NSWidth(aligned), CGFloat(rows) / scale);
        // Let TextKit draw both sides of a seam, then copy only this band's interior.
        NSRect raster = NSIntersectionRect(NSInsetRect(band, 0, -CGFloat(overlap) / scale), aligned);
        // Release AppKit's temporary graphics objects before allocating another band.
        @autoreleasepool {
            DrawSurfaceBand(target, space, band, raster, width, stride, scale, settings, layout, darkPaper, draw);
        }
    }
    CGColorSpaceRelease(space);
}

static bool IsHorizontalSpace(unichar character)
{
    return character == ' ' || character == '\t';
}

static bool ContainsCharacter(const std::vector<NSRange> &ranges, NSUInteger index)
{
    auto range = std::lower_bound(ranges.begin(), ranges.end(), index, [](NSRange range, NSUInteger at) {
        return NSMaxRange(range) <= at;
    });
    return range != ranges.end() && NSLocationInRange(index, *range);
}

static NSColor *SelectedWhitespaceColor(NSColor *background)
{
    NSColor *rgb = [background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat brightness = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent;
    if (brightness > 0.54)
        return SRGBColor(rgba(0, 0, 0, 0.32f));
    return SRGBColor(rgba(255, 255, 255, 0.38f));
}

void DrawEditorWhitespace(NSTextView *view, NSRect dirty, NSFont *font, WhitespaceMode mode, Col32 color,
                          Col32 selectionBackground, std::vector<NSRange> &selections,
                          std::vector<NSRange> &inactiveSelections)
{
    if (mode == WhitespaceMode::None ||
        (mode == WhitespaceMode::Selection && selections.empty() && inactiveSelections.empty()))
        return;

    NSLayoutManager *layout = view.layoutManager;
    CodeLayoutManager *codeLayout = [layout isKindOfClass:CodeLayoutManager.class] ? (CodeLayoutManager *)layout : nil;
    NSTextContainer *container = view.textContainer;
    NSPoint origin = view.textContainerOrigin;
    NSRect area = NSOffsetRect(dirty, -origin.x, -origin.y);
    NSRange glyphs = [layout glyphRangeForBoundingRect:area inTextContainer:container];
    if (!glyphs.length)
        return;

    MergeRanges(selections);
    MergeRanges(inactiveSelections);
    if (mode == WhitespaceMode::Selection) {
        NSRange visible = [layout characterRangeForGlyphRange:glyphs actualGlyphRange:nullptr];
        NSRange selected{};
        for (const auto *ranges : {&selections, &inactiveSelections}) {
            if (!ranges->empty()) {
                NSUInteger start = ranges->front().location;
                NSRange bounds = NSMakeRange(start, NSMaxRange(ranges->back()) - start);
                selected = selected.length ? NSUnionRange(selected, bounds) : bounds;
            }
        }
        selected = NSIntersectionRange(visible, selected);
        if (!selected.length)
            return;
        NSRange selectedGlyphs = [layout glyphRangeForCharacterRange:selected actualCharacterRange:nullptr];
        glyphs = NSIntersectionRange(glyphs, selectedGlyphs);
        if (!glyphs.length)
            return;
    }

    NSString *text = view.string;
    static NSCharacterSet *const nonWhitespace = [[NSCharacterSet characterSetWithCharactersInString:@" \t"] invertedSet];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextClipToRect(context, dirty);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    enum MarkColor { Ordinary, Selected, Inactive, MarkColorCount };
    std::array<NSColor *, MarkColorCount> inks = {
        SRGBColor(color),
        selections.empty() ? nil : SelectedWhitespaceColor(SRGBColor(selectionBackground)),
        inactiveSelections.empty() ? nil : SelectedWhitespaceColor(NSColor.unemphasizedSelectedTextBackgroundColor),
    };
    // Solid theme ink is the default. Selected marks blend into the selection.
    CGContextSetFillColorWithColor(context, inks[Ordinary].CGColor);
    __block MarkColor fill = Ordinary;
    __block std::array<CGMutablePathRef, MarkColorCount> tabs = {};
    CGFloat size = font.pointSize;
    CGFloat centerAboveBaseline = font.xHeight * 0.46;
    [layout enumerateLineFragmentsForGlyphRange:glyphs
        usingBlock:^(NSRect line, NSRect used, NSTextContainer *, NSRange fragment, BOOL *) {
        if (!NSIntersectsRect(used, area))
            return;
        NSRange visible = NSIntersectionRange(fragment, glyphs);
        CFStringInlineBuffer characters;
        CFStringInitInlineBuffer((__bridge CFStringRef)text, &characters, CFRangeMake(0, text.length));
        NSUInteger lineStart = 0, lineEnd = 0, trailingStart = 0;
        NSUInteger indexes[128];
        NSGlyphProperty properties[128];
        unsigned char levels[128];
        bool dots = false;
        for (NSUInteger first = visible.location; first < NSMaxRange(visible);) {
            NSRange batch = NSMakeRange(first, std::min<NSUInteger>(std::size(indexes), NSMaxRange(visible) - first));
            first = NSMaxRange(batch);
            if (visible.length > std::size(indexes) &&
                !NSIntersectsRect([layout boundingRectForGlyphRange:batch inTextContainer:container], area))
                continue;
            bool wholeLine = NSEqualRanges(batch, fragment);
            NSUInteger count = [layout getGlyphsInRange:batch glyphs:nullptr properties:properties
                                       characterIndexes:indexes bidiLevels:wholeLine ? levels : nullptr];
            bool leftToRight = wholeLine &&
                std::all_of(levels, levels + count, [](unsigned char level) { return level == 0; });
            for (NSUInteger i = 0; i < count; ++i) {
                if (properties[i] & NSGlyphPropertyNull)
                    continue;
                NSUInteger at = indexes[i];
                unichar character = CFStringGetCharacterFromInlineBuffer(&characters, at);
                if (!IsHorizontalSpace(character))
                    continue;

                if ((mode == WhitespaceMode::Boundary || mode == WhitespaceMode::Trailing) &&
                    (at < lineStart || at >= lineEnd)) {
                    [text getLineStart:&lineStart end:nullptr contentsEnd:&lineEnd forRange:NSMakeRange(at, 0)];
                    if (mode == WhitespaceMode::Trailing) {
                        NSRange nonSpace = [text rangeOfCharacterFromSet:nonWhitespace options:NSBackwardsSearch
                                                                 range:NSMakeRange(lineStart, lineEnd - lineStart)];
                        trailingStart = nonSpace.location == NSNotFound ? lineStart : NSMaxRange(nonSpace);
                    }
                }
                if (mode == WhitespaceMode::Trailing && at < trailingStart)
                    continue;
                if (mode == WhitespaceMode::Boundary && character == ' ' && at > lineStart && at + 1 < lineEnd &&
                    !IsHorizontalSpace(CFStringGetCharacterFromInlineBuffer(&characters, at - 1)) &&
                    !IsHorizontalSpace(CFStringGetCharacterFromInlineBuffer(&characters, at + 1)))
                    continue;
                MarkColor mark = Ordinary;
                if (ContainsCharacter(inactiveSelections, at))
                    mark = Inactive;
                else if (ContainsCharacter(selections, at))
                    mark = Selected;
                if (mode == WhitespaceMode::Selection && mark == Ordinary)
                    continue;

                NSUInteger glyph = batch.location + i;
                NSPoint position = [layout locationForGlyphAtIndex:glyph];
                CGFloat cellStart = NSMinX(line) + position.x;
                CGFloat advance = 0;
                // Adjacent left-to-right glyph positions already describe the cell.
                if (leftToRight) {
                    if (glyph + 1 == NSMaxRange(fragment))
                        advance = NSMaxX(used) - cellStart;
                    else if (i + 1 < count && !(properties[i + 1] & NSGlyphPropertyNull))
                        advance = [layout locationForGlyphAtIndex:glyph + 1].x - position.x;
                }
                NSRect cell = advance > 0 ? NSMakeRect(cellStart, NSMinY(line), advance, NSHeight(line)) :
                    [layout boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:container];
                cell.size.width = std::max(0.0, NSWidth(cell) - [codeLayout inlayWidthAfterCharacter:at]);
                if (!NSIntersectsRect(cell, area))
                    continue;
                CGFloat y = origin.y + NSMinY(line) + position.y - centerAboveBaseline;
                if (character == ' ') {
                    if (fill != mark) {
                        if (dots)
                            CGContextFillPath(context);
                        CGContextSetFillColorWithColor(context, inks[mark].CGColor);
                        fill = mark;
                        dots = false;
                    }
                    if (!dots) {
                        CGContextBeginPath(context);
                        dots = true;
                    }
                    CGFloat radius = std::min(NSWidth(cell) * 0.24, std::max(CGFloat(0.72), size * 0.083));
                    CGContextAddEllipseInRect(context, CGRectMake(origin.x + NSMidX(cell) - radius, y - radius,
                                                                 2 * radius, 2 * radius));
                } else {
                    CGFloat length = std::min(size * 0.52, NSWidth(cell) * 0.78);
                    CGFloat left = origin.x + NSMinX(cell) + std::min(size * 0.12, (NSWidth(cell) - length) / 2);
                    CGFloat right = left + length;
                    CGFloat tip = length * 0.32;
                    auto &path = tabs[mark];
                    if (!path)
                        path = CGPathCreateMutable();
                    CGPathMoveToPoint(path, nullptr, left, y);
                    CGPathAddLineToPoint(path, nullptr, right, y);
                    CGPathMoveToPoint(path, nullptr, right - tip, y - tip);
                    CGPathAddLineToPoint(path, nullptr, right, y);
                    CGPathAddLineToPoint(path, nullptr, right - tip, y + tip);
                }
            }
        }
        if (dots)
            CGContextFillPath(context);
    }];
    for (size_t mark = 0; mark < tabs.size(); ++mark) {
        CGMutablePathRef path = tabs[mark];
        if (!path)
            continue;
        CGContextSetStrokeColorWithColor(context, inks[mark].CGColor);
        CGContextBeginPath(context);
        CGContextAddPath(context, path);
        CGContextSetLineWidth(context, std::max(CGFloat(0.68), size * 0.083));
        CGContextSetLineCap(context, kCGLineCapRound);
        CGContextSetLineJoin(context, kCGLineJoinRound);
        CGContextStrokePath(context);
        CGPathRelease(path);
    }
    CGContextRestoreGState(context);
}