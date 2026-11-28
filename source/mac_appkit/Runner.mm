// Running files in the AppKit editor. Run.cpp makes every decision: what a file belongs to, what builds and runs it,
// and what its output says. This side runs its jobs on a dispatch queue, runs their children with ChildProcess.cpp,
// and turns their lines into the RunMessages the output pane and the editor show.

#import "Runner.h"
#include "ChildProcess.hpp"
#include "../Run.hpp"
#import "Workspace.h"

#include <cstring>

static NSString *RunString(std::string_view bytes)
{
    NSString *text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
    if (!text)
        text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
    return text;
}

static NSURL *RunURL(const std::string &path, BOOL folder)
{
    return path.empty() ? nil : [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:folder relativeToURL:nil];
}

static std::string RunPath(NSURL *url)
{
    const char *path = url.fileSystemRepresentation;
    return path ? path : "";
}

// Also what the language server bridge reads NSStrings with. The view lasts as long as the string's autorelease pool.
static std::string_view UTF8View(NSString *text)
{
    const char *bytes = text.UTF8String;
    return bytes ? std::string_view(bytes, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string_view();
}

static NSURL *TemporaryFolder(void)
{
    std::string path = RunPath([NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"RetinaCode-XXXXXX"]]);
    return mkdtemp(path.data()) ? RunURL(path, YES) : nil;
}

@interface DebugExecutable ()
@property(nonatomic) NSURL *scratch;
@end

@implementation DebugExecutable

- (instancetype)initWithFile:(NSURL *)file directory:(NSURL *)directory
{
    return [self initWithFile:file directory:directory backend:DebugBackend::LLDB interpreter:nil];
}

- (instancetype)initWithFile:(NSURL *)file directory:(NSURL *)directory backend:(DebugBackend)backend interpreter:(NSString *)interpreter
{
    self = [super init];
    if (self) {
        _file = file;
        _directory = directory;
        _backend = backend;
        _interpreter = interpreter;
    }

    return self;
}

- (void)dealloc
{
    if (NSURL *scratch = _scratch) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NSFileManager.defaultManager removeItemAtURL:scratch error:nil];
        });
    }
}

@end

// The folder a window's Rust checks share, so cargo's target folder in it stays warm from one check to the next.
@interface RustCheckCache ()
- (NSURL *)directory;
- (void)removeFiles;
@end

static NSHashTable<RustCheckCache *> *checkCaches;

@implementation RustCheckCache {
    NSURL *_directory;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        if (!checkCaches)
            checkCaches = [NSHashTable weakObjectsHashTable];
        [checkCaches addObject:self];
    }
    return self;
}

- (NSURL *)directory
{
    if (!_directory)
        _directory = TemporaryFolder();
    return _directory;
}

- (void)removeFiles
{
    if (_directory) {
        [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
        _directory = nil;
    }
}

- (void)dealloc
{
    if (NSURL *directory = _directory) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        });
    }
}

@end

//
// Run.cpp's questions, in AppKit's terms.
//

RunProject LocateRunProject(Language language, NSURL *file, NSURL *folder)
{
    static const RunKind kinds[] = {RunKind::Source, RunKind::Script, RunKind::NativeProject, RunKind::Cargo, RunKind::GoModule,
                                    RunKind::SwiftPackage, RunKind::DotNet, RunKind::OdinPackage};
    Project project = locate_project(language, RunPath(CanonicalFileURL(file)), RunPath(CanonicalFileURL(folder)));
    return {kinds[project.kind], RunURL(project.folder, YES), RunURL(project.manifest, NO)};
}

NSURL *ParentManifest(NSURL *directory, NSURL *limit, NSString *name)
{
    return RunURL(find_parent_file(RunPath(directory), RunPath(limit), UTF8View(name)), NO);
}

bool RunnableLanguage(Language language)
{
    return runnable_language(language);
}

bool CheckableLanguage(Language language)
{
    return checkable_language(language);
}

bool DebuggableLanguage(Language language, NSURL *file)
{
    return debuggable_language(language, RunPath(file));
}

NSString *FindTool(NSString *name, Language language)
{
    std::string path = find_tool(UTF8View(name), language, nullptr);
    return path.empty() ? nil : [NSFileManager.defaultManager stringWithFileSystemRepresentation:path.data() length:path.size()];
}

//
// Jobs.
//

// A job and what the main thread keeps for it, which live and die together.
struct RunTask {
    RunJob job;
    ProgramInput input;            // what the output pane typed for the program, which RunChild writes to its terminal
    RunOutput output;              // where its lines go, on the main thread; none for a check, whose lines stay in its log
    void (^ready)(void);           // told when the program's input opens
    NSURL *file;                   // the tab's file, where lines about the file that ran link
    RunLog taken;                  // the lines taken from the job last, kept for their buffers
    bool input_open;
};

static RunMessage RunMessageFor(const RunLog &log, const RunLine &line, NSURL *file)
{
    std::string_view text = log.text;
    RunMessage message{RunString(text.substr(line.text_start, line.text_length)), line.tone, {}};
    message.usesTerminalColors = line.colored;
    message.colorSpans.assign(log.spans.begin() + line.spans_start, log.spans.begin() + line.spans_start + line.span_count);
    if (line.line) {
        NSURL *place = line.current_source ? file : RunURL(std::string(text.substr(line.file_start, line.file_length)), NO);
        message.location = {place, line.line, line.column, line.first_column, line.end_column, line.current_source,
                            line.columns == RUN_COLUMN_BYTES, line.columns == RUN_COLUMN_UTF16};
        if (line.link_length)
            message.linkRange = NSMakeRange(line.link_start, line.link_length);
    }
    if (line.diagnostic_length)
        message.diagnostic = RunString(text.substr(line.diagnostic_start, line.diagnostic_length));
    if (line.label_length)
        message.diagnosticLabel = RunString(text.substr(line.label_start, line.label_length));
    return message;
}

static std::vector<RunMessage> RunMessagesFor(const RunLog &log, NSURL *file)
{
    std::vector<RunMessage> messages;
    messages.reserve(log.messages.size());
    for (const RunLine &line : log.messages)
        messages.push_back(RunMessageFor(log, line, file));
    if (!messages.empty())
        messages.front().earlierOutputDiscarded = log.discarded;
    return messages;
}

// On the main thread: the lines the job wrote since the last time, and its input as the job has it now.
static void DeliverRunOutput(void *context)
{
    RunTask &task = *static_cast<RunTask *>(context);
    @autoreleasepool {
        take_run_log(task.job, task.taken);
        if (task.taken.input_open != task.input_open) {
            task.input_open = task.taken.input_open;
            SetProgramInput(task.input, task.input_open);
            if (task.input_open && task.ready)
                task.ready();
        }
        if (!task.taken.messages.empty())
            task.output(RunMessagesFor(task.taken, task.file));
    }
    task.taken.text.clear();
    task.taken.spans.clear();
    task.taken.messages.clear();
}

void notify_run_output(RunJob &job)
{
    RunTask *task = static_cast<RunTask *>(job.frontend);
    if (task->output)
        dispatch_async_f(dispatch_get_main_queue(), task, DeliverRunOutput);
}

static void ReadChild(void *context, ChildEvent event, std::string_view bytes)
{
    RunJob &job = *static_cast<RunJob *>(context);
    if (event == ChildEvent::Started)
        child_started(job);
    else if (event == ChildEvent::Output)
        child_output(job, 0, bytes);
    else if (event == ChildEvent::ErrorOutput)
        child_output(job, 1, bytes);
    else if (event == ChildEvent::Idle)
        child_idle(job);
}

// Runs a child with ChildProcess.cpp. The program reads the output pane's typing through a terminal of its own, so
// what it writes comes a line at a time.
int run_child(RunJob &job, const ChildCommand &child)
{
    std::string program(child.program);
    std::string arguments(child.arguments);
    std::string folder(child.folder);
    std::vector<const char *> argv = {program.c_str()};
    for (size_t at = 0; at < arguments.size(); at = arguments.find('\0', at) + 1)
        argv.push_back(arguments.data() + at);
    argv.push_back(nullptr);

    RunTask &task = *static_cast<RunTask *>(job.frontend);
    ProgramInput *input = child.kind == CHILD_PROGRAM ? &task.input : nullptr;
    ChildResult result = RunChild(argv.data(), folder.c_str(), job.stop, input, ReadChild, &job);
    if (result.startError) {
        std::string text = std::string(program.substr(program.rfind('/') + 1)) + ": " + strerror(result.startError) + "\n";
        log_status(job, text, OutputTone::Error);
        return CHILD_NOT_STARTED;
    }
    if (result.ioError)
        log_status(job, std::string(strerror(result.ioError)) + "\n", OutputTone::Error);
    return result.code;
}

// Live runs, which quitting stops and waits for, including runs whose tabs have closed.
static NSMutableSet<SourceRunner *> *activeRunners;
static dispatch_group_t activeRuns;
static bool stoppingRunsForQuit;

bool StopSourceRunsForQuit(dispatch_block_t finished)
{
    stoppingRunsForQuit = true;
    NSArray<RustCheckCache *> *caches = checkCaches.allObjects;
    bool running = activeRuns && dispatch_group_wait(activeRuns, DISPATCH_TIME_NOW) != 0;
    if (!running && !caches.count)
        return false;

    for (SourceRunner *runner in activeRunners)
        [runner stop];
    dispatch_block_t cleanup = ^{
        for (RustCheckCache *cache in caches)
            [cache removeFiles];
        finished();
    };
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    if (running)
        dispatch_group_notify(activeRuns, queue, cleanup);
    else
        dispatch_async(queue, cleanup);
    return true;
}

@implementation SourceRunner {
    RunTask *_task;                // the job going on, until it ends
    std::atomic_bool _stopped;
}

// Makes the job for a file and its project. The project's folder is the workspace the job looks up to, which
// finds the same project again.
- (RunTask *)taskFor:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name output:(RunOutput)output
{
    RunTask *task = new RunTask();
    task->output = output;
    task->ready = self.inputReady;
    task->file = file;
    RunJob &job = task->job;
    job.language = language;
    job.file = RunPath(CanonicalFileURL(file));
    job.name = std::string(UTF8View(name));
    job.workspace = RunPath(CanonicalFileURL(project.folder));
    job.frontend = task;
    job.stop = _stopped.load(std::memory_order_relaxed);
    return task;
}

// Runs the job on a queue, then hands it to finish on the main thread with its last lines shown, and ends it.
- (void)start:(RunTask *)task work:(void (*)(RunJob &))work qos:(qos_class_t)qos finish:(void (^)(RunTask *))finish
{
    if (stoppingRunsForQuit) {
        [self stop];
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(nullptr);
            delete task;
        });
        return;
    }
    if (!activeRuns) {
        activeRuns = dispatch_group_create();
        activeRunners = [[NSMutableSet alloc] init];
    }
    [activeRunners addObject:self];
    _task = task;
    dispatch_group_async(activeRuns, dispatch_get_global_queue(qos, 0), ^{
        work(task->job);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task->output)
                DeliverRunOutput(task);
            if (self->_task == task)
                self->_task = nullptr;
            [activeRunners removeObject:self];
            finish(task);
            delete task;
        });
    });
}

- (void)startProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
         workingText:(NSString *)text output:(RunOutput)output finished:(void (^)(void))finished
{
    RunTask *task = [self taskFor:project language:language file:file name:name output:output];
    if (text) {
        task->job.draft = std::string(UTF8View(text));
        task->job.has_draft = true;
    }
    [self start:task work:run_job qos:QOS_CLASS_USER_INITIATED finish:^(RunTask *) { finished(); }];
}

- (void)checkProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
             sources:(std::vector<CheckSource>)sources cache:(RustCheckCache *)cache finished:(CheckFinished)finished
{
    RunTask *task = [self taskFor:project language:language file:file name:name output:nil];
    RunJob &job = task->job;
    for (const CheckSource &source : sources)
        job.drafts.push_back({RunPath(CanonicalFileURL(source.file)), std::string(UTF8View(source.text)), source.saved});
    if (language == Language::Rust)
        job.cache = RunPath(cache.directory);
    [self start:task work:check_job qos:QOS_CLASS_UTILITY finish:^(RunTask *done) {
        if (!done || self.isStopped) {
            finished({});
            return;
        }
        finished({RunMessagesFor(done->job.log, done->file), done->job.errors, done->job.warnings});
    }];
}

- (void)buildDebugProject:(RunProject)project language:(Language)language file:(NSURL *)file
                   output:(RunOutput)output finished:(void (^)(DebugExecutable *))finished
{
    RunTask *task = [self taskFor:project language:language file:file name:file.lastPathComponent output:output];
    [self start:task work:debug_build_job qos:QOS_CLASS_USER_INITIATED finish:^(RunTask *done) {
        RunJob *job = done ? &done->job : nullptr;
        if (!job || job->debug_program.empty()) {
            finished(nil);
            return;
        }
        DebugBackend backend = job->debug_adapter == DEBUG_SBCL ? DebugBackend::SBCL : job->debug_adapter == DEBUG_PYTHON ? DebugBackend::Debugpy :
                               DebugBackend::LLDB;
        NSString *interpreter = job->debug_interpreter.empty() ? nil : RunString(job->debug_interpreter);
        DebugExecutable *executable = [[DebugExecutable alloc] initWithFile:RunURL(job->debug_program, NO) directory:RunURL(job->debug_folder, YES)
                                                                    backend:backend interpreter:interpreter];
        if (job->keep_temporary)
            executable.scratch = RunURL(job->temporary, YES);
        finished(executable);
    }];
}

- (BOOL)isStopped { return _stopped.load(std::memory_order_relaxed); }

- (void)stop
{
    _stopped.store(true, std::memory_order_relaxed);
    if (_task) {
        _task->job.stop = true;
        SetProgramInput(_task->input, false);
    }
}

- (BOOL)sendInput:(NSString *)text
{
    return _task && QueueProgramInput(_task->input, UTF8View(text));
}

@end
