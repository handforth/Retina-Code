#import "Debugger.h"
#import "Workspace.h"
#include "DebugTransport.hpp"
#import <AppKit/AppKit.h>
#include <algorithm>
#include <cerrno>
#include <limits.h>

NSString *const DebugBreakpointsChanged = @"DebugBreakpointsChanged";

NSString *DebugSourcePath(NSURL *file)
{
    return file.isFileURL ? file.URLByStandardizingPath.URLByResolvingSymlinksInPath.path : nil;
}

static NSMutableDictionary<NSString *, NSDictionary<NSNumber *, NSDictionary *> *> *breakpoints;

static void LoadBreakpoints()
{
    if (breakpoints)
        return;
    breakpoints = [NSMutableDictionary dictionary];
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"debugBreakpoints"];
    for (NSString *path in stored) {
        NSMutableDictionary *lines = [NSMutableDictionary dictionary];
        for (NSString *line in stored[path])
            lines[@(line.integerValue)] = stored[path][line];
        if (lines.count)
            breakpoints[path] = [lines copy];
    }
}

NSDictionary<NSString *, NSDictionary<NSNumber *, NSDictionary *> *> *DebugAllBreakpoints()
{
    LoadBreakpoints();
    return breakpoints;
}

NSDictionary<NSNumber *, NSDictionary *> *DebugBreakpoints(NSString *path)
{
    return path.length ? DebugAllBreakpoints()[path] : nil;
}

static void StoreBreakpoints(NSString *path)
{
    NSMutableDictionary *stored = [NSMutableDictionary dictionaryWithCapacity:breakpoints.count];
    for (NSString *file in breakpoints) {
        NSMutableDictionary *lines = [NSMutableDictionary dictionary];
        for (NSNumber *line in breakpoints[file])
            lines[line.stringValue] = breakpoints[file][line];
        stored[file] = lines;
    }
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:@"debugBreakpoints"];
    [NSNotificationCenter.defaultCenter postNotificationName:DebugBreakpointsChanged object:path];
}

void SetDebugBreakpoint(NSString *path, NSUInteger line, NSDictionary *options)
{
    if (!path.length || !line)
        return;
    NSMutableDictionary *lines = [DebugBreakpoints(path) mutableCopy];
    if (!lines)
        lines = [NSMutableDictionary dictionary];
    lines[@(line)] = options;
    breakpoints[path] = lines.count ? [lines copy] : nil;
    StoreBreakpoints(path);
}

void MoveDebugBreakpoints(NSString *oldPath, NSString *newPath)
{
    NSDictionary *old = DebugBreakpoints(oldPath);
    if (!old.count || !newPath.length || [oldPath isEqualToString:newPath])
        return;
    NSMutableDictionary *lines = [DebugBreakpoints(newPath) mutableCopy];
    if (!lines)
        lines = [NSMutableDictionary dictionary];
    [lines addEntriesFromDictionary:old];
    breakpoints[oldPath] = nil;
    breakpoints[newPath] = [lines copy];
    StoreBreakpoints(oldPath);
    [NSNotificationCenter.defaultCenter postNotificationName:DebugBreakpointsChanged object:newPath];
}

void ShiftDebugBreakpoints(NSString *path, NSUInteger firstLine, NSUInteger oldLines, NSUInteger newLines)
{
    NSDictionary *lines = DebugBreakpoints(path);
    if (!lines.count || oldLines == newLines)
        return;
    NSMutableDictionary *shifted = [NSMutableDictionary dictionaryWithCapacity:lines.count];
    for (NSNumber *line in [lines.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSUInteger number = line.unsignedIntegerValue;
        if (number >= firstLine + oldLines)
            number = number - oldLines + newLines;
        else if (number >= firstLine && number - firstLine >= newLines)
            continue;
        shifted[@(number)] = lines[line];
    }
    if ([shifted isEqualToDictionary:lines])
        return;
    breakpoints[path] = shifted.count ? [shifted copy] : nil;
    StoreBreakpoints(path);
}

static NSMutableSet<DebugSession *> *sessions;
static dispatch_group_t sessionGroup;
static bool stoppingSessionsForQuit;

bool StopDebugSessionsForQuit(dispatch_block_t finished)
{
    stoppingSessionsForQuit = true;
    if (!sessions.count)
        return false;
    for (DebugSession *session in sessions.allObjects)
        [session stop];
    dispatch_group_notify(sessionGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), finished);
    return true;
}

struct PendingDebugReply {
    uint64_t sequence;
    DebugReply reply;
};

static std::string_view DebugUTF8(NSString *text)
{
    const char *bytes = text.UTF8String;
    return bytes ? std::string_view(bytes, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string_view{};
}

static NSString *PanicFunction(Language language)
{
    if (language == Language::Rust)
        return @"rust_panic";

    // Go reaches fatalpanic after deferred recover calls have had a chance to run.
    return language == Language::Go ? @"runtime.fatalpanic" : nil;
}

static NSString *DebugAdapterName(DebugBackend backend)
{
    switch (backend) {
    case DebugBackend::SBCL: return @"SBCL";
    case DebugBackend::Debugpy: return @"debugpy";
    default: return @"LLDB";
    }
}

static std::string_view DebugDataView(NSData *data)
{
    return data.length ? std::string_view(static_cast<const char *>(data.bytes), data.length) : std::string_view{};
}

static NSString *DebugText(std::string_view bytes)
{
    NSString *text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
    return text ? text : [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
}

@interface DebugSession ()
- (void)receiveEvents;
@end

@implementation DebugSession {
    DebugExecutable *_executable;
    NSArray<NSString *> *_arguments;
    Language _language;
    DebugBackend _backend;
    pid_t _attachPID;
    DebugTransport _transport;
    DebugBatch _batch;
    CFRunLoopSourceRef _eventSource;
    bool _receiving;
    bool _needsDrain;
    bool _terminalOpen;
    std::vector<PendingDebugReply> _replies;
    NSMutableDictionary<NSString *, NSDictionary<NSNumber *, NSNumber *> *> *_resolved;
    NSDictionary *_capabilities;
    NSString *_temporaryPath;
    NSMutableString *_rustOutputTail;
    NSUInteger _temporaryLine;
    NSUInteger _sequence;
    NSUInteger _stackRequest;
    NSUInteger _stopSequence;
    NSInteger _panicBreakpoint;
    BOOL _configured;
    BOOL _hasExitCode;
    BOOL _rustPanic;
}

- (instancetype)initWithExecutable:(DebugExecutable *)executable arguments:(NSArray<NSString *> *)arguments
                          language:(Language)language pid:(pid_t)pid
{
    self = [super init];
    if (self) {
        _executable = executable;
        _arguments = [arguments copy];
        _language = language;
        _backend = executable.backend;
        _attachPID = pid;
        _phase = DebugPhase::Launching;
        _status = [NSString stringWithFormat:@"Starting %@…", DebugAdapterName(_backend)];
    }
    return self;
}

- (BOOL)attached
{
    return _attachPID > 0;
}

- (BOOL)acceptsInput
{
    return _terminalOpen && _phase == DebugPhase::Running;
}

- (NSString *)rustPanicMessage
{
    NSRange panic = [_rustOutputTail rangeOfString:@" panicked at " options:NSBackwardsSearch];
    if (!_rustOutputTail || panic.location == NSNotFound)
        return @"Rust panic";
    NSUInteger start = NSMaxRange(panic);
    NSUInteger end, next;
    [_rustOutputTail getLineStart:nullptr end:&next contentsEnd:&end forRange:NSMakeRange(start, 0)];
    if (end > start && [_rustOutputTail characterAtIndex:start] == '\'')
        return [_rustOutputTail substringWithRange:NSMakeRange(start, end - start)];
    if (next < _rustOutputTail.length) {
        NSRange line = [_rustOutputTail lineRangeForRange:NSMakeRange(next, 0)];
        NSString *message = [[_rustOutputTail substringWithRange:line]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (message.length && ![message hasPrefix:@"note:"])
            return message;
    }
    return @"Rust panic";
}

- (void)writeOutput:(NSString *)text tone:(OutputTone)tone
{
    if (text.length && self.output)
        self.output(text, tone);
}

- (void)writeProgramOutput:(NSString *)text tone:(OutputTone)tone
{
    if (_language == Language::Rust && text.length) {
        if (!_rustOutputTail)
            _rustOutputTail = [NSMutableString string];
        constexpr NSUInteger limit = 4096;
        NSUInteger skip = text.length > limit ? text.length - limit : 0;
        [_rustOutputTail appendString:skip ? [text substringFromIndex:skip] : text];
        if (_rustOutputTail.length > limit)
            [_rustOutputTail deleteCharactersInRange:NSMakeRange(0, _rustOutputTail.length - limit)];
        if (_rustPanic) {
            NSString *message = [self rustPanicMessage];
            if (![_exception isEqualToString:message]) {
                _exception = message;
                if (self.changed)
                    self.changed();
            }
        }
    }
    [self writeOutput:text tone:tone];
}

- (void)report:(NSString *)text
{
    [self writeOutput:[text stringByAppendingString:@"\n"] tone:OutputTone::Error];
}

- (void)changePhase:(DebugPhase)phase status:(NSString *)status
{
    _phase = phase;
    _status = status;
    if (phase != DebugPhase::Paused) {
        ++_revision;
        ++_stopSequence;
        _frames = nil;
        _frame = nil;
        _exception = nil;
        if (_rustPanic)
            [_rustOutputTail setString:@""];
        _rustPanic = NO;
    }
    if (self.changed)
        self.changed();
}

- (void)fail:(NSString *)message
{
    [self report:message];
    _status = @"Debugging failed";
    [self stop];
}

- (void)adapterExited
{
    CFRunLoopSourceInvalidate(_eventSource);
    CFRelease(_eventSource);
    _eventSource = nullptr;
    _terminalOpen = false;
    _replies = {};
    _resolved = nil;
    _capabilities = nil;
    _rustOutputTail = nil;
    _configured = NO;
    _executable = nil;
    if (_phase != DebugPhase::Stopping && _phase != DebugPhase::Finished && !_hasExitCode) {
        if (_phase == DebugPhase::Launching && _backend == DebugBackend::Debugpy)
            [self report:@"Install debugpy in the Python environment used to run this file."];
        else
            [self report:[NSString stringWithFormat:@"%@ disconnected.", DebugAdapterName(_backend)]];
    }

    NSString *status = (_hasExitCode || _phase == DebugPhase::Stopping) ? _status : @"Disconnected";
    [sessions removeObject:self];
    dispatch_group_leave(sessionGroup);
    [self changePhase:DebugPhase::Finished status:status];
}

- (void)receiveEvents
{
    if (_receiving) {
        _needsDrain = true;
        return;
    }

    _receiving = true;
    _needsDrain = false;
    TakeDebugEvents(_transport, _batch);
    for (const auto &event : _batch.events) {
        @autoreleasepool {
            auto bytes = std::string_view(_batch.bytes).substr(event.offset, event.length);
            switch (event.kind) {
            case DebugEventKind::Packet: {
                NSData *data = [NSData dataWithBytesNoCopy:const_cast<char *>(bytes.data()) length:bytes.size() freeWhenDone:NO];
                id message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([message isKindOfClass:NSDictionary.class])
                    [self receive:message];
                else
                    [self fail:@"Invalid response from LLDB."];
                break;
            }

            case DebugEventKind::Program:
            case DebugEventKind::ProgramError:
                [self writeProgramOutput:DebugText(bytes)
                                    tone:event.kind == DebugEventKind::ProgramError ? OutputTone::Error : OutputTone::Text];
                break;

            case DebugEventKind::Console:
            case DebugEventKind::AdapterError:
                [self writeOutput:DebugText(bytes) tone:event.kind == DebugEventKind::AdapterError ? OutputTone::Error : OutputTone::Text];
                break;

            case DebugEventKind::Invalid:
                [self fail:@"Invalid response from LLDB."];
                break;

            case DebugEventKind::Exit:
                [self adapterExited];
                break;
            }
        }
    }

    _receiving = false;
    if (!_eventSource) {
        _batch = {};
    } else if (_needsDrain) {
        CFRunLoopSourceSignal(_eventSource);
        CFRunLoopWakeUp(CFRunLoopGetMain());
    }
}

- (void)start
{
    if (stoppingSessionsForQuit || _eventSource)
        return;

    _resolved = [NSMutableDictionary dictionary];
    __attribute__((objc_precise_lifetime)) NSString *tool = _executable.interpreter;
    __attribute__((objc_precise_lifetime)) NSString *worker = nil;
    const char *argv[5]{};
    NSString *adapterID = @"lldb";
    if (_backend == DebugBackend::SBCL) {
        worker = [NSBundle.mainBundle pathForResource:@"LispDebug" ofType:@"lisp"];
        if (!worker.length) {
            [self report:@"LispDebug.lisp is missing from Retina Code."];
            [self changePhase:DebugPhase::Finished status:@"Debugging failed"];
            return;
        }

        argv[0] = tool.fileSystemRepresentation;
        argv[1] = "--noinform";
        argv[2] = "--script";
        argv[3] = worker.fileSystemRepresentation;
        adapterID = @"common-lisp";
        _transport.lispRequests = true;
    } else if (_backend == DebugBackend::Debugpy) {
        argv[0] = tool.fileSystemRepresentation;
        argv[1] = "-m";
        argv[2] = "debugpy.adapter";
        adapterID = @"debugpy";
    } else {
        tool = FindTool(@"lldb-dap", Language::Plain);
        argv[0] = tool ? tool.fileSystemRepresentation : "/usr/bin/xcrun";
        argv[1] = tool ? nullptr : "lldb-dap";
    }

    CFRunLoopSourceContext events{};
    events.info = (__bridge void *)self;
    events.perform = [](void *context) {
        __attribute__((objc_precise_lifetime)) DebugSession *session = (__bridge DebugSession *)context;
        [session receiveEvents];
    };
    _eventSource = CFRunLoopSourceCreate(nullptr, 0, &events);
    CFRunLoopRef loop = CFRunLoopGetMain();
    if (_eventSource) {
        CFRunLoopAddSource(loop, _eventSource, kCFRunLoopDefaultMode);
        CFRunLoopAddSource(loop, _eventSource, (__bridge CFStringRef)NSModalPanelRunLoopMode);
    }

    auto wake = [](void *source) {
        CFRunLoopSourceSignal(static_cast<CFRunLoopSourceRef>(source));
        CFRunLoopWakeUp(CFRunLoopGetMain());
    };
    int error = _eventSource ? StartDebugTransport(_transport, argv, _executable.directory.fileSystemRepresentation, wake, _eventSource) : ENOMEM;
    if (error) {
        if (_eventSource) {
            CFRunLoopSourceInvalidate(_eventSource);
            CFRelease(_eventSource);
            _eventSource = nullptr;
        }

        [self report:[NSError errorWithDomain:NSPOSIXErrorDomain code:error userInfo:nil].localizedDescription];
        [self changePhase:DebugPhase::Finished status:@"Debugging failed"];
        return;
    }

    if (!sessions) {
        sessions = [NSMutableSet set];
        sessionGroup = dispatch_group_create();
    }

    [sessions addObject:self];
    dispatch_group_enter(sessionGroup);
    __weak DebugSession *weak = self;
    [self request:@"initialize" arguments:@{
        @"adapterID":adapterID, @"clientID":@"retina-code", @"clientName":@"Retina Code",
        @"linesStartAt1":@YES, @"columnsStartAt1":@YES, @"pathFormat":@"path",
        @"supportsVariableType":@YES, @"supportsVariablePaging":@YES,
        @"$__lldb_sourceInitFile":@NO
    } reply:^(NSDictionary *body, NSString *failure) {
        DebugSession *session = weak;
        if (failure)
            [session fail:failure];
        else
            [session launch:body];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        DebugSession *session = weak;
        if (session && session.phase == DebugPhase::Launching) {
            NSString *error = session->_backend == DebugBackend::LLDB ?
                @"LLDB could not start the program. Check for a macOS Developer Tools prompt." : @"The debugger did not respond.";
            [session fail:error];
        }
    });
}

- (NSString *)openTerminal
{
    char path[PATH_MAX];
    if (StartDebugTerminal(_transport, path))
        return nil;

    _terminalOpen = true;
    return [NSString stringWithUTF8String:path];
}

- (void)launch:(NSDictionary *)capabilities
{
    if (_phase != DebugPhase::Launching)
        return;
    _capabilities = capabilities;
    NSMutableDictionary *arguments = [NSMutableDictionary dictionary];
    NSString *command = self.attached ? @"attach" : @"launch";
    if (_executable.file)
        arguments[@"program"] = _executable.file.path;

    if (_backend != DebugBackend::LLDB) {
        arguments[@"cwd"] = _executable.directory.path;
        arguments[@"args"] = _arguments ? _arguments : @[];
        if (_backend == DebugBackend::SBCL) {
            arguments[@"terminal"] = [self openTerminal];
        } else {
            arguments[@"python"] = @[_executable.interpreter];
            arguments[@"console"] = @"internalConsole";
            arguments[@"redirectOutput"] = @YES;
            arguments[@"justMyCode"] = @YES;
            arguments[@"subProcess"] = @NO;
        }

        __weak DebugSession *weak = self;
        [self request:@"launch" arguments:arguments reply:^(NSDictionary *, NSString *error) {
            if (error)
                [weak fail:error];
        }];
        return;
    }

    if (_executable.directory) {
        arguments[@"cwd"] = _executable.directory.path;
        arguments[@"debuggerRoot"] = _executable.directory.path;
        arguments[@"sourcePath"] = _executable.directory.path;
    }
    arguments[@"stopOnEntry"] = @(self.attached);
    if (self.attached) {
        arguments[@"pid"] = @(_attachPID);
    } else {
        arguments[@"args"] = _arguments ? _arguments : @[];
        arguments[@"disableASLR"] = @NO;
    }
    NSMutableArray *commands = [NSMutableArray array];
    if (!self.attached) {
        if (NSString *path = [self openTerminal]) {
            for (NSString *stream in @[@"input", @"output", @"error"])
                [commands addObject:[NSString stringWithFormat:@"?settings set target.%@-path %@", stream, path]];
        }
    }
    NSString *panic = PanicFunction(_language);
    if (panic && ![capabilities[@"supportsFunctionBreakpoints"] boolValue])
        [commands addObject:[NSString stringWithFormat:@"?breakpoint set --name %@", panic]];
    if (commands.count)
        arguments[@"preRunCommands"] = commands;

    __weak DebugSession *weak = self;
    [self request:command arguments:arguments reply:^(NSDictionary *, NSString *error) {
        if (error)
            [weak fail:error];
    }];
}

- (void)stop
{
    if (!_eventSource || _phase == DebugPhase::Stopping || _phase == DebugPhase::Finished)
        return;
    NSString *status = [_status isEqualToString:@"Debugging failed"] ? _status : self.attached ? @"Detached" : @"Stopped";
    [self changePhase:DebugPhase::Stopping status:status];
    [self disconnect];
}

- (void)disconnect
{
    if (!_eventSource)
        return;

    RequestDebugStop(_transport);
    __weak DebugSession *weak = self;
    [self request:@"disconnect" arguments:@{@"terminateDebuggee":@(!self.attached)} reply:^(NSDictionary *, NSString *) {
        DebugSession *session = weak;
        if (session)
            CloseDebugInput(session->_transport);
    }];
}

- (void)request:(NSString *)command arguments:(NSDictionary *)arguments reply:(DebugReply)reply
{
    if (!_eventSource)
        return;

    uint64_t sequence = ++_sequence;
    __attribute__((objc_precise_lifetime)) NSData *data = arguments ? [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil] : nil;
    if ((arguments && !data) || !SendDebugRequest(_transport, sequence, DebugUTF8(command), DebugDataView(data))) {
        if (reply)
            reply(nil, @"Could not send the request to the debugger.");
        return;
    }

    if (reply)
        _replies.push_back({sequence, reply});
}

- (void)send:(NSDictionary *)message
{
    __attribute__((objc_precise_lifetime)) NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    SendDebugPacket(_transport, DebugDataView(data));
}

- (void)receive:(NSDictionary *)message
{
    if (!_eventSource)
        return;
    NSString *type = message[@"type"];
    if (![type isKindOfClass:NSString.class])
        return;

    if ([type isEqualToString:@"response"]) {
        uint64_t sequence = [message[@"request_seq"] unsignedLongLongValue];
        auto pending = std::find_if(_replies.begin(), _replies.end(), [sequence](const PendingDebugReply &request) {
            return request.sequence == sequence;
        });
        if (pending != _replies.end()) {
            DebugReply reply = pending->reply;
            if (pending != _replies.end() - 1)
                *pending = std::move(_replies.back());
            _replies.pop_back();
            NSString *error = [message[@"success"] boolValue] ? nil : message[@"message"] ? message[@"message"] : @"Debugger request failed.";
            reply(message[@"body"], error);
        }
        return;
    }
    if ([type isEqualToString:@"request"] && message[@"seq"] && message[@"command"]) {
        [self send:@{@"type":@"response", @"seq":@(++_sequence), @"request_seq":message[@"seq"],
                     @"command":message[@"command"], @"success":@NO, @"message":@"Request is unsupported."}];
        return;
    }
    NSString *event = message[@"event"];
    NSDictionary *body = message[@"body"];
    if (![event isKindOfClass:NSString.class])
        return;

    if ([event isEqualToString:@"exited"]) {
        int code = [body[@"exitCode"] intValue];
        _hasExitCode = YES;
        NSString *status = [NSString stringWithFormat:@"Exited (%d)", code];
        [self writeOutput:[NSString stringWithFormat:@"\nProcess exited with code %d.\n", code]
                     tone:code ? OutputTone::Error : OutputTone::Text];
        if (_phase != DebugPhase::Stopping) {
            [self changePhase:DebugPhase::Stopping status:status];
            [self disconnect];
        }
    } else if ([event isEqualToString:@"terminated"] && _phase != DebugPhase::Stopping) {
        [self changePhase:DebugPhase::Stopping status:_hasExitCode ? _status : @"Ended"];
        [self disconnect];
    } else if (_phase == DebugPhase::Stopping || _phase == DebugPhase::Finished) {
        return;
    } else if ([event isEqualToString:@"initialized"]) {
        [self configure];
    } else if ([event isEqualToString:@"stopped"]) {
        [self stopped:body];
    } else if ([event isEqualToString:@"continued"] && _phase != DebugPhase::Running) {
        [self changePhase:DebugPhase::Running status:@"Running"];
    } else if ([event isEqualToString:@"breakpoint"]) {
        NSDictionary *breakpoint = body[@"breakpoint"];
        NSString *path = breakpoint[@"source"][@"path"];
        NSNumber *line = breakpoint[@"line"];
        if (path.length && line) {
            if (path.isAbsolutePath)
                path = DebugSourcePath([NSURL fileURLWithPath:path]);

            NSMutableDictionary *states = [_resolved[path] mutableCopy];
            if (!states)
                states = [NSMutableDictionary dictionary];
            states[line] = breakpoint[@"verified"];
            _resolved[path] = states;
            if (self.changed)
                self.changed();
        }
    }
}

- (void)configure
{
    if (_configured)
        return;
    _configured = YES;
    for (NSString *path in DebugAllBreakpoints())
        [self sendBreakpoints:path];
    NSMutableArray *filters = [NSMutableArray array];
    for (NSDictionary *option in _capabilities[@"exceptionBreakpointFilters"]) {
        NSString *name = option[@"filter"];
        if (!name)
            continue;
        if ((_backend == DebugBackend::Debugpy && [name isEqualToString:@"uncaught"]) || [name isEqualToString:@"cpp_throw"] || [name isEqualToString:@"objc_throw"] ||
            [name isEqualToString:@"swift_throw"]) {
            [filters addObject:name];
        }
    }

    __weak DebugSession *weak = self;
    [self request:@"setExceptionBreakpoints" arguments:@{@"filters":filters} reply:nil];
    NSString *panic = PanicFunction(_language);
    if (panic && [_capabilities[@"supportsFunctionBreakpoints"] boolValue]) {
        [self request:@"setFunctionBreakpoints" arguments:@{@"breakpoints":@[@{@"name":panic}]}
                reply:^(NSDictionary *body, NSString *) {
            DebugSession *session = weak;
            if (session) {
                NSArray *points = body[@"breakpoints"];
                session->_panicBreakpoint = [points.firstObject[@"id"] integerValue];
            }
        }];
    }
    [self request:@"configurationDone" arguments:nil reply:^(NSDictionary *, NSString *error) {
        DebugSession *session = weak;
        if (error) {
            [session fail:error];
        } else if (session && session.phase == DebugPhase::Launching) {
            [session changePhase:DebugPhase::Running status:@"Running"];
        }
    }];
}

- (void)sendBreakpoints:(NSString *)path
{
    [self sendBreakpoints:path checking:0 ready:nil];
}

- (void)sendBreakpoints:(NSString *)path checking:(NSUInteger)line ready:(void (^)(BOOL))ready
{
    if (!_configured || !path.length || _phase == DebugPhase::Stopping) {
        if (ready)
            ready(NO);
        return;
    }
    NSDictionary *lines = DebugBreakpoints(path);
    NSMutableArray *requested = [NSMutableArray arrayWithCapacity:lines.count + 1];
    BOOL temporary = [_temporaryPath isEqualToString:path];
    for (NSNumber *line in [lines.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *options = lines[line];
        if ([options[@"disabled"] boolValue] && !(temporary && line.unsignedIntegerValue == _temporaryLine))
            continue;
        NSMutableDictionary *point = [NSMutableDictionary dictionaryWithObject:line forKey:@"line"];
        if (!(temporary && line.unsignedIntegerValue == _temporaryLine)) {
            for (NSString *key in @[@"condition", @"hitCondition", @"logMessage"])
                point[key] = options[key];
        }
        [requested addObject:point];
        if (temporary && line.unsignedIntegerValue == _temporaryLine)
            temporary = NO;
    }
    if (temporary)
        [requested addObject:@{@"line":@(_temporaryLine)}];

    __weak DebugSession *weak = self;
    [self request:@"setBreakpoints" arguments:@{@"source":@{@"path":path}, @"breakpoints":requested}
             reply:^(NSDictionary *body, NSString *error) {
        DebugSession *session = weak;
        if (!session)
            return;
        if (error) {
            [session report:error];
            if (ready)
                ready(NO);
            return;
        }
        NSMutableDictionary *states = [NSMutableDictionary dictionary];
        NSArray *received = body[@"breakpoints"];
        for (NSUInteger i = 0; i < std::min(requested.count, received.count); ++i)
            states[requested[i][@"line"]] = @([received[i][@"verified"] boolValue]);
        session->_resolved[path] = states;
        if (session.changed)
            session.changed();
        if (ready)
            ready([states[@(line)] boolValue]);
    }];
}

- (BOOL)breakpointResolved:(NSString *)path line:(NSUInteger)line
{
    return !_configured || [_resolved[path][@(line)] boolValue];
}

- (void)runToLine:(NSUInteger)line path:(NSString *)path
{
    if (_phase != DebugPhase::Paused || !line || !path.length || _temporaryPath)
        return;
    _temporaryPath = path;
    _temporaryLine = line;
    NSUInteger stop = _stopSequence;
    __weak DebugSession *weak = self;
    [self sendBreakpoints:path checking:line ready:^(BOOL resolved) {
        DebugSession *session = weak;
        if (!session || session->_stopSequence != stop || session.phase != DebugPhase::Paused)
            return;
        if (resolved) {
            [session performCommand:DebugCommand::Continue];
        } else {
            session->_temporaryPath = nil;
            session->_temporaryLine = 0;
            [session sendBreakpoints:path];
            [session report:@"No executable code at the cursor."];
        }
    }];
}

- (void)stopped:(NSDictionary *)body
{
    _threadID = body[@"threadId"];
    _frame = nil;
    _frames = nil;
    _threads = nil;
    ++_revision;
    NSString *reason = body[@"reason"];
    BOOL nativeException = [reason isEqualToString:@"exception"] || [reason isEqualToString:@"signal"];
    bool panic = _panicBreakpoint > 0 && [body[@"hitBreakpointIds"] containsObject:@(_panicBreakpoint)];
    _rustPanic = panic && _language == Language::Rust;
    _exception = nil;
    if (_rustPanic) {
        _exception = [self rustPanicMessage];
    } else if (panic && _language == Language::Go) {
        _exception = @"Go panic";
    } else if (nativeException) {
        NSString *description = body[@"description"];
        if (!description.length)
            description = body[@"text"];
        _exception = description.length ? description : @"Exception";
    }
    NSUInteger stop = ++_stopSequence;
    NSString *path = _temporaryPath;
    _temporaryPath = nil;
    _temporaryLine = 0;
    [self changePhase:DebugPhase::Paused status:_exception ? @"Exception" : @"Paused"];
    if (path)
        [self sendBreakpoints:path];

    __weak DebugSession *weak = self;
    NSNumber *thread = _threadID;
    [self request:@"threads" arguments:nil reply:^(NSDictionary *reply, NSString *error) {
        DebugSession *session = weak;
        if (!session || session.phase != DebugPhase::Paused || stop != session->_stopSequence)
            return;
        session->_threads = reply[@"threads"];
        if (!session.threadID)
            [session selectThread:session.threads.firstObject[@"id"]];
        else if (session.changed)
            session.changed();
        if (error)
            [session report:error];
    }];
    if (thread)
        [self loadFrames:thread];
    if (thread && nativeException && !_rustPanic && [_capabilities[@"supportsExceptionInfoRequest"] boolValue]) {
        [self request:@"exceptionInfo" arguments:@{@"threadId":thread} reply:^(NSDictionary *reply, NSString *) {
            DebugSession *session = weak;
            if (!session || session.phase != DebugPhase::Paused || stop != session->_stopSequence)
                return;
            NSString *description = reply[@"details"][@"message"];
            if (!description.length)
                description = reply[@"description"];
            if (description.length) {
                session->_exception = description;
                if (session.changed)
                    session.changed();
            }
        }];
    }
}

- (void)loadFrames:(NSNumber *)thread
{
    NSUInteger request = ++_stackRequest;
    __weak DebugSession *weak = self;
    [self request:@"stackTrace" arguments:@{@"threadId":thread, @"startFrame":@0, @"levels":@100}
             reply:^(NSDictionary *reply, NSString *error) {
        DebugSession *session = weak;
        if (!session || session.phase != DebugPhase::Paused || request != session->_stackRequest)
            return;
        if (error) {
            [session report:error];
            return;
        }
        session->_frames = reply[@"stackFrames"];
        NSDictionary *selected = nil;
        NSString *topName = session.frames.firstObject[@"name"];
        if (session->_language == Language::Rust && !session->_rustPanic &&
            ([topName hasPrefix:@"__rustc::rust_panic"] || [topName hasPrefix:@"std::panicking::rust_panic"] ||
             [topName isEqualToString:@"rust_panic"])) {
            session->_status = @"Exception";
            session->_rustPanic = YES;
            session->_exception = [session rustPanicMessage];
        } else if (session->_language == Language::Go && [topName isEqualToString:@"runtime.fatalpanic"]) {
            session->_status = @"Exception";
            session->_exception = @"Go panic";
        }

        BOOL preferUserSource = session.exception.length > 0;
        NSString *sourceRoot = preferUserSource ? DebugSourcePath(session->_executable.directory) : nil;
        for (NSDictionary *frame in session.frames) {
            NSString *path = frame[@"source"][@"path"];
            if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path])
                continue;
            if (!selected)
                selected = frame;
            if (!preferUserSource || PathIsInFolder(DebugSourcePath([NSURL fileURLWithPath:path]), sourceRoot)) {
                selected = frame;
                break;
            }
        }
        [session selectFrame:selected ? selected : session.frames.firstObject];
    }];
}

- (void)evaluateWatch:(NSString *)expression reply:(DebugReply)reply
{
    NSNumber *frameID = _frame[@"id"];
    if (_phase != DebugPhase::Paused || !frameID)
        return;
    NSString *path = _frame[@"source"][@"path"];
    Language language = DetectLanguage(DebugUTF8(path));
    if (language == Language::Plain)
        language = _language;

    // LLDB can resolve variable paths in Rust and Go without compiling an expression.
    bool variable_path = language == Language::Rust || language == Language::Go;
    NSString *context = variable_path ? @"hover" : @"watch";
    [self request:@"evaluate" arguments:@{@"expression":expression, @"frameId":frameID, @"context":context}
             reply:^(NSDictionary *body, NSString *error) {
        if (reply)
            reply(body, variable_path && error ? @"Unavailable in this frame" : error);
    }];
}

- (void)selectThread:(NSNumber *)thread
{
    if (_phase != DebugPhase::Paused || !thread)
        return;
    _threadID = thread;
    _frames = nil;
    [self selectFrame:nil];
    [self loadFrames:thread];
}

- (void)selectFrame:(NSDictionary *)frame
{
    if (_phase != DebugPhase::Paused)
        return;
    _frame = frame;
    ++_revision;
    if (self.changed)
        self.changed();
}

- (void)performCommand:(DebugCommand)command
{
    NSString *request = nil;
    switch (command) {
    case DebugCommand::Pause: request = @"pause"; break;
    case DebugCommand::Continue: request = @"continue"; break;
    case DebugCommand::StepOver: request = @"next"; break;
    case DebugCommand::StepInto: request = @"stepIn"; break;
    case DebugCommand::StepOut: request = @"stepOut"; break;
    default: return;
    }
    if (command == DebugCommand::Pause ? _phase != DebugPhase::Running : _phase != DebugPhase::Paused)
        return;
    if (command != DebugCommand::Pause && !_threadID)
        return;
    NSUInteger revision = _revision;
    __weak DebugSession *weak = self;
    [self request:request arguments:@{@"threadId":_threadID ? _threadID : @0} reply:^(NSDictionary *, NSString *error) {
        DebugSession *session = weak;
        if (error)
            [session report:error];
        else if (command != DebugCommand::Pause && session.phase == DebugPhase::Paused && session.revision == revision)
            [session changePhase:DebugPhase::Running status:@"Running"];
    }];
}

- (BOOL)sendInput:(NSString *)text
{
    if (!self.acceptsInput)
        return NO;
    return SendDebugInput(_transport, DebugUTF8(text));
}

@end