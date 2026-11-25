#import "Debugger.h"
#import <AppKit/AppKit.h>
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <util.h>
#include <unistd.h>

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
static bool quitting;

bool StopDebugSessionsForQuit(dispatch_block_t finished)
{
    quitting = true;
    if (!sessions.count)
        return false;
    for (DebugSession *session in sessions.allObjects)
        [session stop];
    dispatch_group_notify(sessionGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), finished);
    return true;
}

static void OnDebugMain(dispatch_block_t work)
{
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(loop, (__bridge CFArrayRef)@[NSDefaultRunLoopMode, NSModalPanelRunLoopMode], work);
    CFRunLoopWakeUp(loop);
}

static NSData *ReadDebugPipe(NSFileHandle *file)
{
    char bytes[16 * 1024];
    ssize_t size;
    do {
        size = read(file.fileDescriptor, bytes, sizeof(bytes));
    } while (size < 0 && errno == EINTR);
    return size > 0 ? [NSData dataWithBytes:bytes length:NSUInteger(size)] : nil;
}

static constexpr NSUInteger maxPacketSize = 16 * 1024 * 1024;

// Only the pipe reader touches the receive buffer. Replies and debugger state live on the main thread.
@interface DebugPackets : NSObject
@property(nonatomic, copy) void (^message)(NSDictionary *);
@property(nonatomic, copy) dispatch_block_t invalid;
- (void)receive:(NSData *)data;
@end

@implementation DebugPackets {
    NSMutableData *_data;
    NSUInteger _bodyLength;
}

- (void)receive:(NSData *)data
{
    if (!_data)
        _data = [NSMutableData data];
    [_data appendData:data];
    while (_data.length) {
        if (!_bodyLength) {
            NSData *separator = [NSData dataWithBytes:"\r\n\r\n" length:4];
            NSRange header = [_data rangeOfData:separator options:0 range:NSMakeRange(0, _data.length)];
            if (header.location == NSNotFound && _data.length < 4096)
                return;
            if (header.location != NSNotFound && header.location < 4096) {
                NSString *text = [[NSString alloc] initWithBytes:_data.bytes length:header.location
                                                        encoding:NSASCIIStringEncoding];
                for (NSString *line in [text componentsSeparatedByString:@"\r\n"]) {
                    if (![line hasPrefix:@"Content-Length:"])
                        continue;
                    NSScanner *scanner = [NSScanner scannerWithString:[line substringFromIndex:15]];
                    unsigned long long length = 0;
                    if ([scanner scanUnsignedLongLong:&length] && scanner.isAtEnd && length <= maxPacketSize)
                        _bodyLength = NSUInteger(length);
                }
            }
            if (!_bodyLength)
                break;
            [_data replaceBytesInRange:NSMakeRange(0, NSMaxRange(header)) withBytes:nullptr length:0];
        }
        if (_data.length < _bodyLength)
            return;
        NSData *body = [NSData dataWithBytes:_data.bytes length:_bodyLength];
        [_data replaceBytesInRange:NSMakeRange(0, _bodyLength) withBytes:nullptr length:0];
        _bodyLength = 0;
        id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![object isKindOfClass:NSDictionary.class]) {
            _invalid();
            [_data setLength:0];
            return;
        }
        _message(object);
    }
    if (_data.length) {
        [_data setLength:0];
        _invalid();
    }
}

@end

@implementation DebugSession {
    DebugExecutable *_executable;
    NSArray<NSString *> *_arguments;
    Language _language;
    pid_t _attachPID;
    NSTask *_task;
    NSFileHandle *_input;
    NSFileHandle *_reader;
    NSFileHandle *_stderrReader;
    NSFileHandle *_terminal;
    NSFileHandle *_slave;
    dispatch_queue_t _writes;
    dispatch_queue_t _terminalWrites;
    NSMutableDictionary<NSNumber *, DebugReply> *_replies;
    NSMutableDictionary<NSString *, NSDictionary<NSNumber *, NSNumber *> *> *_resolved;
    NSDictionary *_capabilities;
    NSString *_temporaryPath;
    NSMutableString *_rustOutputTail;
    NSUInteger _temporaryLine;
    NSUInteger _sequence;
    NSUInteger _stackRequest;
    NSUInteger _stopSequence;
    NSInteger _rustPanicBreakpoint;
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
        _attachPID = pid;
        _phase = DebugPhase::Launching;
        _status = @"Starting LLDB…";
        _replies = [NSMutableDictionary dictionary];
        _resolved = [NSMutableDictionary dictionary];
        _writes = dispatch_queue_create("RetinaCode.DebugWrites", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)attached
{
    return _attachPID > 0;
}

- (BOOL)acceptsInput
{
    return _terminal && _phase == DebugPhase::Running;
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

- (void)adapterExited:(NSTask *)task
{
    if (_task != task)
        return;
    _reader.readabilityHandler = nil;
    _stderrReader.readabilityHandler = nil;
    _terminal.readabilityHandler = nil;
    [_slave closeAndReturnError:nil];
    [_terminal closeAndReturnError:nil];
    _terminal = nil;
    _slave = nil;
    [_replies removeAllObjects];
    _input = nil;
    _reader = nil;
    _stderrReader = nil;
    _task = nil;
    _executable = nil;
    if (_phase != DebugPhase::Stopping && _phase != DebugPhase::Finished && !_hasExitCode)
        [self report:@"LLDB disconnected."];
    NSString *status = (_hasExitCode || _phase == DebugPhase::Stopping) ? _status : @"Disconnected";
    [sessions removeObject:self];
    dispatch_group_leave(sessionGroup);
    [self changePhase:DebugPhase::Finished status:status];
}

- (void)start
{
    if (quitting || _task)
        return;
    NSTask *task = [[NSTask alloc] init];
    NSString *tool = FindTool(@"lldb-dap", Language::Plain);
    task.executableURL = [NSURL fileURLWithPath:tool ? tool : @"/usr/bin/xcrun"];
    task.arguments = tool ? @[] : @[@"lldb-dap"];
    task.currentDirectoryURL = _executable.directory;
    NSPipe *input = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    __weak DebugSession *weak = self;
    DebugPackets *packets = [[DebugPackets alloc] init];
    packets.message = ^(NSDictionary *message) {
        OnDebugMain(^{ [weak receive:message]; });
    };
    packets.invalid = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weak fail:@"Invalid response from LLDB."]; });
    };

    _reader = stdoutPipe.fileHandleForReading;
    _stderrReader = stderrPipe.fileHandleForReading;
    _input = input.fileHandleForWriting;
    fcntl(_input.fileDescriptor, F_SETNOSIGPIPE, 1);
    _reader.readabilityHandler = ^(NSFileHandle *file) {
        NSData *data = ReadDebugPipe(file);
        if (data.length)
            [packets receive:data];
        else
            file.readabilityHandler = nil;
    };
    _stderrReader.readabilityHandler = ^(NSFileHandle *file) {
        NSData *data = ReadDebugPipe(file);
        if (!data.length) {
            file.readabilityHandler = nil;
            return;
        }
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak writeOutput:message tone:OutputTone::Error]; });
    };
    task.terminationHandler = ^(NSTask *ended) {
        OnDebugMain(^{ [weak adapterExited:ended]; });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        _reader.readabilityHandler = nil;
        _stderrReader.readabilityHandler = nil;
        [self report:error.localizedDescription];
        [self changePhase:DebugPhase::Finished status:@"Could not start LLDB"];
        return;
    }
    _task = task;
    if (!sessions) {
        sessions = [NSMutableSet set];
        sessionGroup = dispatch_group_create();
    }
    [sessions addObject:self];
    dispatch_group_enter(sessionGroup);
    [self request:@"initialize" arguments:@{
        @"adapterID":@"lldb", @"clientID":@"retina-code", @"clientName":@"Retina Code",
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
        if (session && session.phase == DebugPhase::Launching)
            [session fail:@"LLDB could not start the program. Check for a macOS Developer Tools prompt."];
    });
}

- (NSString *)openTerminal
{
    int master = -1;
    int slave = -1;
    char path[PATH_MAX];
    if (openpty(&master, &slave, path, nullptr, nullptr) != 0)
        return nil;
    fcntl(master, F_SETFD, FD_CLOEXEC);
    fcntl(slave, F_SETFD, FD_CLOEXEC);
    struct termios mode;
    if (tcgetattr(slave, &mode) == 0) {
        mode.c_lflag &= ~ECHO;
        mode.c_oflag &= ~ONLCR;
        tcsetattr(slave, TCSANOW, &mode);
    }
    _terminalWrites = dispatch_queue_create("RetinaCode.DebugTerminalWrites", DISPATCH_QUEUE_SERIAL);
    _terminal = [[NSFileHandle alloc] initWithFileDescriptor:master closeOnDealloc:YES];
    _slave = [[NSFileHandle alloc] initWithFileDescriptor:slave closeOnDealloc:YES];
    __weak DebugSession *weak = self;
    _terminal.readabilityHandler = ^(NSFileHandle *file) {
        NSData *data = ReadDebugPipe(file);
        if (!data.length) {
            file.readabilityHandler = nil;
            return;
        }
        NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!string)
            string = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak writeProgramOutput:string tone:OutputTone::Text]; });
    };
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
    if (_language == Language::Rust && ![capabilities[@"supportsFunctionBreakpoints"] boolValue])
        [commands addObject:@"?breakpoint set --name rust_panic"];
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
    if (!_task || _phase == DebugPhase::Stopping || _phase == DebugPhase::Finished)
        return;
    NSString *status = [_status isEqualToString:@"Debugging failed"] ? _status : self.attached ? @"Detached" : @"Stopped";
    [self changePhase:DebugPhase::Stopping status:status];
    [self disconnect];
}

- (void)disconnect
{
    if (!_task)
        return;
    NSTask *task = _task;
    __weak DebugSession *weak = self;
    [self request:@"disconnect" arguments:@{@"terminateDebuggee":@(!self.attached)} reply:^(NSDictionary *, NSString *) {
        // Closing the protocol input lets the adapter flush its final events and exit.
        DebugSession *session = weak;
        if (session) {
            NSFileHandle *input = session->_input;
            dispatch_async(session->_writes, ^{ [input closeAndReturnError:nil]; });
        }
    }];
    dispatch_queue_t cleanup = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), cleanup, ^{
        if (task.running)
            [task terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), cleanup, ^{
            if (task.running)
                kill(task.processIdentifier, SIGKILL);
        });
    });
}

- (void)request:(NSString *)command arguments:(NSDictionary *)arguments reply:(DebugReply)reply
{
    if (!_task)
        return;
    NSNumber *sequence = @(++_sequence);
    NSDictionary *message = @{@"type":@"request", @"seq":sequence, @"command":command,
                              @"arguments":arguments ? arguments : @{}};
    if (reply)
        _replies[sequence] = [reply copy];
    [self send:message];
}

- (void)send:(NSDictionary *)message
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length > maxPacketSize)
        return;
    NSString *header = [NSString stringWithFormat:@"Content-Length: %lu\r\n\r\n", data.length];
    NSMutableData *packet = [NSMutableData dataWithData:[header dataUsingEncoding:NSASCIIStringEncoding]];
    [packet appendData:data];
    NSFileHandle *input = _input;
    dispatch_async(_writes, ^{ [input writeData:packet error:nil]; });
}

- (void)receive:(NSDictionary *)message
{
    if (!_task)
        return;
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"response"]) {
        NSNumber *sequence = message[@"request_seq"];
        if (!sequence)
            return;
        DebugReply reply = _replies[sequence];
        [_replies removeObjectForKey:sequence];
        if (reply) {
            NSString *error = nil;
            if (![message[@"success"] boolValue])
                error = message[@"message"] ? message[@"message"] : @"LLDB request failed.";
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
    if ([event isEqualToString:@"output"]) {
        NSString *category = body[@"category"];
        if ([category isEqualToString:@"stdout"] || [category isEqualToString:@"stderr"]) {
            [self writeProgramOutput:body[@"output"] tone:[category isEqualToString:@"stderr"] ? OutputTone::Error : OutputTone::Text];
        } else if (![category isEqualToString:@"telemetry"]) {
            [self writeOutput:body[@"output"] tone:OutputTone::Text];
        }
    } else if ([event isEqualToString:@"exited"]) {
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
        if ([name isEqualToString:@"cpp_throw"] || [name isEqualToString:@"objc_throw"] ||
            [name isEqualToString:@"swift_throw"]) {
            [filters addObject:name];
        }
    }

    __weak DebugSession *weak = self;
    [self request:@"setExceptionBreakpoints" arguments:@{@"filters":filters} reply:nil];
    if (_language == Language::Rust && [_capabilities[@"supportsFunctionBreakpoints"] boolValue]) {
        // The panic hook has already written its message by the time rust_panic runs.
        [self request:@"setFunctionBreakpoints" arguments:@{@"breakpoints":@[@{@"name":@"rust_panic"}]}
                reply:^(NSDictionary *body, NSString *) {
            DebugSession *session = weak;
            if (session) {
                NSArray *points = body[@"breakpoints"];
                session->_rustPanicBreakpoint = [points.firstObject[@"id"] integerValue];
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
    _rustPanic = _rustPanicBreakpoint > 0 && [body[@"hitBreakpointIds"] containsObject:@(_rustPanicBreakpoint)];
    _exception = nil;
    if (_rustPanic) {
        _exception = [self rustPanicMessage];
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
        NSString *directory = session->_executable.directory.path;
        NSString *topName = session.frames.firstObject[@"name"];
        if (session->_language == Language::Rust && !session->_rustPanic &&
            ([topName hasPrefix:@"__rustc::rust_panic"] || [topName hasPrefix:@"std::panicking::rust_panic"] ||
             [topName isEqualToString:@"rust_panic"])) {
            session->_status = @"Exception";
            session->_rustPanic = YES;
            session->_exception = [session rustPanicMessage];
        }
        BOOL preferUserSource = session.exception.length > 0;
        NSString *sourceRoot = [directory stringByAppendingString:@"/"];
        for (NSDictionary *frame in session.frames) {
            NSString *path = frame[@"source"][@"path"];
            if (!path.isAbsolutePath || ![NSFileManager.defaultManager fileExistsAtPath:path])
                continue;
            if (!selected)
                selected = frame;
            if (!preferUserSource || (sourceRoot && [path hasPrefix:sourceRoot])) {
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
    BOOL rust = _language == Language::Rust || [path.pathExtension.lowercaseString isEqualToString:@"rs"];
    NSString *context = rust ? @"hover" : @"watch";
    // Hover resolves variable paths without requesting Rust expression compilation.
    [self request:@"evaluate" arguments:@{@"expression":expression, @"frameId":frameID, @"context":context}
             reply:^(NSDictionary *body, NSString *error) {
        reply(body, rust && error ? @"Unavailable in this frame" : error);
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
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *terminal = _terminal;
    dispatch_async(_terminalWrites, ^{ [terminal writeData:data error:nil]; });
    return YES;
}

@end