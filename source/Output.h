#pragma once

#import "Rendering.h"
#import "Runner.h"

@class SourceDocument;

@interface OutputPane : NSView
- (instancetype)initWithFrame:(NSRect)frame diagnostics:(BOOL)diagnostics;
@property(nonatomic, copy) void (^openLocation)(const RunLocation &, SourceDocument *);
@property(nonatomic, copy) BOOL (^sendInput)(NSString *);
@property(nonatomic, readonly) BOOL hasKeyboardFocus;
- (void)setInputEnabled:(BOOL)enabled;
- (BOOL)focusInput;
- (void)applyFont:(NSFont *)font rendering:(RenderSettings)settings dark:(BOOL)dark;
- (void)prepareForRun;
- (void)clear;
- (void)appendMessages:(const std::vector<RunMessage> &)messages source:(SourceDocument *)source;
- (void)showDiagnostics:(const std::vector<RunMessage> &)messages source:(SourceDocument *)source;
@end