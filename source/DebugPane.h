#pragma once

#import "Debugger.h"
#import "Output.h"

NSMenuItem *MakeDebugMenuItem(DebugCommand command);
NSString *DebugCommandToolTip(DebugCommand command, NSString *title);

@interface DebugPane : NSView
@property(nonatomic) DebugSession *session;
@property(nonatomic, copy) void (^command)(DebugCommand);
@property(nonatomic, copy) void (^openLocation)(NSString *, NSUInteger);
@property(nonatomic, copy) void (^editBreakpoint)(NSString *, NSUInteger);
@property(nonatomic, readonly) BOOL hasKeyboardFocus;
@property(nonatomic, readonly) OutputPane *console;
- (void)prepare;
- (void)updateStatus:(NSString *)status building:(BOOL)building restartable:(BOOL)restartable;
- (void)breakpointsChanged;
- (void)showConsole;
@end