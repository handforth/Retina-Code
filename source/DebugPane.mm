#import "DebugPane.h"
#include <algorithm>

struct DebugControl {
    DebugCommand command;
    NSString *name;
    NSString *icon;
    unichar key;
    NSEventModifierFlags modifiers;
};

static const DebugControl controls[] = {
    {DebugCommand::Continue, @"Start / Continue", @"play.fill", NSF9FunctionKey, 0},
    {DebugCommand::Pause, @"Pause", @"pause.fill", NSF6FunctionKey, 0},
    {DebugCommand::StepOver, @"Step Over", nil, NSF8FunctionKey, 0},
    {DebugCommand::StepInto, @"Step Into", @"arrow.down.to.line", NSF7FunctionKey, 0},
    {DebugCommand::StepOut, @"Step Out", @"arrow.up.to.line", NSF8FunctionKey, NSEventModifierFlagShift},
    {DebugCommand::Restart, @"Restart", @"arrow.clockwise", NSF9FunctionKey, NSEventModifierFlagShift},
    {DebugCommand::Stop, @"Stop", @"stop.fill", NSF5FunctionKey, NSEventModifierFlagShift},
    {DebugCommand::ToggleBreakpoint, @"Toggle Breakpoint", nil, NSF9FunctionKey, NSEventModifierFlagCommand},
    {DebugCommand::EditBreakpoint, @"Edit Breakpoint…", nil, 0, 0},
    {DebugCommand::RunToCursor, @"Run to Cursor", nil, NSF10FunctionKey, 0},
    {DebugCommand::ChooseExecutable, @"Debug Executable…", nil, 0, 0},
    {DebugCommand::Attach, @"Attach to Process…", nil, 0, 0},
    {DebugCommand::Arguments, @"Program Arguments…", nil, 0, 0},
    {DebugCommand::ShowPane, @"Show Debug Pane", nil, 0, 0},
};

static NSImage *StepOverButtonImage()
{
    static NSImage *image = [] {
        NSImage *symbol = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:YES drawingHandler:^BOOL(NSRect) {
            [NSColor.systemGrayColor setStroke];
            NSBezierPath *arrow = [NSBezierPath bezierPath];
            arrow.lineWidth = 1.35;
            arrow.lineCapStyle = NSLineCapStyleRound;
            arrow.lineJoinStyle = NSLineJoinStyleRound;

            [arrow moveToPoint:NSMakePoint(2, 7.5)];
            [arrow lineToPoint:NSMakePoint(8, 2)];
            [arrow lineToPoint:NSMakePoint(14, 7.5)];
            [arrow moveToPoint:NSMakePoint(10, 7.5)];
            [arrow lineToPoint:NSMakePoint(14, 7.5)];
            [arrow lineToPoint:NSMakePoint(14, 3.5)];
            [arrow moveToPoint:NSMakePoint(2, 13)];
            [arrow lineToPoint:NSMakePoint(14, 13)];
            [arrow stroke];
            return YES;
        }];
        symbol.accessibilityDescription = @"Step Over";
        return symbol;
    }();
    return image;
}

static const DebugControl &Control(DebugCommand command)
{
    return controls[static_cast<NSUInteger>(command)];
}

NSMenuItem *MakeDebugMenuItem(DebugCommand command)
{
    const DebugControl &control = Control(command);
    NSString *key = control.key ? [NSString stringWithCharacters:&control.key length:1] : @"";
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:control.name action:@selector(debugCommand:) keyEquivalent:key];
    item.keyEquivalentModifierMask = control.modifiers;
    item.tag = NSInteger(command);
    return item;
}

NSString *DebugCommandToolTip(DebugCommand command, NSString *title)
{
    const DebugControl &control = Control(command);
    if (!control.key)
        return title;
    NSString *shift = control.modifiers & NSEventModifierFlagShift ? @"⇧" : @"";
    NSString *cmd = control.modifiers & NSEventModifierFlagCommand ? @"⌘" : @"";
    return [NSString stringWithFormat:@"%@ (%@%@F%d)", title, shift, cmd, control.key - NSF1FunctionKey + 1];
}

enum class DebugPage : NSInteger { Watches, Variables, Stack, Breakpoints, Console };

@interface DebugRow : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) NSUInteger line;
@property(nonatomic) NSNumber *reference;
@property(nonatomic) NSArray<DebugRow *> *children;
@property(nonatomic) NSDictionary *frame;
@property(nonatomic) BOOL watch;
@property(nonatomic) BOOL breakpoint;
@property(nonatomic) BOOL disabled;
@property(nonatomic) BOOL loading;
@end

@implementation DebugRow
@end

static DebugRow *MakeDebugRow(NSString *name, NSString *value)
{
    DebugRow *row = [[DebugRow alloc] init];
    row.name = name;
    row.value = value;
    return row;
}

static void SetValue(DebugRow *row, NSDictionary *value, NSString *field)
{
    row.value = value[field];
    row.type = value[@"type"];
    row.reference = value[@"variablesReference"];
}

@interface DebugPane () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate>
@end

@implementation DebugPane {
    NSMutableArray<NSButton *> *_buttons;
    NSTextField *_status;
    NSPopUpButton *_pages;
    NSPopUpButton *_threads;
    NSTextField *_input;
    NSScrollView *_scroll;
    NSOutlineView *_outline;
    NSArray<DebugRow *> *_rows;
    NSMutableArray<NSString *> *_watches;
    DebugPage _page;
    NSUInteger _revision;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    _watches = [[NSUserDefaults.standardUserDefaults stringArrayForKey:@"debugWatches"] mutableCopy];
    if (!_watches)
        _watches = [NSMutableArray array];
    _buttons = [NSMutableArray array];
    for (const DebugControl &control : controls) {
        if (control.command > DebugCommand::Stop)
            break;
        NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
        button.bezelStyle = NSBezelStyleSmallSquare;
        button.image = control.command == DebugCommand::StepOver ? StepOverButtonImage() :
            [NSImage imageWithSystemSymbolName:control.icon accessibilityDescription:control.name];
        button.imagePosition = NSImageOnly;
        button.target = self;
        button.action = @selector(performControl:);
        button.tag = NSInteger(control.command);
        NSString *name = control.command == DebugCommand::Continue ? @"Continue" : control.name;
        button.toolTip = DebugCommandToolTip(control.command, name);
        button.accessibilityLabel = name;
        [_buttons addObject:button];
        [self addSubview:button];
    }

    _status = [NSTextField labelWithString:@"Ready"];
    _status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_status];

    _pages = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_pages addItemsWithTitles:@[@"Watches", @"Variables", @"Call Stack", @"Breakpoints", @"Console"]];
    _pages.controlSize = NSControlSizeSmall;
    _pages.target = self;
    _pages.action = @selector(selectPage:);
    _pages.accessibilityLabel = @"Debug View";
    [self addSubview:_pages];

    _threads = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _threads.controlSize = NSControlSizeSmall;
    _threads.target = self;
    _threads.action = @selector(selectThread:);
    _threads.accessibilityLabel = @"Thread";
    [self addSubview:_threads];

    _input = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _input.cell.scrollable = YES;
    _input.controlSize = NSControlSizeSmall;
    _input.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _input.usesSingleLineMode = YES;
    _input.target = self;
    _input.action = @selector(commitInput:);
    [self addSubview:_input];

    _outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    _outline.usesAlternatingRowBackgroundColors = YES;
    _outline.rowHeight = 18;
    _outline.indentationPerLevel = 13;
    _outline.delegate = self;
    _outline.dataSource = self;
    _outline.target = self;
    _outline.action = @selector(selectRow:);
    _outline.doubleAction = @selector(openRow:);
    _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    for (NSString *name in @[@"Name", @"Value", @"Type"]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:name];
        column.title = name;
        column.width = [name isEqualToString:@"Type"] ? 100 : 160;
        column.minWidth = 40;
        [_outline addTableColumn:column];
    }
    _outline.outlineTableColumn = _outline.tableColumns.firstObject;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    _outline.menu = menu;
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.documentView = _outline;
    [self addSubview:_scroll];

    _console = [[OutputPane alloc] initWithFrame:NSZeroRect diagnostics:NO];
    __weak DebugPane *weak = self;
    _console.sendInput = ^BOOL(NSString *text) { return [weak.session sendInput:text]; };
    [self addSubview:_console];
    [self updateStatus:nil building:NO restartable:NO];
    [self reloadPage];
    return self;
}

- (BOOL)hasKeyboardFocus
{
    id focus = self.window.firstResponder;
    if ([focus isKindOfClass:NSTextView.class] && [(NSTextView *)focus isFieldEditor])
        focus = [(NSTextView *)focus delegate];
    return [focus isKindOfClass:NSView.class] && [(NSView *)focus isDescendantOf:self];
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat x = 6;
    for (NSButton *button in _buttons) {
        button.frame = NSMakeRect(x, std::max(0.0, height - 25), 24, 21);
        x += 25;
    }
    _status.frame = NSMakeRect(x + 5, std::max(0.0, height - 22), std::max(0.0, width - x - 11), 16);
    CGFloat pageY = std::max(0.0, height - 50);
    _pages.frame = NSMakeRect(4, pageY, 106, 22);
    NSRect accessory = NSMakeRect(114, pageY + 1, std::max(0.0, width - 121), 20);
    _threads.frame = accessory;
    _input.frame = accessory;
    _scroll.frame = NSMakeRect(0, 0, width, pageY);
    _console.frame = _scroll.frame;
}

- (void)performControl:(NSButton *)button
{
    if (self.command)
        self.command(static_cast<DebugCommand>(button.tag));
}

- (void)prepare
{
    [_console clear];
    _input.stringValue = @"";
    [self reloadPage];
}

- (void)showConsole
{
    [_pages selectItemAtIndex:NSInteger(DebugPage::Console)];
    [self selectPage:_pages];
}

- (void)updateStatus:(NSString *)status building:(BOOL)building restartable:(BOOL)restartable
{
    DebugSession *session = self.session;
    BOOL active = session && session.phase != DebugPhase::Finished;
    BOOL running = active && session.phase == DebugPhase::Running;
    BOOL paused = active && session.phase == DebugPhase::Paused;
    BOOL stopping = active && session.phase == DebugPhase::Stopping;
    _status.stringValue = status ? status : session ? session.status : @"Ready";
    _status.toolTip = session.exception.length ? session.exception : _status.stringValue;
    _buttons[NSInteger(DebugCommand::Continue)].enabled = paused && session.threadID;
    _buttons[NSInteger(DebugCommand::Pause)].enabled = running;
    for (auto command : {DebugCommand::StepOver, DebugCommand::StepInto, DebugCommand::StepOut})
        _buttons[NSInteger(command)].enabled = paused && session.threadID;
    _buttons[NSInteger(DebugCommand::Restart)].enabled = restartable && !stopping && !session.attached;
    _buttons[NSInteger(DebugCommand::Stop)].enabled = building || (active && !stopping);
    [_console setInputEnabled:session.acceptsInput];
    if (_page == DebugPage::Console)
        _input.enabled = paused || running;
    if (session.revision != _revision) {
        _revision = session.revision;
        [self reloadPage];
    } else if (_page == DebugPage::Stack) {
        [self updateThreads];
    }
}

- (void)setSession:(DebugSession *)session
{
    if (_session == session)
        return;
    _session = session;
    _revision = session.revision;
    [self reloadPage];
}

- (void)selectPage:(NSPopUpButton *)sender
{
    _page = static_cast<DebugPage>(sender.indexOfSelectedItem);
    _input.stringValue = @"";
    [self reloadPage];
}

- (void)updateThreads
{
    [_threads removeAllItems];
    for (NSDictionary *thread in self.session.threads) {
        NSString *name = thread[@"name"];
        [_threads addItemWithTitle:name.length ? name : [thread[@"id"] stringValue]];
        _threads.lastItem.representedObject = thread[@"id"];
        if ([thread[@"id"] isEqual:self.session.threadID])
            [_threads selectItem:_threads.lastItem];
    }
    _threads.enabled = _threads.numberOfItems > 0;
}

- (void)reloadPage
{
    _scroll.hidden = _page == DebugPage::Console;
    _console.hidden = !_scroll.hidden;
    _threads.hidden = _page != DebugPage::Stack;
    _input.hidden = _page != DebugPage::Watches && _page != DebugPage::Console;
    _input.placeholderString = _page == DebugPage::Watches ? @"Add Watch" : @"LLDB command";
    _input.accessibilityLabel = _input.placeholderString;
    _input.enabled = _page == DebugPage::Watches || (self.session && (self.session.phase == DebugPhase::Paused ||
                                                                    self.session.phase == DebugPhase::Running));
    _outline.tableColumns[0].title = _page == DebugPage::Watches ? @"Expression" :
                                     _page == DebugPage::Stack ? @"Frame" : @"Name";
    _outline.tableColumns[2].hidden = _page == DebugPage::Stack || _page == DebugPage::Breakpoints;
    _outline.tableColumns[1].title = _page == DebugPage::Stack ? @"Location" :
                                     _page == DebugPage::Breakpoints ? @"Condition" : @"Value";
    _rows = nil;
    DebugSession *session = self.session;
    NSMutableArray<DebugRow *> *rows = [NSMutableArray array];
    if (_page == DebugPage::Watches) {
        for (NSString *expression in _watches) {
            DebugRow *row = MakeDebugRow(expression, nil);
            row.watch = YES;
            [rows addObject:row];
        }
    } else if (_page == DebugPage::Stack) {
        [self updateThreads];
        for (NSDictionary *frame in session.frames) {
            NSString *path = frame[@"source"][@"path"];
            NSString *file = path.lastPathComponent;
            NSUInteger line = [frame[@"line"] unsignedIntegerValue];
            NSString *value = file.length ? [NSString stringWithFormat:@"%@:%lu", file, line] : frame[@"instructionPointerReference"];
            DebugRow *row = MakeDebugRow(frame[@"name"], value);
            row.frame = frame;
            [rows addObject:row];
        }
    } else if (_page == DebugPage::Breakpoints) {
        NSDictionary *files = DebugAllBreakpoints();
        for (NSString *path in [files.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSDictionary *lines = files[path];
            for (NSNumber *line in [lines.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                DebugRow *row = MakeDebugRow([NSString stringWithFormat:@"%@:%@", path.lastPathComponent, line],
                                             lines[line][@"condition"]);
                row.path = path;
                row.line = line.unsignedIntegerValue;
                row.breakpoint = YES;
                row.disabled = [lines[line][@"disabled"] boolValue];
                [rows addObject:row];
            }
        }
    }
    _rows = rows;
    [_outline reloadData];
    if (_page == DebugPage::Stack) {
        NSUInteger index = [session.frames indexOfObjectIdenticalTo:session.frame];
        if (session.frame && index < _rows.count)
            [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    }
    if (session.phase != DebugPhase::Paused || !session.frame[@"id"])
        return;
    if (_page == DebugPage::Watches) {
        for (DebugRow *row in _rows)
            [self evaluateWatch:row];
    } else if (_page == DebugPage::Variables) {
        [self loadScopes];
    }
}

- (void)breakpointsChanged
{
    if (_page == DebugPage::Breakpoints)
        [self reloadPage];
}

- (void)evaluateWatch:(DebugRow *)row
{
    __weak DebugPane *weak = self;
    NSUInteger revision = _revision;
    [self.session evaluateWatch:row.name reply:^(NSDictionary *body, NSString *error) {
        DebugPane *pane = weak;
        if (!pane || pane->_revision != revision || ![pane->_rows containsObject:row])
            return;
        if (error)
            row.value = error;
        else
            SetValue(row, body, @"result");
        [pane->_outline reloadItem:row];
    }];
}

- (void)loadScopes
{
    __weak DebugPane *weak = self;
    NSUInteger revision = _revision;
    [self.session request:@"scopes" arguments:@{@"frameId":self.session.frame[@"id"]}
                    reply:^(NSDictionary *body, NSString *error) {
        DebugPane *pane = weak;
        if (!pane || pane->_revision != revision || pane->_page != DebugPage::Variables)
            return;
        NSMutableArray *rows = [NSMutableArray array];
        if (error)
            [rows addObject:MakeDebugRow(error, nil)];
        for (NSDictionary *scope in body[@"scopes"]) {
            DebugRow *row = MakeDebugRow(scope[@"name"], nil);
            row.reference = scope[@"variablesReference"];
            [rows addObject:row];
        }
        pane->_rows = rows;
        [pane->_outline reloadData];
        if (rows.count)
            [pane->_outline expandItem:rows.firstObject];
    }];
}

- (NSInteger)outlineView:(NSOutlineView *)view numberOfChildrenOfItem:(DebugRow *)item
{
    (void)view;
    return item ? item.children.count : _rows.count;
}

- (id)outlineView:(NSOutlineView *)view child:(NSInteger)index ofItem:(DebugRow *)item
{
    (void)view;
    return item ? item.children[index] : _rows[index];
}

- (BOOL)outlineView:(NSOutlineView *)view isItemExpandable:(DebugRow *)item
{
    (void)view;
    return item.reference.integerValue > 0;
}

- (BOOL)outlineView:(NSOutlineView *)view shouldExpandItem:(DebugRow *)item
{
    (void)view;
    if (item.children || item.loading)
        return YES;
    if (!self.session.frame || !item.reference.integerValue)
        return NO;
    item.loading = YES;
    NSUInteger revision = _revision;
    __weak DebugPane *weak = self;
    [self.session request:@"variables" arguments:@{@"variablesReference":item.reference, @"start":@0, @"count":@250}
                    reply:^(NSDictionary *body, NSString *error) {
        DebugPane *pane = weak;
        if (!pane || pane->_revision != revision || [pane->_outline rowForItem:item] < 0)
            return;
        NSMutableArray *rows = [NSMutableArray array];
        if (error)
            [rows addObject:MakeDebugRow(error, nil)];
        for (NSDictionary *variable in body[@"variables"]) {
            DebugRow *row = MakeDebugRow(variable[@"name"], nil);
            SetValue(row, variable, @"value");
            [rows addObject:row];
        }
        item.children = rows;
        item.loading = NO;
        [pane->_outline reloadItem:item reloadChildren:YES];
        [pane->_outline expandItem:item];
    }];
    return YES;
}

- (NSView *)outlineView:(NSOutlineView *)view viewForTableColumn:(NSTableColumn *)column item:(DebugRow *)item
{
    NSString *key = column.identifier;
    NSTextField *cell = [view makeViewWithIdentifier:key owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = key;
        cell.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSString *text = [key isEqualToString:@"Name"] ? item.name : [key isEqualToString:@"Type"] ? item.type : item.value;
    cell.stringValue = text ? text : @"";
    cell.textColor = item.disabled ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    cell.toolTip = [key isEqualToString:@"Name"] && item.path ? item.path : text;
    return cell;
}

- (void)selectThread:(NSPopUpButton *)sender
{
    [self.session selectThread:sender.selectedItem.representedObject];
}

- (void)selectRow:(NSOutlineView *)sender
{
    if (sender.clickedRow < 0)
        return;
    DebugRow *row = [sender itemAtRow:sender.clickedRow];
    if (row.frame && row.frame != self.session.frame)
        [self.session selectFrame:row.frame];
}

- (void)openRow:(NSOutlineView *)sender
{
    if (sender.clickedRow < 0)
        return;
    DebugRow *row = [sender itemAtRow:sender.clickedRow];
    if (row.breakpoint && self.openLocation)
        self.openLocation(row.path, row.line);
}

- (void)commitInput:(NSTextField *)sender
{
    NSString *text = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length)
        return;
    if (_page == DebugPage::Watches) {
        if (![_watches containsObject:text]) {
            [_watches addObject:text];
            [NSUserDefaults.standardUserDefaults setObject:_watches forKey:@"debugWatches"];
            [self reloadPage];
        }
    } else if (_page == DebugPage::Console && sender.enabled) {
        DebugSession *session = self.session;
        NSString *command = [text hasPrefix:@"`"] ? text : [@"`" stringByAppendingString:text];
        NSMutableDictionary *arguments = [@{@"expression":command, @"context":@"repl"} mutableCopy];
        arguments[@"frameId"] = session.frame[@"id"];
        [_console appendMessages:{{[NSString stringWithFormat:@"(lldb) %@\n", text], OutputTone::Text, {}}} source:nil];
        __weak DebugPane *weak = self;
        [session request:@"evaluate" arguments:arguments reply:^(NSDictionary *body, NSString *error) {
            NSString *result = error ? error : body[@"result"];
            if (result.length)
                [weak.console appendMessages:{{[result stringByAppendingString:@"\n"], error ? OutputTone::Error : OutputTone::Text, {}}}
                                     source:nil];
        }];
    }
    sender.stringValue = @"";
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];
    NSInteger index = _outline.clickedRow;
    if (index < 0)
        return;
    DebugRow *row = [_outline itemAtRow:index];
    if (row.value.length)
        [self addMenuItem:menu title:@"Copy Value" action:@selector(copyValue:) row:row];
    if (row.watch)
        [self addMenuItem:menu title:@"Remove Watch" action:@selector(removeWatch:) row:row];
    if (row.breakpoint) {
        [self addMenuItem:menu title:@"Edit Breakpoint…" action:@selector(changeBreakpoint:) row:row];
        [self addMenuItem:menu title:row.disabled ? @"Enable Breakpoint" : @"Disable Breakpoint"
                  action:@selector(toggleBreakpointEnabled:) row:row];
        [self addMenuItem:menu title:@"Remove Breakpoint" action:@selector(removeBreakpoint:) row:row];
    }
}

- (void)addMenuItem:(NSMenu *)menu title:(NSString *)title action:(SEL)action row:(DebugRow *)row
{
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = row;
}

- (void)copyValue:(NSMenuItem *)item
{
    DebugRow *row = item.representedObject;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:row.value forType:NSPasteboardTypeString];
}

- (void)removeWatch:(NSMenuItem *)item
{
    DebugRow *row = item.representedObject;
    [_watches removeObject:row.name];
    [NSUserDefaults.standardUserDefaults setObject:_watches forKey:@"debugWatches"];
    [self reloadPage];
}

- (void)changeBreakpoint:(NSMenuItem *)item
{
    DebugRow *row = item.representedObject;
    if (self.editBreakpoint)
        self.editBreakpoint(row.path, row.line);
}

- (void)toggleBreakpointEnabled:(NSMenuItem *)item
{
    DebugRow *row = item.representedObject;
    NSMutableDictionary *options = [DebugBreakpoints(row.path)[@(row.line)] mutableCopy];
    options[@"disabled"] = @(!row.disabled);
    SetDebugBreakpoint(row.path, row.line, options);
}

- (void)removeBreakpoint:(NSMenuItem *)item
{
    DebugRow *row = item.representedObject;
    SetDebugBreakpoint(row.path, row.line, nil);
}

@end