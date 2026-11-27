#pragma once

#import "Runner.h"

enum class DebugPhase { Launching, Running, Paused, Stopping, Finished };
enum class DebugCommand : NSInteger {
    Continue, Pause, StepOver, StepInto, StepOut, Restart, Stop,
    ToggleBreakpoint, EditBreakpoint, RunToCursor, ChooseExecutable, Attach, Arguments, ShowPane
};

extern NSString *const DebugBreakpointsChanged;
NSString *DebugSourcePath(NSURL *file);
NSDictionary<NSNumber *, NSDictionary *> *DebugBreakpoints(NSString *path);
NSDictionary<NSString *, NSDictionary<NSNumber *, NSDictionary *> *> *DebugAllBreakpoints();
void SetDebugBreakpoint(NSString *path, NSUInteger line, NSDictionary *options);
void MoveDebugBreakpoints(NSString *oldPath, NSString *newPath);
void ShiftDebugBreakpoints(NSString *path, NSUInteger firstLine, NSUInteger oldLines, NSUInteger newLines);

using DebugReply = void (^)(NSDictionary *body, NSString *error);

@interface DebugSession : NSObject
- (instancetype)initWithExecutable:(DebugExecutable *)executable arguments:(NSArray<NSString *> *)arguments
                          language:(Language)language pid:(pid_t)pid;
@property(nonatomic, copy) dispatch_block_t changed;
@property(nonatomic, copy) void (^output)(NSString *, OutputTone);
@property(nonatomic, readonly) DebugPhase phase;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSString *exception;
@property(nonatomic, readonly) NSArray<NSDictionary *> *threads;
@property(nonatomic, readonly) NSArray<NSDictionary *> *frames;
@property(nonatomic, readonly) NSNumber *threadID;
@property(nonatomic, readonly) NSDictionary *frame;
@property(nonatomic, readonly) NSUInteger revision;
@property(nonatomic, readonly) BOOL attached;
@property(nonatomic, readonly) BOOL acceptsInput;
- (void)start;
- (void)stop;
- (void)performCommand:(DebugCommand)command;
- (void)request:(NSString *)command arguments:(NSDictionary *)arguments reply:(DebugReply)reply;
- (void)evaluateWatch:(NSString *)expression reply:(DebugReply)reply;
- (void)selectThread:(NSNumber *)thread;
- (void)selectFrame:(NSDictionary *)frame;
- (void)sendBreakpoints:(NSString *)path;
- (BOOL)breakpointResolved:(NSString *)path line:(NSUInteger)line;
- (void)runToLine:(NSUInteger)line path:(NSString *)path;
- (BOOL)sendInput:(NSString *)text;
@end

bool StopDebugSessionsForQuit(dispatch_block_t finished);