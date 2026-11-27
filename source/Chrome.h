#pragma once

#import <AppKit/AppKit.h>
#include "Color.h"
#include <optional>

void DrawWindowBarGradient(NSRect bounds, NSAppearance *appearance);

struct Theme;

void DrawPopupFrame(NSRect frame, NSRect dirty, Col32 paper, Col32 border);

enum class DockSide { Bottom, Left, Right, Top };
enum class DockPage { Hidden, Output, Errors, Debug };

struct DockFrames {
    NSRect editor, rail, tab, output, divider;
};

bool DockIsSide(DockSide side);
DockFrames LayoutDock(NSRect body, DockSide side, DockPage page, CGFloat extent);
std::optional<DockSide> DockSideAtPoint(NSRect body, NSPoint point);
NSRect SplitDockRect(NSRect body, DockSide side);
bool SplitDockFirst(DockSide side);
void ArrangeEditorSplit(NSSplitView *split, NSView *primary, NSView *secondary, DockSide side, CGFloat fraction);

@interface DockRail : NSView
@property(nonatomic) DockSide side;
@end

@interface DockTab : NSButton
@property(nonatomic, copy) void (^track)(NSPoint point, BOOL finished);
@end

@interface DockDivider : NSView
@property(nonatomic) BOOL vertical;
@property(nonatomic, copy) void (^resize)(CGFloat delta, BOOL finished);
@end

enum class DropPreviewStyle { Highlight, Outline, Insertion };

@interface DockDropTarget : NSView
@property(nonatomic) DropPreviewStyle style;
@end

@class SourceDocument;

inline constexpr CGFloat projectTabBarHeight = 27;

struct TabInsertion {
    NSUInteger index = NSNotFound;
    NSRect marker = NSZeroRect;
};

NSRect TabInsertionMarker(NSWindow *window, NSRect viewport, CGFloat x);

@interface ProjectTabBar : NSView
@property(nonatomic, copy) void (^selectDocument)(SourceDocument *);
@property(nonatomic, copy) void (^closeDocument)(SourceDocument *);
@property(nonatomic, copy) void (^activateGroup)(void);
- (void)showDocuments:(NSArray<SourceDocument *> *)documents selected:(SourceDocument *)selected;
- (SourceDocument *)documentAtWindowPoint:(NSPoint)point tabView:(NSView **)tabView;
- (TabInsertion)insertionAtWindowPoint:(NSPoint)point;
@end

inline constexpr NSUInteger defaultCommandPaletteRows = 8;
enum class CommandPaletteMode { Commands, Choices };
using CommandPreview = void (^)(NSMenuItem *);

@interface CommandPalette : NSView
- (void)presentInView:(NSView *)host items:(NSArray<NSMenuItem *> *)items placeholder:(NSString *)placeholder
                 mode:(CommandPaletteMode)mode rowLimit:(NSUInteger)rowLimit preview:(CommandPreview)preview;
- (void)applyTheme:(const Theme &)theme;
- (void)dismiss;
@end