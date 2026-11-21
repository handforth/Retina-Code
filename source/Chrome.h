#pragma once

#import <AppKit/AppKit.h>
#include <optional>

enum class DockSide { Bottom, Left, Right, Top };

struct DockFrames {
    NSRect editor, rail, tab, output, divider;
};

bool DockIsSide(DockSide side);
DockFrames LayoutDock(NSRect body, DockSide side, BOOL open, CGFloat extent);
std::optional<DockSide> DockSideAtPoint(NSRect body, NSPoint point);

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

@interface DockDropTarget : NSView
@end

@class SourceDocument;

inline constexpr CGFloat projectTabBarHeight = 27;

@interface ProjectTabBar : NSView
@property(nonatomic, copy) void (^selectDocument)(SourceDocument *);
@property(nonatomic, copy) void (^closeDocument)(SourceDocument *);
@property(nonatomic, copy) void (^moveDocument)(SourceDocument *, NSUInteger);
- (void)showDocuments:(NSArray<SourceDocument *> *)documents selected:(SourceDocument *)selected;
@end

inline constexpr NSUInteger defaultCommandPaletteRows = 8;
enum class CommandPaletteMode { Commands, Choices };
using CommandPreview = void (^)(NSMenuItem *);

@interface CommandPalette : NSView
- (void)presentInView:(NSView *)host items:(NSArray<NSMenuItem *> *)items placeholder:(NSString *)placeholder
                 mode:(CommandPaletteMode)mode rowLimit:(NSUInteger)rowLimit preview:(CommandPreview)preview;
- (void)dismiss;
@end