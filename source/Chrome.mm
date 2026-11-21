#import "Chrome.h"
#import "Editor.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

bool DockIsSide(DockSide side) { return side == DockSide::Left || side == DockSide::Right; }

static NSString *const recentCommandsKey = @"RecentPaletteCommands";
static constexpr NSUInteger recentCommandLimit = 20;

static NSString *CommandIdentifier(NSMenuItem *item)
{
    // A menu title can change with context, such as Show Sidebar and Hide Sidebar.
    return [NSString stringWithFormat:@"%@/%ld", NSStringFromSelector(item.action), long(item.tag)];
}

static void RememberCommand(NSString *identifier)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *saved = [defaults arrayForKey:recentCommandsKey];
    if ([saved.firstObject isEqual:identifier])
        return;

    NSMutableArray *recent = saved ? [saved mutableCopy] : [NSMutableArray array];
    [recent removeObject:identifier];
    [recent insertObject:identifier atIndex:0];
    if (recent.count > recentCommandLimit)
        [recent removeObjectsInRange:NSMakeRange(recentCommandLimit, recent.count - recentCommandLimit)];
    [defaults setObject:recent forKey:recentCommandsKey];
}

static NSInteger CommandMatchScore(NSString *title, NSString *query)
{
    if (!query.length)
        return 0;
    NSRange match = [title rangeOfString:query options:NSLiteralSearch];
    if (match.location != NSNotFound) {
        bool startsWord = match.location == 0 || [title characterAtIndex:match.location - 1] == ' ';
        return (startsWord ? 0 : 64) + NSInteger(std::min<NSUInteger>(match.location, 63));
    }

    NSUInteger at = 0;
    NSInteger score = 128;
    for (NSUInteger q = 0; q < query.length; ++q) {
        unichar key = [query characterAtIndex:q];
        if (key == ' ' || key == '\t')
            continue;
        NSUInteger start = at;
        while (at < title.length && [title characterAtIndex:at] != key)
            ++at;
        if (at == title.length)
            return -1;
        score += NSInteger(at - start);
        if (at != start && [title characterAtIndex:at - 1] != ' ')
            score += 4;
        ++at;
    }
    return score;
}

enum class CommandPointerState { Idle, Hover, Pressed };

@interface CommandRow : NSTableRowView
@property(nonatomic) CommandPointerState pointerState;
@end

@implementation CommandRow

- (void)setPointerState:(CommandPointerState)state
{
    if (_pointerState != state) {
        _pointerState = state;
        self.needsDisplay = YES;
    }
}

- (void)drawBackgroundInRect:(NSRect)dirty
{
    [super drawBackgroundInRect:dirty];
    if (_pointerState == CommandPointerState::Idle || self.selected)
        return;
    CGFloat alpha = _pointerState == CommandPointerState::Pressed ? 0.34 : 0.15;
    [[NSColor.controlAccentColor colorWithAlphaComponent:alpha] setFill];
    NSRectFillUsingOperation(dirty, NSCompositingOperationSourceOver);
}

- (void)drawSelectionInRect:(NSRect)dirty
{
    [NSColor.selectedContentBackgroundColor setFill];
    NSRectFill(dirty);
    if (_pointerState != CommandPointerState::Idle) {
        bool pressed = _pointerState == CommandPointerState::Pressed;
        NSColor *shade = pressed ? NSColor.blackColor : NSColor.whiteColor;
        [[shade colorWithAlphaComponent:pressed ? 0.24 : 0.12] setFill];
        NSRectFillUsingOperation(dirty, NSCompositingOperationSourceOver);
    }
}

- (NSBackgroundStyle)interiorBackgroundStyle
{
    return self.selected ? NSBackgroundStyleEmphasized : NSBackgroundStyleNormal;
}

@end

@interface CommandTable : NSTableView
- (CommandPointerState)pointerStateAtRow:(NSInteger)row;
- (void)clearPointerState;
- (void)viewportMoved:(NSNotification *)notification;
@end

@implementation CommandTable {
    NSInteger _hoveredRow;
    NSInteger _pressedRow;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _hoveredRow = _pressedRow = -1;
        NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
            NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point
{
    return [super hitTest:point] ? self : nil;
}

- (NSInteger)rowAtWindowPoint:(NSPoint)point
{
    point = [self convertPoint:point fromView:nil];
    return NSPointInRect(point, self.visibleRect) ? [self rowAtPoint:point] : -1;
}

- (CommandPointerState)pointerStateAtRow:(NSInteger)row
{
    if (row < 0 || row != _hoveredRow)
        return CommandPointerState::Idle;
    return row == _pressedRow ? CommandPointerState::Pressed : CommandPointerState::Hover;
}

- (void)updateHoveredRow:(NSInteger)row pressedRow:(NSInteger)pressed
{
    if (row == _hoveredRow && pressed == _pressedRow)
        return;
    if (_hoveredRow >= 0 && _hoveredRow != row) {
        CommandRow *old = (CommandRow *)[self rowViewAtRow:_hoveredRow makeIfNecessary:NO];
        old.pointerState = CommandPointerState::Idle;
    }
    _hoveredRow = row;
    _pressedRow = pressed;
    if (row >= 0) {
        CommandRow *view = (CommandRow *)[self rowViewAtRow:row makeIfNecessary:NO];
        view.pointerState = [self pointerStateAtRow:row];
    }
}

- (void)clearPointerState
{
    [self updateHoveredRow:-1 pressedRow:-1];
}

- (void)viewportMoved:(NSNotification *)notification
{
    (void)notification;
    if (_hoveredRow >= 0 || _pressedRow >= 0)
        [self updateHoveredRow:[self rowAtWindowPoint:self.window.mouseLocationOutsideOfEventStream]
                    pressedRow:_pressedRow];
}

- (void)mouseMoved:(NSEvent *)event
{
    [self updateHoveredRow:[self rowAtWindowPoint:event.locationInWindow] pressedRow:_pressedRow];
}

- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }

- (void)mouseExited:(NSEvent *)event
{
    (void)event;
    [self updateHoveredRow:-1 pressedRow:_pressedRow];
}

- (void)mouseDown:(NSEvent *)event
{
    NSInteger row = [self rowAtWindowPoint:event.locationInWindow];
    [self updateHoveredRow:row pressedRow:row];
}

- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }

- (void)mouseUp:(NSEvent *)event
{
    NSInteger row = [self rowAtWindowPoint:event.locationInWindow];
    bool choose = row >= 0 && row == _pressedRow;
    [self updateHoveredRow:row pressedRow:-1];
    if (choose) {
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self sendAction:self.action to:self.target];
    }
}

@end

@interface CommandPalette () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@end

@implementation CommandPalette {
    NSTextField *_query;
    NSTextField *_empty;
    NSScrollView *_scroll;
    CommandTable *_results;
    NSLayoutConstraint *_height;
    NSArray<NSMenuItem *> *_items;
    NSArray<NSString *> *_searchTitles;
    std::vector<NSUInteger> _recentRanks;
    std::vector<NSInteger> _rows;
    __weak NSWindow *_hostWindow;
    __weak NSResponder *_previousFocus;
    id _mouseMonitor;
    CommandPreview _preview;
    CommandPaletteMode _mode;
    NSUInteger _rowLimit;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.clipsToBounds = YES;
    NSLayoutConstraint *width = [self.widthAnchor constraintEqualToConstant:545];
    width.priority = NSLayoutPriorityDefaultHigh;
    _height = [self.heightAnchor constraintEqualToConstant:70];
    _height.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[width, _height]];

    _query = [NSTextField textFieldWithString:@""];
    _query.font = [NSFont systemFontOfSize:14];
    _query.delegate = self;
    _query.accessibilityLabel = @"Command search";
    [self addSubview:_query];

    _scroll = [[NSScrollView alloc] init];
    _scroll.borderType = NSNoBorder;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleLegacy;
    _results = [[CommandTable alloc] initWithFrame:NSZeroRect];
    _results.headerView = nil;
    _results.rowHeight = 22;
    _results.intercellSpacing = NSZeroSize;
    _results.allowsEmptySelection = NO;
    _results.refusesFirstResponder = YES;
    _results.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _results.style = NSTableViewStylePlain;
    _results.accessibilityLabel = @"Commands";
    [_results addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"command"]];
    _results.dataSource = self;
    _results.delegate = self;
    _results.target = self;
    _results.action = @selector(chooseCommand:);
    _scroll.documentView = _results;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:_results selector:@selector(viewportMoved:)
        name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [self addSubview:_scroll];

    _empty = [NSTextField labelWithString:@"No matching commands"];
    _empty.textColor = NSColor.secondaryLabelColor;
    [self addSubview:_empty];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirty
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSFrameRectWithWidthUsingOperation(self.bounds, 1, NSCompositingOperationSourceOver);
}

- (void)layout
{
    [super layout];
    CGFloat width = std::max<CGFloat>(0, NSWidth(self.bounds) - 16);
    _query.frame = NSMakeRect(8, 8, width, 27);
    _scroll.frame = NSMakeRect(8, 40, width, std::max<CGFloat>(0, NSHeight(self.bounds) - 48));
    _empty.frame = NSMakeRect(13, 42, std::max<CGFloat>(0, width - 10), 20);
}

- (void)presentInView:(NSView *)host items:(NSArray<NSMenuItem *> *)items placeholder:(NSString *)placeholder
                 mode:(CommandPaletteMode)mode rowLimit:(NSUInteger)rowLimit preview:(CommandPreview)preview
{
    if (!host.window)
        return;
    [self dismiss];
    _hostWindow = host.window;
    _previousFocus = host.window.firstResponder;
    _mode = mode;
    _rowLimit = rowLimit;
    _preview = [preview copy];
    _items = [items copy];
    if (mode == CommandPaletteMode::Commands) {
        NSArray *recent = [NSUserDefaults.standardUserDefaults arrayForKey:recentCommandsKey];
        if (recent.count) {
            _recentRanks.reserve(_items.count);
            for (NSMenuItem *item in _items)
                _recentRanks.push_back([recent indexOfObject:CommandIdentifier(item)]);
        }
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:items.count];
    for (NSMenuItem *item in _items) {
        NSString *title = item.title.lowercaseString;
        if ([item.representedObject isKindOfClass:NSString.class]) {
            NSString *aliases = item.representedObject;
            title = [NSString stringWithFormat:@"%@ %@", title, aliases.lowercaseString];
        }
        [titles addObject:title];
    }
    _searchTitles = titles;
    _query.placeholderString = placeholder;
    _query.stringValue = @"";

    [host addSubview:self positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [self.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [self.topAnchor constraintEqualToAnchor:host.topAnchor constant:7],
        [self.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-16],
        [self.heightAnchor constraintLessThanOrEqualToAnchor:host.heightAnchor constant:-14]
    ]];
    [self filterCommands];
    [host layoutSubtreeIfNeeded];
    [host.window makeFirstResponder:_query];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowLostFocus:)
                                               name:NSWindowDidResignKeyNotification object:host.window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowLostFocus:)
                                               name:NSWindowWillCloseNotification object:host.window];

    __weak CommandPalette *palette = self;
    _mouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
        NSEventMaskOtherMouseDown handler:^NSEvent *(NSEvent *event) {
            CommandPalette *view = palette;
            if (view && (event.window != view.window ||
                !NSPointInRect([view convertPoint:event.locationInWindow fromView:nil], view.bounds)))
                [view dismiss];
            return event;
        }];
}

- (void)dismiss
{
    NSWindow *window = _hostWindow;
    if (!_items)
        return;
    NSResponder *previous = _previousFocus;
    BOOL restoreFocus = self.window == window && (window.firstResponder == _query.currentEditor ||
                                                 window.firstResponder == _query);
    CommandPreview preview = _preview;
    _preview = nil;
    _hostWindow = nil;
    _previousFocus = nil;
    _items = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:window];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:window];
    if (_mouseMonitor) {
        [NSEvent removeMonitor:_mouseMonitor];
        _mouseMonitor = nil;
    }
    if (restoreFocus)
        [window makeFirstResponder:previous];
    [_results clearPointerState];
    [self removeFromSuperview];
    _searchTitles = nil;
    _recentRanks.clear();
    _rows.clear();
    [_results reloadData];
    if (preview)
        preview(nil);
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (!self.window)
        [self dismiss];
}

- (void)windowLostFocus:(NSNotification *)notification
{
    (void)notification;
    [self dismiss];
}

- (void)selectResultRow:(NSInteger)row
{
    [_results selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_results scrollRowToVisible:row];
    if (_preview)
        _preview(_items[_rows[row]]);
}

- (void)filterCommands
{
    NSString *text = _query.stringValue.lowercaseString;
    if ([text hasPrefix:@">"])
        text = [text substringFromIndex:1];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    struct Match { NSInteger row; NSInteger score; NSUInteger recentRank; };
    std::vector<Match> matches;
    matches.reserve(_items.count);
    for (NSUInteger i = 0; i < _items.count; ++i) {
        if (!_items[i].enabled)
            continue;
        NSInteger score = CommandMatchScore(_searchTitles[i], text);
        if (score >= 0) {
            NSUInteger recentRank = _recentRanks.empty() ? NSNotFound : _recentRanks[i];
            matches.push_back({NSInteger(i), score, recentRank});
        }
    }
    std::stable_sort(matches.begin(), matches.end(), [](Match a, Match b) {
        return a.score == b.score ? a.recentRank < b.recentRank : a.score < b.score;
    });
    [_results clearPointerState];
    _rows.clear();
    for (auto match : matches)
        _rows.push_back(match.row);
    [_results reloadData];
    _empty.hidden = !_rows.empty();
    _scroll.hidden = _rows.empty();
    _height.constant = 48 + _results.rowHeight * std::clamp<size_t>(_rows.size(), 1, _rowLimit);
    if (!_rows.empty()) {
        NSUInteger row = 0;
        if (_mode == CommandPaletteMode::Choices && !text.length) {
            auto current = std::find_if(_rows.begin(), _rows.end(), [&](NSInteger index) {
                return _items[index].state == NSControlStateValueOn;
            });
            if (current != _rows.end())
                row = NSUInteger(current - _rows.begin());
        }
        [self selectResultRow:NSInteger(row)];
    } else if (_preview)
        _preview(nil);
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    (void)notification;
    [self filterCommands];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)action
{
    (void)control;
    (void)textView;
    if (action == @selector(cancelOperation:)) {
        [self dismiss];
        return YES;
    }
    if (action == @selector(insertNewline:)) {
        [self chooseCommand:nil];
        return YES;
    }
    if (action != @selector(moveUp:) && action != @selector(moveDown:) &&
        action != @selector(pageUp:) && action != @selector(pageDown:))
        return NO;
    if (!_rows.empty()) {
        NSInteger count = NSInteger(_rows.size());
        NSInteger row = std::max<NSInteger>(0, _results.selectedRow);
        if (action == @selector(pageUp:) || action == @selector(pageDown:)) {
            NSInteger pageSize = NSInteger(_rowLimit);
            row = std::clamp(row + (action == @selector(pageUp:) ? -pageSize : pageSize), NSInteger(0), count - 1);
        } else {
            row = (row + count + (action == @selector(moveUp:) ? -1 : 1)) % count;
        }
        [self selectResultRow:row];
    }
    return YES;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
    (void)table;
    return NSInteger(_rows.size());
}

- (NSTableRowView *)tableView:(NSTableView *)table rowViewForRow:(NSInteger)row
{
    CommandRow *view = [table makeViewWithIdentifier:@"commandRow" owner:self];
    if (!view) {
        view = [[CommandRow alloc] init];
        view.identifier = @"commandRow";
    }
    view.pointerState = [_results pointerStateAtRow:row];
    return view;
}

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)column;
    NSTableCellView *cell = [table makeViewWithIdentifier:@"command" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"command";
        NSTextField *label = [NSTextField labelWithString:@""];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:label];
        cell.textField = label;

        NSImage *image = [NSImage imageNamed:NSImageNameMenuOnStateTemplate];
        NSImageView *checkmark = [NSImageView imageViewWithImage:image];
        checkmark.imageScaling = NSImageScaleProportionallyDown;
        checkmark.accessibilityLabel = @"Checked";
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:checkmark];
        cell.imageView = checkmark;

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:9],
            [label.trailingAnchor constraintEqualToAnchor:checkmark.leadingAnchor constant:-8],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [checkmark.widthAnchor constraintEqualToConstant:11],
            [checkmark.heightAnchor constraintEqualToAnchor:checkmark.widthAnchor],
            [checkmark.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-9],
            [checkmark.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    NSMenuItem *item = _items[_rows[row]];
    cell.textField.stringValue = item.title;
    cell.imageView.hidden = item.state != NSControlStateValueOn;
    return cell;
}

- (IBAction)chooseCommand:(id)sender
{
    (void)sender;
    NSInteger row = _results.selectedRow;
    if (row < 0 || row >= NSInteger(_rows.size()))
        return;
    NSMenuItem *command = _items[_rows[row]];
    id target = command.target;
    NSString *identifier = _mode == CommandPaletteMode::Commands ? CommandIdentifier(command) : nil;
    // Apply the command before clearing the preview so the saved theme does not flash.
    CommandPreview preview = _preview;
    _preview = nil;
    [self dismiss];
    if (target && [NSApp sendAction:command.action to:target from:command] && identifier)
        RememberCommand(identifier);
    if (preview)
        preview(nil);
}

@end

DockFrames LayoutDock(NSRect body, DockSide side, BOOL open, CGFloat extent)
{
    constexpr CGFloat railWidth = 24;
    constexpr CGFloat grip = 5;
    bool vertical = DockIsSide(side);
    CGFloat rail = std::min(railWidth, vertical ? NSWidth(body) : NSHeight(body));
    CGFloat span = vertical ? NSWidth(body) : NSHeight(body);
    CGFloat minimumEditor = vertical ? 200 : 104;
    CGFloat maximum = std::max<CGFloat>(0, span - rail - grip - minimumEditor);
    CGFloat size = open ? std::clamp(std::round(extent), std::min<CGFloat>(74, maximum), maximum) : 0;
    CGFloat x = NSMinX(body), y = NSMinY(body), w = NSWidth(body), h = NSHeight(body);
    CGFloat tabInset = std::min<CGFloat>(6, vertical ? h : w);
    CGFloat tabLength = std::min<CGFloat>(74, (vertical ? h : w) - tabInset);
    DockFrames frames{};
    frames.editor = body;
    if (side == DockSide::Bottom) {
        frames.rail = NSMakeRect(x, y, w, rail);
        frames.tab = NSMakeRect(x + tabInset, y, tabLength, rail);
        frames.output = NSMakeRect(x, y + rail, w, size);
        frames.divider = NSMakeRect(x, NSMaxY(frames.output), w, grip);
        frames.editor.origin.y += rail + size + (size ? grip : 0);
        frames.editor.size.height = std::max<CGFloat>(0, NSMaxY(body) - NSMinY(frames.editor));
    } else if (side == DockSide::Top) {
        frames.rail = NSMakeRect(x, y + h - rail, w, rail);
        frames.tab = NSMakeRect(x + tabInset, NSMinY(frames.rail), tabLength, rail);
        frames.output = NSMakeRect(x, NSMinY(frames.rail) - size, w, size);
        frames.divider = NSMakeRect(x, NSMinY(frames.output) - grip, w, grip);
        frames.editor.size.height = std::max<CGFloat>(0, h - rail - size - (size ? grip : 0));
    } else if (side == DockSide::Left) {
        frames.rail = NSMakeRect(x, y, rail, h);
        frames.tab = NSMakeRect(x, y + h - tabInset - tabLength, rail, tabLength);
        frames.output = NSMakeRect(x + rail, y, size, h);
        frames.divider = NSMakeRect(NSMaxX(frames.output), y, grip, h);
        frames.editor.origin.x += rail + size + (size ? grip : 0);
        frames.editor.size.width = std::max<CGFloat>(0, NSMaxX(body) - NSMinX(frames.editor));
    } else {
        frames.rail = NSMakeRect(x + w - rail, y, rail, h);
        frames.tab = NSMakeRect(NSMinX(frames.rail), y + h - tabInset - tabLength, rail, tabLength);
        frames.output = NSMakeRect(NSMinX(frames.rail) - size, y, size, h);
        frames.divider = NSMakeRect(NSMinX(frames.output) - grip, y, grip, h);
        frames.editor.size.width = std::max<CGFloat>(0, w - rail - size - (size ? grip : 0));
    }
    if (!size)
        frames.divider = NSZeroRect;
    return frames;
}

std::optional<DockSide> DockSideAtPoint(NSRect body, NSPoint point)
{
    if (!NSPointInRect(point, NSInsetRect(body, -18, -18)))
        return {};
    std::array<CGFloat, 4> distances = {
        std::abs(point.y - NSMinY(body)), std::abs(point.x - NSMinX(body)),
        std::abs(NSMaxX(body) - point.x), std::abs(NSMaxY(body) - point.y)
    };
    auto nearest = std::min_element(distances.begin(), distances.end());
    CGFloat reach = std::clamp(std::min(NSWidth(body), NSHeight(body)) / 4, 52.0, 130.0);
    return *nearest <= reach ? std::optional(DockSide(nearest - distances.begin())) : std::nullopt;
}

@implementation DockRail

- (void)drawRect:(NSRect)dirty
{
    NSRectEdge face;
    switch (self.side) {
        // The status bar paints the shared background at the bottom.
        case DockSide::Bottom: return;
        case DockSide::Top: face = NSMinYEdge; break;
        case DockSide::Left: face = NSMaxXEdge; break;
        case DockSide::Right: face = NSMinXEdge; break;
    }
    NSRect bounds = self.bounds;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSIntersectionRect(dirty, bounds));
    NSRect rule, rest;
    NSDivideRect(bounds, &rule, &rest, 1, face);
    [NSColor.separatorColor setFill];
    NSRectFill(NSIntersectionRect(dirty, rule));
}

@end

@implementation DockTab {
    NSPoint _start;
    BOOL _dragging;
}

- (void)mouseDown:(NSEvent *)event
{
    _start = event.locationInWindow;
    _dragging = NO;
    [self highlight:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
    NSPoint point = event.locationInWindow;
    if (!_dragging && std::hypot(point.x - _start.x, point.y - _start.y) < 5)
        return;
    _dragging = YES;
    if (self.track)
        self.track(point, NO);
}

- (void)mouseUp:(NSEvent *)event
{
    [self highlight:NO];
    if (_dragging) {
        if (self.track)
            self.track(event.locationInWindow, YES);
    } else if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) {
        [self sendAction:self.action to:self.target];
    }
    _dragging = NO;
}

@end

@implementation DockDivider {
    CGFloat _previous;
}

- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:self.vertical ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = self.bounds;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSIntersectionRect(dirty, bounds));
    NSRect line = self.vertical ? NSMakeRect(NSMidX(bounds) - 0.5, 0, 1, NSHeight(bounds)) :
                                  NSMakeRect(0, NSMidY(bounds) - 0.5, NSWidth(bounds), 1);
    [NSColor.separatorColor setFill];
    NSRectFill(NSIntersectionRect(dirty, line));
}

- (void)mouseDown:(NSEvent *)event
{
    _previous = self.vertical ? event.locationInWindow.x : event.locationInWindow.y;
}

- (void)trackResize:(NSEvent *)event finished:(BOOL)finished
{
    CGFloat point = self.vertical ? event.locationInWindow.x : event.locationInWindow.y;
    if (self.resize)
        self.resize(point - _previous, finished);
    _previous = point;
}

- (void)mouseDragged:(NSEvent *)event { [self trackResize:event finished:NO]; }
- (void)mouseUp:(NSEvent *)event { [self trackResize:event finished:YES]; }

@end

@implementation DockDropTarget

- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }

- (void)drawRect:(NSRect)dirty
{
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
    NSRectFillUsingOperation(NSIntersectionRect(dirty, self.bounds), NSCompositingOperationSourceOver);
    [NSColor.controlAccentColor setStroke];
    [[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 1, 1)] stroke];
}

@end

@class ProjectTab;

@interface ProjectTabBar ()
- (void)dragTab:(ProjectTab *)tab toPoint:(NSPoint)point;
@end

@interface ProjectTab : NSView
@property(nonatomic, weak) SourceDocument *document;
@property(nonatomic, weak) ProjectTabBar *bar;
@property(nonatomic) BOOL selected;
@property(nonatomic, readonly) CGFloat tabWidth;
- (instancetype)initWithDocument:(SourceDocument *)document bar:(ProjectTabBar *)bar;
- (void)update;
@end

@implementation ProjectTab {
    DockTab *_label;
    NSButton *_close;
    CGFloat _tabWidth;
}

- (instancetype)initWithDocument:(SourceDocument *)document bar:(ProjectTabBar *)bar
{
    self = [super initWithFrame:NSZeroRect];
    if (!self)
        return nil;
    _document = document;
    _bar = bar;
    _label = [[DockTab alloc] initWithFrame:NSZeroRect];
    _label.bordered = NO;
    _label.alignment = NSTextAlignmentLeft;
    _label.font = [NSFont systemFontOfSize:12];
    _label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _label.target = self;
    _label.action = @selector(select:);
    __weak ProjectTab *tab = self;
    _label.track = ^(NSPoint point, BOOL finished) {
        if (finished)
            [tab finishDrag:point];
    };
    [self addSubview:_label];

    _close = [[NSButton alloc] initWithFrame:NSZeroRect];
    _close.bordered = NO;
    _close.imagePosition = NSImageOnly;
    NSImage *close = [NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close Tab"];
    _close.image = [close imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightMedium]];
    _close.contentTintColor = NSColor.secondaryLabelColor;
    _close.target = self;
    _close.action = @selector(close:);
    _close.toolTip = @"Close Tab";
    [self addSubview:_close];
    return self;
}

- (void)update
{
    NSString *name = self.document.displayName;
    if (!name.length)
        name = @"Untitled";
    BOOL dirty = self.document.isDocumentEdited;
    NSString *title = dirty ? [@"•  " stringByAppendingString:name] : name;
    if (![_label.title isEqualToString:title])
        _label.title = title;
    NSString *path = self.document.fileURL.path;
    _label.toolTip = path.length ? path : name;
    _label.accessibilityLabel = name;
    _label.accessibilityValue = dirty ? @"Modified" : nil;
    _close.accessibilityLabel = [@"Close " stringByAppendingString:name];
    _tabWidth = std::clamp(std::ceil([name sizeWithAttributes:@{NSFontAttributeName:_label.font}].width) + 55, 102.0, 220.0);
}

- (void)setSelected:(BOOL)selected
{
    if (_selected == selected)
        return;
    _selected = selected;
    _label.accessibilitySelected = selected;
    self.needsDisplay = YES;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    _label.frame = NSMakeRect(8, 1, std::max<CGFloat>(0, width - 32), height - 2);
    _close.frame = NSMakeRect(width - 24, 1, 22, height - 2);
}

- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = self.bounds;
    if (_selected) {
        [NSColor.controlBackgroundColor setFill];
        NSRectFill(NSIntersectionRect(dirty, bounds));
    }
    [NSColor.separatorColor setFill];
    NSRect edge = NSMakeRect(NSMaxX(bounds) - 1, NSMinY(bounds), 1, NSHeight(bounds));
    NSRectFillUsingOperation(NSIntersectionRect(dirty, edge), NSCompositingOperationSourceOver);
}

- (IBAction)select:(id)sender
{
    (void)sender;
    auto action = self.bar.selectDocument;
    if (action && self.document)
        action(self.document);
}

- (IBAction)close:(id)sender
{
    (void)sender;
    auto action = self.bar.closeDocument;
    if (action && self.document)
        action(self.document);
}

- (void)finishDrag:(NSPoint)point
{
    [self.bar dragTab:self toPoint:point];
}

@end

@implementation ProjectTabBar {
    NSScrollView *_scroll;
    NSView *_contents;
    NSButton *_newTab;
    NSArray<ProjectTab *> *_tabs;
    __weak SourceDocument *_selected;
    BOOL _revealSelected;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.clipsToBounds = YES;
    self.accessibilityLabel = @"Editor Tabs";
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.borderType = NSNoBorder;
    _scroll.drawsBackground = NO;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _contents = [[NSView alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _contents;
    [self addSubview:_scroll];

    _newTab = [[NSButton alloc] initWithFrame:NSZeroRect];
    _newTab.bordered = NO;
    _newTab.imagePosition = NSImageOnly;
    NSImage *plus = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Tab"];
    _newTab.image = [plus imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]];
    _newTab.toolTip = @"New Tab";
    _newTab.target = self;
    _newTab.action = @selector(newTab:);
    [self addSubview:_newTab];
    return self;
}

- (void)showDocuments:(NSArray<SourceDocument *> *)documents selected:(SourceDocument *)selected
{
    NSMapTable<SourceDocument *, ProjectTab *> *existing = [NSMapTable strongToStrongObjectsMapTable];
    for (ProjectTab *tab in _tabs) {
        if (tab.document)
            [existing setObject:tab forKey:tab.document];
        else
            [tab removeFromSuperview];
    }
    NSMutableArray<ProjectTab *> *tabs = [NSMutableArray arrayWithCapacity:documents.count];
    for (SourceDocument *document in documents) {
        ProjectTab *tab = [existing objectForKey:document];
        if (tab) {
            [existing removeObjectForKey:document];
        } else {
            tab = [[ProjectTab alloc] initWithDocument:document bar:self];
            [_contents addSubview:tab];
        }
        tab.selected = document == selected;
        [tab update];
        [tabs addObject:tab];
    }
    for (ProjectTab *tab in existing.objectEnumerator)
        [tab removeFromSuperview];
    _revealSelected |= _selected != selected || _tabs.count != tabs.count;
    _tabs = tabs;
    _selected = selected;
    self.needsLayout = YES;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat tabsWidth = std::max<CGFloat>(0, width - 28);
    _scroll.frame = NSMakeRect(0, 0, tabsWidth, height);
    _newTab.frame = NSMakeRect(tabsWidth + 1, 1, std::min<CGFloat>(26, width), std::max<CGFloat>(0, height - 2));
    CGFloat x = 0;
    ProjectTab *selected = nil;
    for (ProjectTab *tab in _tabs) {
        tab.frame = NSMakeRect(x, 0, tab.tabWidth, height);
        x += tab.tabWidth;
        if (tab.selected)
            selected = tab;
    }
    _contents.frame = NSMakeRect(0, 0, std::max(x, tabsWidth), height);
    if (_revealSelected && selected)
        [selected scrollRectToVisible:selected.bounds];
    _revealSelected = NO;
}

- (void)drawRect:(NSRect)dirty
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSRect rule = NSMakeRect(0, 0, NSWidth(self.bounds), 1);
    NSRectFillUsingOperation(NSIntersectionRect(dirty, rule), NSCompositingOperationSourceOver);
}

- (void)dragTab:(ProjectTab *)tab toPoint:(NSPoint)point
{
    if (!self.moveDocument || !tab.document || !NSPointInRect([self convertPoint:point fromView:nil], self.bounds))
        return;
    CGFloat x = [_contents convertPoint:point fromView:nil].x;
    NSUInteger from = [_tabs indexOfObjectIdenticalTo:tab];
    NSUInteger to = 0;
    while (to < _tabs.count && x >= NSMidX(_tabs[to].frame))
        ++to;
    if (to > from)
        --to;
    if (from != NSNotFound && from != to)
        self.moveDocument(tab.document, to);
}

- (IBAction)newTab:(id)sender
{
    (void)sender;
    [NSApp sendAction:@selector(newWindowForTab:) to:NSApp.delegate from:self.window];
}

@end