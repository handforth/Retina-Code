#import "Runner.h"
#include "ChildProcess.hpp"
#include "../RunTools.hpp"
#import "Preferences.h"
#import "Workspace.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <optional>
#include <mutex>
#include <string>

#include <fcntl.h>
#include <unistd.h>

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

static bool ExistingFile(NSURL *url)
{
    NSNumber *regular = nil;
    return [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] && regular.boolValue;
}

static std::string_view FileSystemPath(NSURL *url)
{
    const char *path = url.fileSystemRepresentation;
    return path ? std::string_view(path) : std::string_view{};
}

NSURL *ParentManifest(NSURL *directory, NSURL *limit, NSString *name)
{
    std::string path;
    const char *basename = name.fileSystemRepresentation;
    if (!basename || !FindParentFile(path, FileSystemPath(directory), FileSystemPath(limit), basename))
        return nil;

    return [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:NO relativeToURL:nil];
}

static NSURL *DotNetProject(NSURL *directory, NSURL *limit, NSString *extension)
{
    NSFileManager *files = NSFileManager.defaultManager;
    while (directory.path.length) {
        NSArray<NSURL *> *items = [files contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        NSURL *match = nil;
        for (NSURL *file in items) {
            if (![file.pathExtension.lowercaseString isEqualToString:extension] || !ExistingFile(file))
                continue;
            if (match)
                return nil;
            match = file;
        }
        if (match)
            return match;
        if ([directory.path isEqualToString:limit.path] || [directory.path isEqualToString:@"/"])
            break;
        directory = directory.URLByDeletingLastPathComponent;
    }
    return nil;
}

RunProject LocateRunProject(Language language, NSURL *file, NSURL *folder)
{
    file = CanonicalFileURL(file);
    folder = CanonicalFileURL(folder);
    if (file && !PathIsInFolder(file.path, folder.path))
        folder = nil;
    NSURL *directory = file ? file.URLByDeletingLastPathComponent : folder;
    NSURL *limit = folder;

    bool workspaceOnly = language == Language::Plain && !file && folder;
    if (language == Language::Rust || workspaceOnly) {
        if (NSURL *manifest = ParentManifest(directory, limit, @"Cargo.toml"))
            return {RunKind::Cargo, folder ? folder : manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (language == Language::Go || workspaceOnly) {
        if (NSURL *manifest = ParentManifest(directory, limit, @"go.mod"))
            return {RunKind::GoModule, manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (language == Language::Swift || workspaceOnly) {
        if (NSURL *manifest = ParentManifest(directory, limit, @"Package.swift"))
            return {RunKind::SwiftPackage, manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (language == Language::Odin) {
        if ([file.pathExtension isEqualToString:@"odin"])
            return {RunKind::OdinPackage, folder ? folder : directory};
        return {};
    }
    NSString *projectExtension = nil;
    if (language == Language::CSharp && ![file.pathExtension.lowercaseString isEqualToString:@"csx"])
        projectExtension = @"csproj";
    else if (language == Language::FSharp && ![file.pathExtension.lowercaseString isEqualToString:@"fsx"])
        projectExtension = @"fsproj";
    else if (language == Language::VisualBasic && [file.pathExtension.lowercaseString isEqualToString:@"vb"])
        projectExtension = @"vbproj";
    if (file && projectExtension.length) {
        if (NSURL *manifest = DotNetProject(directory, limit, projectExtension))
            return {RunKind::DotNet, manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (folder && (is_c_family(language) || (language == Language::Plain && !file)))
        return {RunKind::NativeProject, folder};
    if (folder && file && RunnableLanguage(language))
        return {RunKind::Script, folder};
    return {};
}

static Language TranslationUnit(NSURL *file)
{
    NSString *ext = file.pathExtension;
    if ([ext isEqualToString:@"C"])
        return Language::Cpp;
    if ([ext isEqualToString:@"M"])
        return Language::ObjectiveCpp;
    ext = ext.lowercaseString;
    if ([ext isEqualToString:@"c"])
        return Language::C;
    if ([@[@"cc", @"cpp", @"cxx", @"c++", @"cp"] containsObject:ext])
        return Language::Cpp;
    if ([ext isEqualToString:@"m"])
        return Language::ObjectiveC;
    if ([ext isEqualToString:@"mm"])
        return Language::ObjectiveCpp;
    return Language::Plain;
}

static bool DefinesMain(NSURL *file, Language language)
{
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
    if ([text rangeOfString:@"main" options:NSLiteralSearch].location == NSNotFound || !text.length)
        return false;
    enum class Stage { Name, Open, Parameters, Body };
    Stage stage = Stage::Name;
    unsigned braces = 0, parameters = 0;
    LexState state;
    std::u16string row;
    std::vector<Token> tokens;
    for (NSUInteger start = 0; start < text.length;) {
        NSUInteger end, content;
        [text getLineStart:nullptr end:&end contentsEnd:&content forRange:NSMakeRange(start, 0)];
        row.resize(content - start);
        [text getCharacters:reinterpret_cast<unichar *>(row.data()) range:NSMakeRange(start, row.size())];
        start = end;
        tokenize_line(row, language, state, tokens);
        if (!tokens.empty() && tokens.front().ink == Ink::Directive)
            continue;
        size_t token = 0;
        for (size_t i = 0; i < row.size();) {
            while (token < tokens.size() && tokens[token].start + tokens[token].length <= i)
                ++token;
            if (token < tokens.size() && tokens[token].start == i &&
                (tokens[token].ink == Ink::Comment || tokens[token].ink == Ink::String || tokens[token].ink == Ink::Escape)) {
                i += tokens[token].length;
                continue;
            }
            char16_t unit = row[i++];
            if (unit == u' ' || unit == u'\t' || unit == u'\v' || unit == u'\f')
                continue;
            if (stage == Stage::Open) {
                if (unit == u'(') {
                    stage = Stage::Parameters;
                    parameters = 1;
                    continue;
                }
                stage = Stage::Name;
            } else if (stage == Stage::Parameters) {
                if (unit == u'(')
                    ++parameters;
                if (unit == u')' && --parameters == 0)
                    stage = Stage::Body;
                continue;
            } else if (stage == Stage::Body) {
                if (unit == u'{')
                    return true;
                if (unit == u';' || unit == u'=')
                    stage = Stage::Name;
                continue;
            }
            if (unit == u'{') {
                ++braces;
            } else if (unit == u'}') {
                if (braces)
                    --braces;
            } else if (is_ascii_identifier_start(unit)) {
                size_t first = i - 1;
                while (i < row.size() && is_ascii_identifier_char(row[i]))
                    ++i;
                if (!braces && std::u16string_view(row).substr(first, i - first) == u"main")
                    stage = Stage::Open;
            }
        }
    }
    return false;
}

struct SourceUnit {
    NSURL *url;
    Language language;
    bool main;
};

static bool SkipSourceDirectory(NSString *name)
{
    static NSSet<NSString *> *excluded = [NSSet setWithArray:
        @[@"build", @"target", @"vendor", @"third_party", @"node_modules", @"test", @"tests", @"examples"]];
    return [name hasPrefix:@"."] || [excluded containsObject:name];
}

static std::vector<SourceUnit> ReadSourceUnits(NSURL *directory, bool recursive, const std::atomic_bool &stop)
{
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey];
    auto options = NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants;
    if (!recursive)
        options |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
    NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:directory
        includingPropertiesForKeys:keys options:NSDirectoryEnumerationOptions(options) errorHandler:nil];
    std::vector<SourceUnit> result;
    for (NSURL *url in entries) {
        if (stop.load(std::memory_order_relaxed))
            return {};
        @autoreleasepool {
            NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
            if ([values[NSURLIsSymbolicLinkKey] boolValue] ||
                ([values[NSURLIsDirectoryKey] boolValue] && SkipSourceDirectory(url.lastPathComponent))) {
                [entries skipDescendants];
                continue;
            }
            Language language = TranslationUnit(url);
            if (language != Language::Plain && [values[NSURLIsRegularFileKey] boolValue])
                result.push_back({url.URLByStandardizingPath, language, DefinesMain(url, language)});
        }
    }
    std::sort(result.begin(), result.end(), [](const SourceUnit &a, const SourceUnit &b) {
        return [a.url.path compare:b.url.path options:NSLiteralSearch] == NSOrderedAscending;
    });
    return result;
}

struct NativeSources {
    std::vector<SourceUnit> files;
    NSURL *directory = nil;
    NSString *error = nil;
};

static NativeSources CollectProgram(const std::vector<SourceUnit> &units, const SourceUnit &entry, NSURL *directory)
{
    NativeSources result;
    result.directory = directory;
    result.files.push_back(entry);
    for (const auto &unit : units) {
        if (&unit != &entry && !unit.main)
            result.files.push_back(unit);
    }
    return result;
}

static NativeSources SelectNativeSources(NSURL *folder, NSURL *file, const std::atomic_bool &stop)
{
    NSURL *src = [folder URLByAppendingPathComponent:@"src" isDirectory:YES];
    NSURL *active = file.URLByDeletingLastPathComponent;
    if (PathIsInFolder(active.path, src.path)) {
        bool included = true;
        NSArray<NSString *> *parts = active.path.pathComponents;
        for (NSUInteger depth = src.path.pathComponents.count; depth < parts.count; ++depth)
            included &= !SkipSourceDirectory(parts[depth]);
        if (included)
            active = src;
    }
    NSMutableOrderedSet<NSURL *> *directories = [[NSMutableOrderedSet alloc] init];
    if (active && ![active.path isEqualToString:folder.path])
        [directories addObject:active];
    if (active && [active.path isEqualToString:folder.path] && TranslationUnit(file) != Language::Plain)
        [directories addObject:folder];
    [directories addObject:src];
    [directories addObject:folder];
    NSString *uncertain = nil;
    NativeSources fallback;
    for (NSURL *directory in directories) {
        BOOL exists = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:directory.path isDirectory:&exists] || !exists)
            continue;
        bool sourceTree = [directory.path isEqualToString:src.path];
        auto units = ReadSourceUnits(directory, sourceTree, stop);
        if (units.empty())
            continue;
        auto focused = std::find_if(units.begin(), units.end(), [&](const SourceUnit &unit) {
            return [unit.url.path isEqualToString:file.path];
        });
        auto entry = units.end();
        if (focused != units.end() && focused->main) {
            entry = focused;
        } else {
            unsigned mains = 0;
            for (auto it = units.begin(); it != units.end(); ++it) {
                if (it->main) {
                    ++mains;
                    entry = it;
                }
            }
            if (mains > 1) {
                auto named = std::find_if(units.begin(), units.end(), [](const SourceUnit &unit) {
                    return unit.main && [unit.url.lastPathComponent.stringByDeletingPathExtension isEqualToString:@"main"];
                });
                if (named == units.end() ||
                    std::any_of(named + 1, units.end(), [](const SourceUnit &unit) {
                        return unit.main && [unit.url.lastPathComponent.stringByDeletingPathExtension isEqualToString:@"main"];
                    })) {
                    uncertain = @"More than one program was found. Open the main source file you want to run.\n";
                    continue;
                }
                entry = named;
            }
        }
        if (entry == units.end()) {
            entry = std::find_if(units.begin(), units.end(), [](const SourceUnit &unit) {
                return [unit.url.lastPathComponent.stringByDeletingPathExtension isEqualToString:@"main"];
            });
        }
        if (entry == units.end()) {
            if (focused != units.end() && fallback.files.empty())
                fallback = CollectProgram(units, *focused, directory);
            continue;
        }

        NativeSources result = CollectProgram(units, *entry, directory);
        if ([directory.path isEqualToString:folder.path] && ![directories.firstObject.path isEqualToString:src.path]) {
            for (const auto &unit : ReadSourceUnits(src, true, stop)) {
                if (!unit.main)
                    result.files.push_back(unit);
            }
        }
        return result;
    }
    if (!fallback.files.empty())
        return fallback;
    return {{}, nil, uncertain ? uncertain : @"Open a C or C++ source file with a main() in this folder, or open a runnable script.\n"};
}

struct RunTools {
    NSString *tool = nil;
    NSString *suffix = nil;
    NSString *check = nil;
};

static RunTools ToolsForRun(Language language)
{
    const auto tool = ToolForRun(language);
    return {tool.tool ? @(tool.tool) : nil, tool.suffix ? @(tool.suffix) : nil, tool.check ? @(tool.check) : nil};
}

static NSString *ToolName(Language language)
{
    return ToolsForRun(language).tool;
}

bool RunnableLanguage(Language language)
{
    return ToolName(language) != nil;
}

bool DebuggableLanguage(Language language, NSURL *file)
{
    return is_c_family(language) || language == Language::Rust || language == Language::Swift ||
           language == Language::Go || language == Language::Odin || language == Language::Zig ||
           language == Language::CommonLisp || language == Language::Python ||
           (language == Language::Assembly && [file.pathExtension.lowercaseString isEqualToString:@"s"]);
}

static NSString *SourceSuffix(Language language, NSURL *file)
{
    switch (language) {
    case Language::Assembly:
        if ([file.pathExtension isEqualToString:@"S"])
            return @".S";
        break;
    case Language::JavaScript: case Language::TypeScript: {
        NSString *extension = file.pathExtension.lowercaseString;
        if (language == Language::JavaScript ? [extension isEqualToString:@"mjs"] || [extension isEqualToString:@"cjs"] :
                                              [extension isEqualToString:@"mts"] || [extension isEqualToString:@"cts"])
            return [@"." stringByAppendingString:extension];
        break;
    }
    case Language::CSharp:
        if ([file.pathExtension.lowercaseString isEqualToString:@"csx"])
            return @".csx";
        break;
    case Language::Kotlin:
        if ([file.pathExtension.lowercaseString isEqualToString:@"kts"])
            return @".kts";
        break;
    case Language::Scala:
        if ([file.pathExtension.lowercaseString isEqualToString:@"sc"])
            return @".sc";
        break;
    default: break;
    }

    NSString *suffix = ToolsForRun(language).suffix;
    return suffix ? suffix : @"";
}

static NSString *ExecutableAt(NSString *folder, NSString *name)
{
    const char *directory = folder.fileSystemRepresentation;
    std::string path;
    const char *basename = name.fileSystemRepresentation;
    if (!directory || !basename || !ExecutableIn(path, directory, basename))
        return nil;

    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:path.data() length:path.size()];
}

NSString *FindTool(NSString *name, Language language)
{
    std::string path;
    const char *basename = name.fileSystemRepresentation;
    if (!basename)
        return nil;

    const char *search = getenv("PATH");
    std::string_view command = basename;
    if (ExecutableOnPath(path, search ? search : "", command))
        return [NSFileManager.defaultManager stringWithFileSystemRepresentation:path.data() length:path.size()];

    if (language == Language::Go)
        return ExecutableAt(@"/usr/local/go/bin", name);
    if (language == Language::Rust)
        return ExecutableAt([NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin"], name);
    if (language == Language::Odin) {
        if (const char *root = getenv("ODIN_ROOT")) {
            if (ExecutableIn(path, root, command))
                return [NSFileManager.defaultManager stringWithFileSystemRepresentation:path.data() length:path.size()];
        }

        for (NSString *folder in @[@"opt/odin", @".local/bin", @"bin"]) {
            if (NSString *tool = ExecutableAt([NSHomeDirectory() stringByAppendingPathComponent:folder], name))
                return tool;
        }
    }
    if (language == Language::VisualBasic || language == Language::CSharp || language == Language::FSharp) {
        if (NSString *tool = ExecutableAt([NSHomeDirectory() stringByAppendingPathComponent:@".dotnet"], name))
            return tool;
        if (NSString *tool = ExecutableAt(@"/usr/local/share/dotnet", name))
            return tool;
        return ExecutableAt(@"/Library/Frameworks/Mono.framework/Versions/Current/Commands", name);
    }
    return nil;
}

static NSString *FindTSX(NSURL *directory, NSURL *folder)
{
    while (directory.path.length) {
        if (NSString *tool = ExecutableAt([directory.path stringByAppendingPathComponent:@"node_modules/.bin"], @"tsx"))
            return tool;
        if ([directory.path isEqualToString:folder.path] || [directory.path isEqualToString:@"/"])
            break;
        directory = directory.URLByDeletingLastPathComponent;
    }
    return FindTool(@"tsx", Language::TypeScript);
}

static NSString *FindPython(NSURL *folder)
{
    for (NSString *environment : {@".venv/bin", @"venv/bin"}) {
        if (NSString *tool = ExecutableAt([folder.path stringByAppendingPathComponent:environment], @"python"))
            return tool;
    }

    return nil;
}

static NSError *RunError(int code)
{
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

struct RunFiles {
    NSURL *folder = nil;
    NSURL *sibling = nil;

    ~RunFiles()
    {
        NSFileManager *files = NSFileManager.defaultManager;
        if (sibling)
            [files removeItemAtURL:sibling error:nil];
        if (folder)
            [files removeItemAtURL:folder error:nil];
    }
};

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

static NSURL *TemporaryFolder(NSError **error)
{
    NSString *name = [NSTemporaryDirectory() stringByAppendingPathComponent:@"RetinaCode-XXXXXX"];
    std::string path(name.fileSystemRepresentation);
    if (mkdtemp(path.data()))
        return [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:YES relativeToURL:nil];
    *error = RunError(errno);
    return nil;
}

@interface RustCheckCache ()
- (NSURL *)directoryWithError:(NSError **)error;
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

- (NSURL *)directoryWithError:(NSError **)error
{
    if (!_directory)
        _directory = TemporaryFolder(error);
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

static NSURL *WriteRunSource(RunFiles &files, NSData *contents, NSURL *directory, NSString *suffix, NSError **error)
{
    // A sibling keeps quoted includes, Rust modules, and script imports relative to the original file.
    if (directory) {
        NSString *name = [@".retina-code-XXXXXX" stringByAppendingString:suffix];
        NSString *pattern = [directory.path stringByAppendingPathComponent:name];
        std::string path(pattern.fileSystemRepresentation);
        int fd = mkstemps(path.data(), int(suffix.length));
        if (fd >= 0) {
            files.sibling = [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:NO relativeToURL:nil];
            NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
            if ([handle writeData:contents error:error] && [handle closeAndReturnError:error])
                return files.sibling;
            return nil;
        }
    }
    NSURL *source = [files.folder URLByAppendingPathComponent:[@"main" stringByAppendingString:suffix]];
    return [contents writeToURL:source options:0 error:error] ? source : nil;
}

static NSString *ConsoleString(std::string_view bytes)
{
    NSString *text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
    if (!text)
        text = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
    return text;
}

static std::string_view UTF8View(NSString *text)
{
    const char *bytes = text.UTF8String;
    return bytes ? std::string_view(bytes, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string_view{};
}

static RunMessage DecodeConsoleString(NSString *source)
{
    TerminalDecoder decoder{};
    DecodedOutput output;
    DecodeTerminal(decoder, UTF8View(source), output);
    RunMessage message{};
    message.text = ConsoleString(output.text);
    message.colorSpans = std::move(output.spans);
    message.usesTerminalColors = decoder.sawSGR;
    return message;
}

static void ReplaceOutputText(RunMessage &message, NSRange range, NSString *replacement)
{
    ShiftOutputColors(message.colorSpans, {uint32_t(range.location), uint32_t(range.length)},
                      uint32_t(replacement.length));
    message.text = [message.text stringByReplacingCharactersInRange:range withString:replacement];
}

struct DiagnosticContext {
    NSURL *input;
    NSURL *original;
    NSURL *directory;
    NSString *name;
    bool byteColumns;
    Language language = Language::C;
    NSURL *mirror = nil;
    bool runtimeLocations = false;
};

static NSURL *OriginalCheckFile(NSURL *file, NSURL *mirror)
{
    if (PathIsInFolder(file.path, mirror.path) && file.path.length > mirror.path.length)
        file = [NSURL fileURLWithPath:[file.path substringFromIndex:mirror.path.length]];
    return CanonicalFileURL(file);
}

static RunMessage CompilerMessage(RunMessage message, std::string_view text, const DiagnosticContext &context, bool stderrLine)
{
    CompilerFormat format = CompilerFormat::Standard;
    if (context.language == Language::Go)
        format = CompilerFormat::Go;
    else if (context.language == Language::CSharp || context.language == Language::FSharp || context.language == Language::VisualBasic)
        format = CompilerFormat::Parenthesized;
    else if (context.language == Language::Kotlin)
        format = CompilerFormat::Kotlin;

    CompilerLocation match;
    bool runtime = context.runtimeLocations && stderrLine && ParseRuntimeLocation(text, context.language == Language::Python, match);
    if (!runtime && !ParseCompilerLocation(text, format, match))
        return message;

    if (!runtime)
        message.tone = match.tone;

    if (match.path.starts_with('<'))
        return message;

    NSString *path = ConsoleString(match.path);
    NSURL *url = [path hasPrefix:@"file://"] ? [NSURL URLWithString:path] :
        [NSURL fileURLWithPath:path isDirectory:NO relativeToURL:context.directory].URLByStandardizingPath;
    if (!url.isFileURL)
        return message;
    if (context.mirror)
        url = OriginalCheckFile(url, context.mirror);

    bool current = [url isEqual:context.input.URLByStandardizingPath] ||
                   [url.URLByResolvingSymlinksInPath isEqual:context.input.URLByResolvingSymlinksInPath];
    message.location = {current ? context.original : url, match.line, match.column,
                        match.firstColumn, match.endColumn, current, context.byteColumns,
                        runtime && is_javascript_family(context.language)};
    if (runtime) {
        NSRange range = [message.text rangeOfString:path options:NSLiteralSearch];
        if (range.location != NSNotFound) {
            if (current && context.name.length && ![path isEqualToString:context.name]) {
                ReplaceOutputText(message, range, context.name);
                range.length = context.name.length;
            }

            NSUInteger end = range.location;
            [message.text getLineStart:nullptr end:nullptr contentsEnd:&end forRange:NSMakeRange(range.location, 0)];
            message.linkRange = NSMakeRange(range.location, end - range.location);
        }
        return message;
    }

    NSString *label = current && context.name.length ? context.name : context.mirror ? url.path : path;
    NSMutableString *display = [NSMutableString stringWithFormat:@"%@:%lu", label, (unsigned long)match.line];
    if (match.column)
        [display appendFormat:@":%lu", (unsigned long)match.column];

    NSString *details = ConsoleString(text.substr(match.details));
    size_t prefix = message.text.length - details.length;
    if (match.addSeverity) {
        NSString *severity = match.tone == OutputTone::Warning ? @"warning" : match.tone == OutputTone::Text ? @"note" : @"error";
        details = [NSString stringWithFormat:@"%@: %@", severity, details];
        [display appendFormat:@": %@: ", severity];
    } else {
        [display appendString:@": "];
    }

    ReplaceOutputText(message, NSMakeRange(0, prefix), display);
    if (message.tone != OutputTone::Text) {
        message.diagnostic = [details stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (is_c_family(context.language) && [message.diagnostic hasSuffix:@"]"]) {
            NSRange option = [message.diagnostic rangeOfString:@"[-W" options:NSBackwardsSearch];
            if (option.location != NSNotFound) {
                NSUInteger start = option.location + 1;
                NSString *flag = [message.diagnostic substringWithRange:NSMakeRange(start, message.diagnostic.length - start - 1)];
                message.diagnosticLabel = [NSString stringWithFormat:@"clang(%@)", flag];
            }
        }
    }

    return message;
}

struct RunDelivery {
    std::mutex mutex;
    std::vector<RunMessage> ready, spare;
    bool scheduled = false;
    bool delivering = false;
};

struct RunLog {
    SourceRunner *owner = nil;
    RunDelivery *delivery = nullptr;
    RunOutput output;
    std::vector<RunMessage> messages;
    std::vector<NSUInteger> seenDiagnostics;
    Clock::time_point nextUpdate{};
    NSUInteger lineLimit = OutputScrollbackLinesPreference();
    NSUInteger characterLimit = OutputScrollbackCharacterLimit(lineLimit);
    NSUInteger characters = 0;
    size_t first = 0;
    int programExitCode = -1;
    bool buildError = false;
    bool discarded = false;
    bool checking = false;
    bool locatedOnly = false;
    NSUInteger errors = 0;
    NSUInteger warnings = 0;
};

static void LogAppend(RunLog &log, RunMessage message)
{
    NSUInteger length = message.text.length;
    if (!length)
        return;

    if (log.checking) {
        if (message.tone == OutputTone::Text || (log.locatedOnly && !message.location.line))
            return;

        auto &seen = log.seenDiagnostics;
        if (seen.size() < outputScrollbackLines) {
            NSUInteger key = message.text.hash ^ (message.location.file.path.hash << 1);
            auto position = std::lower_bound(seen.begin(), seen.end(), key);
            if (position != seen.end() && *position == key)
                return;

            seen.insert(position, key);
        }

        if (message.tone == OutputTone::Error)
            ++log.errors;
        else
            ++log.warnings;
    }

    auto &messages = log.messages;
    if (length > log.characterLimit) {
        NSUInteger start = length - log.characterLimit;
        if (CFStringIsSurrogateLowCharacter([message.text characterAtIndex:start]) &&
            CFStringIsSurrogateHighCharacter([message.text characterAtIndex:start - 1]))
            ++start;

        ReplaceOutputText(message, NSMakeRange(0, start), @"");
        if (message.linkRange.location != NSNotFound) {
            if (message.linkRange.location < start)
                message.linkRange = {};
            else
                message.linkRange.location -= start;
        }

        length = message.text.length;
        messages.clear();
        log.first = 0;
        log.characters = 0;
        log.discarded = true;
    }

    if (message.diagnostic.length > 2048) {
        NSUInteger end = CFStringIsSurrogateHighCharacter([message.diagnostic characterAtIndex:2047]) ? 2047 : 2048;
        message.diagnostic = [[message.diagnostic substringToIndex:end] stringByAppendingString:@"…"];
    }

    messages.push_back(std::move(message));
    log.characters += length;
    NSUInteger limit = std::max(log.lineLimit, outputScrollbackLines);
    while (log.first < messages.size() && (log.characters > log.characterLimit || messages.size() - log.first > limit)) {
        auto &front = messages[log.first++];
        log.characters -= front.text.length;
        front = {};
        log.discarded = true;
    }

    if (log.first && log.first >= messages.size() / 2) {
        messages.erase(messages.begin(), messages.begin() + log.first);
        log.first = 0;
    }
}

static void LogStatus(RunLog &log, NSString *text, OutputTone tone = OutputTone::Text)
{
    LogAppend(log, {text, tone, {}});
}

static void SendLog(RunLog &log, bool now = false)
{
    auto time = Clock::now();
    if (!log.delivery || log.messages.empty() || (!now && time < log.nextUpdate && log.characters < 96 * 1024))
        return;

    RunDelivery *delivery = log.delivery;
    bool schedule = false;
    {
        std::lock_guard lock(delivery->mutex);
        if (!now && (delivery->scheduled || delivery->delivering))
            return;

        log.messages.erase(log.messages.begin(), log.messages.begin() + log.first);
        log.messages.front().earlierOutputDiscarded = log.discarded;
        if (delivery->ready.empty() || log.discarded) {
            delivery->ready.swap(log.messages);
        } else {
            delivery->ready.insert(delivery->ready.end(), std::make_move_iterator(log.messages.begin()), std::make_move_iterator(log.messages.end()));
        }

        log.messages.clear();
        if (delivery->spare.capacity() > log.messages.capacity())
            delivery->spare.swap(log.messages);

        schedule = !delivery->scheduled;
        delivery->scheduled = true;
    }

    log.first = 0;
    log.characters = 0;
    log.discarded = false;
    log.nextUpdate = time + 24ms;
    log.lineLimit = OutputScrollbackLinesPreference();
    log.characterLimit = OutputScrollbackCharacterLimit(log.lineLimit);
    if (!schedule)
        return;

    SourceRunner *owner = log.owner;
    RunOutput handler = log.output;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            (void)owner; // Keep the runner and its delivery buffers alive.
            std::vector<RunMessage> batch;
            {
                std::lock_guard lock(delivery->mutex);
                batch.swap(delivery->ready);
                delivery->scheduled = false;
                delivery->delivering = true;
            }

            if (handler)
                handler(batch);

            batch.clear();
            {
                std::lock_guard lock(delivery->mutex);
                if (batch.capacity() > delivery->spare.capacity())
                    delivery->spare.swap(batch);
                delivery->delivering = false;
            }
        }
    });
}

static NSDictionary *JSONDictionary(std::string_view bytes)
{
    if (bytes.empty() || bytes.front() != '{')
        return nil;
    NSData *data = [NSData dataWithBytesNoCopy:const_cast<char *>(bytes.data()) length:bytes.size() freeWhenDone:NO];
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static RunMessage RustDiagnostic(NSDictionary *message, const DiagnosticContext &context, NSString *manifest = nil)
{
    if (![message isKindOfClass:NSDictionary.class])
        return {};
    NSString *level = message[@"level"];
    NSString *details = message[@"message"];
    if (![level isKindOfClass:NSString.class] || ![details isKindOfClass:NSString.class])
        return {};
    OutputTone tone = [level isEqualToString:@"warning"] ? OutputTone::Warning :
                      [level isEqualToString:@"error"] || [level isEqualToString:@"failure-note"] ?
                      OutputTone::Error : OutputTone::Text;
    NSString *rendered = message[@"rendered"];
    RunMessage result{};
    if ([rendered isKindOfClass:NSString.class])
        result = DecodeConsoleString(rendered);
    rendered = result.text.length ? result.text : nil;
    if (!rendered) {
        result.text = [NSString stringWithFormat:@"%@: %@\n", level, details];
        result.usesTerminalColors = false;
    } else if (![rendered hasSuffix:@"\n"]) {
        rendered = result.text = [rendered stringByAppendingString:@"\n"];
    }
    result.tone = tone;
    if (tone != OutputTone::Text) {
        result.diagnostic = details;
        id code = message[@"code"];
        if ([code isKindOfClass:NSDictionary.class] && [code[@"code"] isKindOfClass:NSString.class])
            result.diagnosticLabel = [NSString stringWithFormat:@"rustc(%@)", code[@"code"]];
    }

    NSArray *spans = message[@"spans"];
    if (![spans isKindOfClass:NSArray.class])
        return result;
    NSDictionary *primary = nil;
    for (NSDictionary *span in spans) {
        if ([span isKindOfClass:NSDictionary.class] && [span[@"is_primary"] isEqual:@YES]) {
            primary = span;
            break;
        }
    }
    NSString *path = primary[@"file_name"];
    if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"<"])
        return result;

    NSURL *file = [NSURL fileURLWithPath:path isDirectory:NO relativeToURL:context.directory].URLByStandardizingPath;
    if (!path.isAbsolutePath && manifest.length && !ExistingFile(file)) {
        NSURL *package = [NSURL fileURLWithPath:manifest].URLByDeletingLastPathComponent;
        file = [NSURL fileURLWithPath:path isDirectory:NO relativeToURL:package].URLByStandardizingPath;
    }
    file = OriginalCheckFile(file, context.mirror);
    NSUInteger line = [primary[@"line_start"] unsignedIntegerValue];
    NSUInteger column = [primary[@"column_start"] unsignedIntegerValue];
    NSUInteger end = [primary[@"line_end"] unsignedIntegerValue] == line ? [primary[@"column_end"] unsignedIntegerValue] : 0;
    bool current = [file.path isEqualToString:OriginalCheckFile(context.input, context.mirror).path];
    result.location = {current ? context.original : file, line, column, end > column ? column : 0, end, current, false};
    NSString *label = current && context.name.length ? context.name : path;
    if (PathIsInFolder(label, context.mirror.path))
        label = file.path;
    NSString *position = [NSString stringWithFormat:@":%lu:%lu", (unsigned long)line, (unsigned long)column];
    if (!rendered) {
        NSString *reference = [label stringByAppendingString:position];
        result.linkRange = NSMakeRange(0, reference.length);
        result.text = [NSString stringWithFormat:@"%@: %@", reference, result.text];
        return result;
    }

    NSString *reference = [path stringByAppendingString:position];
    NSRange arrow = [rendered rangeOfString:[NSString stringWithFormat:@"--> %@\n", reference] options:NSLiteralSearch];
    if (arrow.location == NSNotFound)
        arrow = [rendered rangeOfString:[NSString stringWithFormat:@"::: %@\n", reference] options:NSLiteralSearch];
    if (arrow.location != NSNotFound) {
        NSUInteger start = arrow.location + 4;
        if (![label isEqualToString:path])
            ReplaceOutputText(result, NSMakeRange(start, path.length), label);
        result.linkRange = NSMakeRange(start, label.length + position.length);
    } else {
        NSUInteger firstLineEnd = 0;
        [rendered getLineStart:nullptr end:nullptr contentsEnd:&firstLineEnd forRange:NSMakeRange(0, 0)];
        result.linkRange = NSMakeRange(0, firstLineEnd);
    }
    return result;
}

static void AppendRustDiagnostic(RunLog &log, NSDictionary *message, const DiagnosticContext &context,
                                 NSString *manifest = nil)
{
    if (log.checking) {
        if (![message isKindOfClass:NSDictionary.class])
            return;
        NSString *level = message[@"level"], *text = message[@"message"];
        if (![level isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class] ||
            (![level isEqualToString:@"error"] && ![level isEqualToString:@"warning"]) ||
            [text hasPrefix:@"aborting due to "] || [text hasSuffix:@" warning emitted"] ||
            [text hasSuffix:@" warnings emitted"])
            return;
    }
    LogAppend(log, RustDiagnostic(message, context, manifest));
}

struct CargoSession {
    DiagnosticContext diagnostics;
    ProgramInput *input;
    void (^ready)(void);
    RunRecords records;
    bool finished = false;
    bool built = false;
    TerminalDecoder terminal{};
    DecodedOutput output{};
    NSMutableOrderedSet<NSString *> *executables = nil;
    bool testsOnly = false;

    void emit(std::string_view bytes, RunLog &log)
    {
        NSDictionary *data = JSONDictionary(bytes);
        NSString *reason = data[@"reason"];
        if ([reason isEqualToString:@"build-finished"]) {
            finished = true;
            built = [data[@"success"] boolValue];
            if (built && input) {
                LogStatus(log, @"Build successful\n\n");
                SendLog(log, true);
                SetProgramInput(*input, true);
                if (ready)
                    dispatch_async(dispatch_get_main_queue(), ready);
            }
            return;
        }
        if ([reason isEqualToString:@"compiler-message"]) {
            AppendRustDiagnostic(log, data[@"message"], diagnostics, data[@"manifest_path"]);
        } else if (executables && [reason isEqualToString:@"compiler-artifact"]) {
            NSString *path = data[@"executable"];
            NSArray *kind = data[@"target"][@"kind"];
            if ([path isKindOfClass:NSString.class] && path.isAbsolutePath &&
                ([kind containsObject:@"test"] || (!testsOnly &&
                   ([kind containsObject:@"bin"] || [kind containsObject:@"example"]))))
                [executables addObject:path];
        } else if (!reason.length && !bytes.empty()) {
            ClearDecodedOutput(output);
            DecodeTerminal(terminal, bytes, output);
            RunMessage message{};
            message.text = ConsoleString(output.text);
            message.colorSpans.assign(output.spans.begin(), output.spans.end());
            message.usesTerminalColors = terminal.sawSGR;
            LogAppend(log, std::move(message));
        }
    }

    std::string_view receive(std::string_view bytes, RunLog &log)
    {
        struct ReadContext {
            CargoSession *cargo;
            RunLog *log;
        } context{this, &log};

        return ReadRunRecords(records, bytes, 2 * 1024 * 1024, [](void *context, std::string_view line) {
            auto &read = *static_cast<ReadContext *>(context);
            read.cargo->emit(line, *read.log);
            return !read.cargo->finished;
        }, &context);
    }
};

struct OutputRun {
    size_t byte, character;
    OutputTone tone;
    bool usesColors;
};

struct RunStream {
    RunRecords records;
    TerminalDecoder terminal{};
    DecodedOutput output;
    std::vector<OutputRun> runs;
    OutputTone lineTone = OutputTone::Text;
    bool continued = false;
};

static void FlushRunText(RunStream &stream, RunLog &log)
{
    auto &output = stream.output;
    size_t span_index = 0;
    for (size_t i = 0; i < stream.runs.size(); ++i) {
        const auto &run = stream.runs[i];
        size_t end_byte = i + 1 < stream.runs.size() ? stream.runs[i + 1].byte : output.text.size();
        size_t end = i + 1 < stream.runs.size() ? stream.runs[i + 1].character : output.characters;
        RunMessage message{ConsoleString(std::string_view(output.text).substr(run.byte, end_byte - run.byte)), run.tone, {}};
        message.usesTerminalColors = run.usesColors;
        while (span_index < output.spans.size() && output.spans[span_index].range.location < end) {
            const auto &span = output.spans[span_index];
            size_t first = std::max(size_t(span.range.location), run.character);
            size_t last = span.range.location + span.range.length;
            message.colorSpans.push_back({{uint32_t(first - run.character), uint32_t(std::min(last, end) - first)}, span.colors});
            if (last > end)
                break;

            ++span_index;
        }

        LogAppend(log, std::move(message));
    }

    ClearDecodedOutput(output);
    stream.runs.clear();
}

static void EmitRunLine(RunStream &stream, std::string_view bytes, const DiagnosticContext *diagnostics, bool stderrLine, RunLog &log)
{
    if (stderrLine && diagnostics && diagnostics->language == Language::Rust) {
        if (NSDictionary *record = JSONDictionary(bytes)) {
            AppendRustDiagnostic(log, record, *diagnostics);
            return;
        }
    }

    if (diagnostics && !stream.continued && !stream.runs.empty())
        FlushRunText(stream, log);

    auto &output = stream.output;
    size_t start = output.text.size();
    size_t character = output.characters;
    DecodeTerminal(stream.terminal, bytes, output);
    if (output.text.size() == start)
        return;

    if (!stream.continued)
        stream.lineTone = ConsoleTone(std::string_view(output.text).substr(start), stderrLine);

    if (diagnostics && !stream.continued) {
        RunMessage message{ConsoleString(output.text), stream.lineTone, {}};
        message.usesTerminalColors = stream.terminal.sawSGR;
        message.colorSpans.assign(output.spans.begin(), output.spans.end());
        message = CompilerMessage(std::move(message), output.text, *diagnostics, stderrLine);
        log.buildError |= message.tone == OutputTone::Error && message.location.line != 0 && message.diagnostic.length != 0;
        stream.lineTone = message.tone;
        LogAppend(log, std::move(message));
        ClearDecodedOutput(output);
    } else {
        if (stream.runs.empty() || stream.runs.back().tone != stream.lineTone ||
            stream.runs.back().usesColors != stream.terminal.sawSGR)
            stream.runs.push_back({start, character, stream.lineTone, stream.terminal.sawSGR});
    }

    stream.continued = !bytes.empty() && bytes.back() != '\n';
}

static void FlushRunPartial(RunStream &stream, const DiagnosticContext *diagnostics, bool stderrLine, RunLog &log)
{
    size_t count = CompleteUTF8Prefix(stream.records.partial);
    if (!count)
        return;

    EmitRunLine(stream, std::string_view(stream.records.partial).substr(0, count), diagnostics, stderrLine, log);
    stream.records.partial.erase(0, count);
    FlushRunText(stream, log);
}

static void ReceiveRunText(RunStream &stream, std::string_view bytes, const DiagnosticContext *diagnostics, bool stderrLine, RunLog &log)
{
    struct ReadContext {
        RunStream *stream;
        const DiagnosticContext *diagnostics;
        bool stderrLine;
        RunLog *log;
    } context{&stream, diagnostics, stderrLine, &log};

    bool structured = stderrLine && diagnostics && diagnostics->language == Language::Rust;
    ReadRunRecords(stream.records, bytes, structured ? 2 * 1024 * 1024 : SIZE_MAX, [](void *context, std::string_view line) {
        auto &read = *static_cast<ReadContext *>(context);
        EmitRunLine(*read.stream, line, read.diagnostics, read.stderrLine, *read.log);
        return true;
    }, &context);

    if (stream.output.characters >= 8192)
        FlushRunText(stream, log);

    if (!structured && stream.records.partial.size() >= 16 * 1024)
        FlushRunPartial(stream, diagnostics, stderrLine, log);
}

struct RunReadout {
    RunStream streams[2];
    const DiagnosticContext *diagnostics;
    RunLog *log;
    ProgramInput *input;
    void (^ready)(void);
    CargoSession *cargo;
    std::string *captures[2];
    size_t lastStream = 2;
};

static void ReadChildOutput(void *context, ChildEvent event, std::string_view bytes)
{
    @autoreleasepool {
        auto &run = *static_cast<RunReadout *>(context);
        auto &log = *run.log;
        switch (event) {
        case ChildEvent::Started:
            if (run.input && !run.cargo) {
                SetProgramInput(*run.input, true);
                if (run.ready)
                    dispatch_async(dispatch_get_main_queue(), run.ready);
            }
            return;

        case ChildEvent::Output:
        case ChildEvent::ErrorOutput: {
            size_t index = event == ChildEvent::Output ? 0 : 1;
            if (auto *buffer = run.captures[index]) {
                size_t limit = index == 0 ? 8 * 1024 * 1024 : 64 * 1024;
                if (buffer->size() < limit)
                    buffer->append(bytes.substr(0, limit - buffer->size()));

                return;
            }

            if (index != run.lastStream && run.lastStream < 2)
                FlushRunText(run.streams[run.lastStream], log);

            run.lastStream = index;
            if (!index && run.cargo && !run.cargo->finished)
                bytes = run.cargo->receive(bytes, log);

            if (!bytes.empty())
                ReceiveRunText(run.streams[index], bytes, run.diagnostics, index == 1, log);

            return;
        }

        case ChildEvent::Idle:
            if (!run.diagnostics || run.input) {
                for (size_t i = 0; i < 2; ++i)
                    FlushRunPartial(run.streams[i], nullptr, i == 1, log);
            }
            break;

        case ChildEvent::Update:
            break;
        }

        if (run.lastStream < 2 && (event == ChildEvent::Idle || Clock::now() >= log.nextUpdate))
            FlushRunText(run.streams[run.lastStream], log);

        SendLog(log);
    }
}

static int RunCommand(NSString *tool, NSArray<NSString *> *arguments, NSURL *directory,
                      const DiagnosticContext *diagnostics, const std::atomic_bool &stop, RunLog &log,
                      ProgramInput *input = nullptr, void (^ready)(void) = nil,
                      CargoSession *cargo = nullptr, std::string *capture = nullptr, std::string *captureErrors = nullptr)
{
    const char *local[32];
    std::vector<const char *> large;
    const char **argv = local;
    if (arguments.count + 2 > std::size(local)) {
        large.resize(arguments.count + 2);
        argv = large.data();
    }

    argv[0] = tool.fileSystemRepresentation;
    size_t index = 1;
    for (NSString *argument in arguments)
        argv[index++] = argument.fileSystemRepresentation;
    argv[index] = nullptr;
    RunReadout read{{}, diagnostics, &log, input, ready, cargo, {capture, captureErrors}};
    auto result = RunChild(argv, directory.fileSystemRepresentation, stop, input, ReadChildOutput, &read);
    if (result.startError) {
        LogStatus(log, [NSString stringWithFormat:@"%@: %@\n", tool.lastPathComponent, RunError(result.startError).localizedDescription],
                  OutputTone::Error);
        return -1;
    }

    if (read.lastStream < 2)
        FlushRunText(read.streams[read.lastStream], log);

    for (size_t i = 0; i < 2; ++i) {
        auto &stream = read.streams[i];
        if (!stream.records.partial.empty() || stream.continued) {
            stream.records.partial += '\n';
            EmitRunLine(stream, stream.records.partial, diagnostics, i == 1, log);
        }

        FlushRunText(stream, log);
    }

    if (result.ioError)
        LogStatus(log, [NSString stringWithFormat:@"%@\n", RunError(result.ioError).localizedDescription], OutputTone::Error);

    return result.code;
}

static void RunProgram(NSString *program, NSArray<NSString *> *arguments, NSURL *directory,
                       const std::atomic_bool &stop, RunLog &log, ProgramInput &input, void (^ready)(void),
                       const DiagnosticContext *diagnostics = nullptr)
{
    int result = RunCommand(program, arguments, directory, diagnostics, stop, log, &input, ready);
    if (result > 0 && diagnostics && log.buildError)
        LogStatus(log, @"Build failed.\n", OutputTone::Error);
    else
        log.programExitCode = result;
}

static NSString *GetTool(NSString *name, Language language, RunLog &log)
{
    NSString *tool = FindTool(name, language);
    if (!tool)
        LogStatus(log, [NSString stringWithFormat:@"%@ was not found.\n", name], OutputTone::Error);
    return tool;
}

static bool CPlusPlus(Language language)
{
    return language == Language::Cpp || language == Language::ObjectiveCpp;
}

static bool Objective(Language language)
{
    return language == Language::ObjectiveC || language == Language::ObjectiveCpp;
}

static NSArray<NSString *> *NativeFlags(Language language, bool debugging = false)
{
    bool cpp = CPlusPlus(language);
    NSString *kind = Objective(language) ? (cpp ? @"objective-c++" : @"objective-c") : (cpp ? @"c++" : @"c");
    NSArray *flags = @[@"-x", kind, cpp ? @"-std=c++20" : @"-std=c17", @"-Wall", @"-Wextra",
                       @"-fcolor-diagnostics", @"-fno-caret-diagnostics", @"-fdiagnostics-print-source-range-info"];
    return debugging ? [flags arrayByAddingObjectsFromArray:@[@"-O0", @"-g"]] : flags;
}

static NSURL *BuildNativeProject(NSURL *folder, NSURL *file, NSString *name, RunFiles &files, bool debugging,
                                 const std::atomic_bool &stop, RunLog &log)
{
    auto sources = SelectNativeSources(folder, CanonicalFileURL(file), stop);
    if (stop.load(std::memory_order_relaxed))
        return nil;
    if (sources.files.empty()) {
        LogStatus(log, sources.error, OutputTone::Error);
        return nil;
    }

    const auto uses = [&](bool (*test)(Language)) {
        return std::any_of(sources.files.begin(), sources.files.end(), [test](const SourceUnit &unit) {
            return test(unit.language);
        });
    };
    bool c = uses([](Language language) { return !CPlusPlus(language); });
    bool cpp = uses(CPlusPlus);
    bool objective = uses(Objective);
    Language firstLanguage = sources.files.front().language;
    bool mixed = std::any_of(sources.files.begin(), sources.files.end(), [firstLanguage](const SourceUnit &unit) {
        return unit.language != firstLanguage;
    });
    NSString *clang = c ? GetTool(@"clang", Language::C, log) : nil;
    NSString *clangXX = cpp ? GetTool(@"clang++", Language::Cpp, log) : nil;
    if ((c && !clang) || (cpp && !clangXX))
        return nil;

    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    if (!files.folder) {
        LogStatus(log, [NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return nil;
    }
    NSURL *program = [files.folder URLByAppendingPathComponent:@"program"];
    NSArray<NSString *> *includes = @[@"-I", sources.directory.path,
        @"-I", [folder URLByAppendingPathComponent:@"include" isDirectory:YES].path, @"-I", folder.path];
    NSURL *active = CanonicalFileURL(file);
    DiagnosticContext diagnostics{active, active, folder, name, true};
    LogStatus(log, @"Building...\n");
    SendLog(log, true);

    int result = 0;
    if (mixed) {
        NSMutableArray<NSString *> *objects = [NSMutableArray arrayWithCapacity:sources.files.size() + 2];
        for (const auto &unit : sources.files) {
            bool cplusplus = CPlusPlus(unit.language);
            NSString *object = [files.folder URLByAppendingPathComponent:
                [NSString stringWithFormat:@"%lu.o", (unsigned long)objects.count]].path;
            NSMutableArray<NSString *> *arguments = [NativeFlags(unit.language, debugging) mutableCopy];
            [arguments addObjectsFromArray:includes];
            [arguments addObjectsFromArray:@[@"-c", unit.url.path, @"-o", object]];
            result = RunCommand(cplusplus ? clangXX : clang, arguments, folder, &diagnostics, stop, log);
            if (result)
                break;
            [objects addObject:object];
        }
        if (!result) {
            if (objective)
                [objects addObjectsFromArray:@[@"-framework", @"Foundation"]];
            if (debugging)
                [objects addObject:@"-g"];
            [objects addObjectsFromArray:@[@"-o", program.path]];
            result = RunCommand(cpp ? clangXX : clang, objects, folder, &diagnostics, stop, log);
        }
    } else {
        NSMutableArray<NSString *> *arguments = [NativeFlags(firstLanguage, debugging) mutableCopy];
        [arguments addObjectsFromArray:includes];
        for (const auto &unit : sources.files)
            [arguments addObject:unit.url.path];
        if (objective)
            [arguments addObjectsFromArray:@[@"-framework", @"Foundation"]];
        [arguments addObjectsFromArray:@[@"-o", program.path]];
        result = RunCommand(cpp ? clangXX : clang, arguments, folder, &diagnostics, stop, log);
    }
    if (stop.load(std::memory_order_relaxed))
        return nil;
    if (result) {
        LogStatus(log, @"Build failed.\n", OutputTone::Error);
        return nil;
    }
    LogStatus(log, @"Build successful\n\n");
    SendLog(log, true);
    return program;
}

static void RunNativeProject(NSURL *folder, NSURL *file, NSString *name, const std::atomic_bool &stop,
                             RunLog &log, ProgramInput &input, void (^ready)(void))
{
    RunFiles files;
    if (NSURL *program = BuildNativeProject(folder, file, name, files, false, stop, log))
        RunProgram(program.path, @[], folder, stop, log, input, ready);
}

static void AddCargoTarget(NSMutableArray<NSString *> *arguments, NSDictionary *metadata,
                           NSURL *manifest, NSURL *file, bool debugging = false)
{
    NSString *active = CanonicalFileURL(file).path;
    BOOL packageManifest = NO;
    NSSet<NSString *> *defaultMembers = [NSSet setWithArray:metadata[@"workspace_default_members"] ?
        metadata[@"workspace_default_members"] : metadata[@"workspace_members"]];
    NSString *onlyPackage = nil, *onlyTarget = nil, *currentDefault = nil;
    NSUInteger defaults = 0;
    for (NSDictionary *package in metadata[@"packages"]) {
        NSString *manifestPath = package[@"manifest_path"];
        if (!manifestPath.length)
            continue;
        BOOL current = [CanonicalFileURL([NSURL fileURLWithPath:manifestPath]).path isEqualToString:manifest.path];
        packageManifest |= current;
        BOOL workspaceDefault = [defaultMembers containsObject:package[@"id"]];
        NSString *defaultRun = package[@"default_run"];
        if (current && [defaultRun isKindOfClass:NSString.class])
            currentDefault = defaultRun;
        for (NSDictionary *target in package[@"targets"]) {
            NSArray<NSString *> *kind = target[@"kind"];
            BOOL binary = [kind containsObject:@"bin"];
            BOOL example = [kind containsObject:@"example"] && [target[@"crate_types"] containsObject:@"bin"];
            BOOL test = debugging && [kind containsObject:@"test"];
            NSString *targetPath = target[@"src_path"];
            NSString *name = target[@"name"];
            if (!name.length)
                continue;
            if ((binary || example || test) && active.length && targetPath.length &&
                [CanonicalFileURL([NSURL fileURLWithPath:targetPath]).path isEqualToString:active]) {
                if (!current)
                    [arguments addObjectsFromArray:@[@"--package", package[@"name"]]];
                [arguments addObjectsFromArray:@[binary ? @"--bin" : example ? @"--example" : @"--test", name]];
                return;
            }
            if (binary && workspaceDefault &&
                (![defaultRun isKindOfClass:NSString.class] || [defaultRun isEqualToString:name])) {
                ++defaults;
                onlyPackage = package[@"name"];
                onlyTarget = name;
            }
        }
    }
    if (!packageManifest && defaults == 1)
        [arguments addObjectsFromArray:@[@"--package", onlyPackage, @"--bin", onlyTarget]];
    else if (debugging && currentDefault.length)
        [arguments addObjectsFromArray:@[@"--bin", currentDefault]];
}

static NSURL *RunCargo(NSURL *manifest, NSURL *file, const std::atomic_bool &stop, RunLog &log,
                      ProgramInput *input, void (^ready)(void))
{
    NSString *tool = GetTool(@"cargo", Language::Rust, log);
    if (!tool)
        return nil;

    bool debugging = !input;
    NSURL *directory = manifest.URLByDeletingLastPathComponent;
    LogStatus(log, debugging ? @"Building…\n" : @"Building...\n");
    SendLog(log, true);

    std::string information;
    int result = RunCommand(tool, @[@"metadata", @"--no-deps", @"--format-version", @"1",
        @"--manifest-path", manifest.path], directory, nullptr, stop, log, nullptr, nil, nullptr, &information);
    if (stop.load(std::memory_order_relaxed))
        return nil;

    NSDictionary *metadata = result ? nil : JSONDictionary(information);
    if (!metadata) {
        LogStatus(log, @"Could not read the Cargo project.\n", OutputTone::Error);
        return nil;
    }

    NSString *root = metadata[@"workspace_root"];
    NSURL *workspace = root.length ? [NSURL fileURLWithPath:root isDirectory:YES] : directory;
    NSMutableArray<NSString *> *arguments = [@[debugging ? @"build" : @"run", @"--quiet", @"--color", @"always",
        @"--message-format=json,json-diagnostic-rendered-ansi"] mutableCopy];
    if (debugging) {
        [arguments addObjectsFromArray:@[@"--config", @"profile.dev.debug=2", @"--config", @"profile.dev.opt-level=0",
                                         @"--config", @"profile.dev.strip=false"]];
    }

    [arguments addObjectsFromArray:@[@"--manifest-path", manifest.path]];
    AddCargoTarget(arguments, metadata, manifest, file, debugging);
    NSURL *active = debugging ? file : CanonicalFileURL(file);
    CargoSession cargo{{active, active, workspace, debugging ? file.lastPathComponent : nil, false, Language::Rust}, input, ready, {}};
    if (debugging) {
        cargo.executables = [NSMutableOrderedSet orderedSet];
        cargo.testsOnly = [arguments containsObject:@"--test"];
    }

    result = RunCommand(tool, arguments, directory, nullptr, stop, log, input, ready, &cargo);
    if (stop.load(std::memory_order_relaxed))
        return nil;

    if (!cargo.built || (debugging && result)) {
        LogStatus(log, @"Build failed.\n", OutputTone::Error);
        return nil;
    }

    if (!debugging) {
        log.programExitCode = result;
        return nil;
    }

    if (cargo.executables.count != 1) {
        NSString *message = cargo.executables.count ? @"Open the main file of the Cargo target you want to debug.\n" :
                                                     @"Cargo did not produce an executable.\n";
        LogStatus(log, message, OutputTone::Error);
        return nil;
    }

    LogStatus(log, @"Build successful\n\n");
    return [NSURL fileURLWithPath:cargo.executables.firstObject];
}

static void AddCheckBranch(NSMutableSet<NSString *> *branches, NSString *path, NSString *root)
{
    while (PathIsInFolder(path, root) && ![branches containsObject:path]) {
        [branches addObject:path];
        if ([path isEqualToString:root])
            break;
        path = path.stringByDeletingLastPathComponent;
    }
}

static NSURL *MirroredCheckURL(NSURL *mirror, NSString *path)
{
    return path.length <= 1 ? mirror : [mirror URLByAppendingPathComponent:[path substringFromIndex:1]];
}

static bool MirrorCheckDirectory(NSString *source, NSURL *destination, NSSet<NSString *> *branches,
                                 NSDictionary<NSString *, NSData *> *edits, const std::atomic_bool &stop, NSError **error)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [files contentsOfDirectoryAtPath:source error:error];
    if (!names || ![files createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:error])
        return false;
    for (NSString *name in names) {
        if (stop.load(std::memory_order_relaxed))
            return false;
        @autoreleasepool {
            NSString *path = [source stringByAppendingPathComponent:name];
            if (edits[path])
                continue;
            NSURL *link = [destination URLByAppendingPathComponent:name];
            if ([branches containsObject:path]) {
                if (!MirrorCheckDirectory(path, link, branches, edits, stop, error))
                    return false;
            } else if ([name isEqualToString:@"Cargo.toml"] || [name isEqualToString:@"Cargo.lock"]) {
                NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
                if (!data || ![data writeToURL:link options:0 error:error])
                    return false;
            } else if (![files createSymbolicLinkAtPath:link.path withDestinationPath:path error:error]) {
                return false;
            }
        }
    }
    return true;
}

static bool WriteCheckMirror(NSURL *mirror, NSString *root, NSSet<NSString *> *branches, NSDictionary<NSString *, NSData *> *edits,
                             const std::atomic_bool &stop, NSError **error)
{
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files fileExistsAtPath:mirror.path] && ![files removeItemAtURL:mirror error:error])
        return false;
    if (!MirrorCheckDirectory(root, MirroredCheckURL(mirror, root), branches, edits, stop, error))
        return false;
    NSString *mirrorPath = CanonicalFileURL(mirror).path;
    for (NSString *path in edits) {
        if (stop.load(std::memory_order_relaxed))
            return false;
        NSURL *file = MirroredCheckURL(mirror, path);
        if (!PathIsInFolder(CanonicalFileURL(file).path, mirrorPath)) {
            *error = RunError(EACCES);
            return false;
        }
        if (![files createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                              attributes:nil error:error] || ![edits[path] writeToURL:file options:0 error:error])
            return false;
    }
    return true;
}
static bool PrepareCargoCheck(NSURL *mirror, NSString *workspace, NSArray *packages,
                              const std::vector<CheckSource> &sources, const std::atomic_bool &stop, NSError **error)
{
    NSString *root = workspace;
    NSMutableSet<NSString *> *external = [NSMutableSet set];
    for (NSDictionary *package in packages) {
        for (NSDictionary *dependency in package[@"dependencies"]) {
            NSString *path = dependency[@"path"];
            if ([path isKindOfClass:NSString.class] && path.isAbsolutePath) {
                path = CanonicalFileURL([NSURL fileURLWithPath:path]).path;
                if (!PathIsInFolder(path, workspace))
                    [external addObject:path];
                while (root.length > 1 && !PathIsInFolder(path, root))
                    root = root.stringByDeletingLastPathComponent;
            }
        }
    }

    NSMutableSet<NSString *> *branches = [NSMutableSet set];
    AddCheckBranch(branches, workspace, root);
    for (NSDictionary *package in packages) {
        NSString *manifest = package[@"manifest_path"];
        if ([manifest isKindOfClass:NSString.class]) {
            NSURL *url = CanonicalFileURL([NSURL fileURLWithPath:manifest]);
            AddCheckBranch(branches, url.URLByDeletingLastPathComponent.path, root);
        }
    }
    NSMutableDictionary<NSString *, NSData *> *edits = [NSMutableDictionary dictionary];
    for (const auto &source : sources) {
        @autoreleasepool {
            NSString *path = source.file.path;
            bool inProject = PathIsInFolder(path, workspace);
            if (!inProject) {
                for (NSString *dependency in external) {
                    if (PathIsInFolder(path, dependency)) {
                        inProject = true;
                        break;
                    }
                }
            }
            if (!inProject)
                continue;
            NSData *data = [source.text dataUsingEncoding:NSUTF8StringEncoding];
            NSData *saved = [NSData dataWithContentsOfURL:source.file options:NSDataReadingMappedIfSafe error:nil];
            if (data && ![data isEqualToData:saved]) {
                edits[path] = data;
                AddCheckBranch(branches, source.file.URLByDeletingLastPathComponent.path, root);
            }
        }
    }

    return WriteCheckMirror(mirror, root, branches, edits, stop, error);
}

static void CargoCheckStatus(RunLog &log, int status, std::string_view errors, NSURL *mirror)
{
    if (status && !log.errors) {
        if (errors.empty()) {
            LogStatus(log, @"Cargo check failed.\n", OutputTone::Error);
            return;
        }
        NSString *text = ConsoleString(errors);
        if (mirror)
            text = [text stringByReplacingOccurrencesOfString:mirror.path withString:@""];
        RunMessage message = DecodeConsoleString(text);
        message.tone = OutputTone::Error;
        LogAppend(log, std::move(message));
    }
}

static void CheckCargo(NSURL *manifest, NSURL *file, NSString *name, const std::vector<CheckSource> &sources,
                       RustCheckCache *cache, const std::atomic_bool &stop, RunLog &log)
{
    NSString *tool = GetTool(@"cargo", Language::Rust, log);
    if (!tool)
        return;
    NSURL *directory = manifest.URLByDeletingLastPathComponent;
    std::string metadata, errors;
    int status = RunCommand(tool, @[@"metadata", @"--offline", @"--no-deps", @"--format-version", @"1",
        @"--manifest-path", manifest.path], directory, nullptr, stop, log, nullptr, nil, nullptr, &metadata, &errors);
    if (stop.load(std::memory_order_relaxed))
        return;
    if (status) {
        CargoCheckStatus(log, status, errors, nil);
        return;
    }
    NSDictionary *project = JSONDictionary(metadata);
    NSString *root = project[@"workspace_root"];
    if (![root isKindOfClass:NSString.class] || !root.isAbsolutePath) {
        LogStatus(log, @"Could not read the Cargo workspace.\n", OutputTone::Error);
        return;
    }
    NSURL *workspace = CanonicalFileURL([NSURL fileURLWithPath:root isDirectory:YES]);
    NSError *error = nil;
    NSURL *scratch = [cache directoryWithError:&error];
    NSURL *mirror = [scratch URLByAppendingPathComponent:@"source" isDirectory:YES];
    if (!scratch || !PrepareCargoCheck(mirror, workspace.path, project[@"packages"], sources, stop, &error)) {
        if (!stop.load(std::memory_order_relaxed)) {
            NSString *message = error ? error.localizedDescription : @"Could not prepare the Cargo workspace.";
            LogStatus(log, [message stringByAppendingString:@"\n"], OutputTone::Error);
        }
        return;
    }

    NSURL *target = [scratch URLByAppendingPathComponent:@"target" isDirectory:YES];
    NSURL *checkedManifest = MirroredCheckURL(mirror, manifest.path);
    NSArray *arguments = @[@"check", @"--quiet", @"--offline", @"--all-targets", @"--color", @"always",
        @"--message-format=json,json-diagnostic-rendered-ansi", @"--manifest-path", checkedManifest.path, @"--target-dir", target.path];
    CargoSession cargo{{file, file, MirroredCheckURL(mirror, workspace.path), name, false, Language::Rust, mirror}, nullptr, nil, {}};
    errors.clear();
    status = RunCommand(tool, arguments, directory, nullptr, stop, log, nullptr, nil, &cargo, nullptr, &errors);
    if (!stop.load(std::memory_order_relaxed))
        CargoCheckStatus(log, status, errors, mirror);
}

static void CheckRustFile(NSURL *file, NSString *name, NSString *text, const std::atomic_bool &stop, RunLog &log)
{
    NSString *tool = GetTool(@"rustc", Language::Rust, log);
    if (!tool)
        return;
    RunFiles files;
    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    NSURL *directory = file.URLByDeletingLastPathComponent;
    NSURL *input = file;
    if (files.folder && text) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (!file || ![data isEqualToData:[NSData dataWithContentsOfURL:file]])
            input = WriteRunSource(files, data, directory, @".rs", &error);
    }
    if (!files.folder || !input) {
        NSString *message = error ? error.localizedDescription : @"Could not prepare the Rust source.";
        LogStatus(log, [message stringByAppendingString:@"\n"], OutputTone::Error);
        return;
    }
    DiagnosticContext diagnostics{input, file, directory ? directory : files.folder, name, false, Language::Rust};
    int status = RunCommand(tool, @[@"--edition=2021", @"--crate-name", @"editor_program", @"--emit=metadata",
        @"--error-format=json", @"--json=diagnostic-rendered-ansi", input.path, @"--out-dir", files.folder.path],
        diagnostics.directory, &diagnostics, stop, log);
    if (status && !log.errors && !stop.load(std::memory_order_relaxed))
        LogStatus(log, @"Rust check failed.\n", OutputTone::Error);
}

static bool BuildProgram(NSString *tool, NSArray<NSString *> *arguments, NSURL *directory,
                         const DiagnosticContext &diagnostics, const std::atomic_bool &stop, RunLog &log)
{
    LogStatus(log, @"Building...\n");
    SendLog(log, true);
    int result = RunCommand(tool, arguments, directory, &diagnostics, stop, log);
    if (stop.load(std::memory_order_relaxed))
        return false;
    if (result) {
        LogStatus(log, @"Build failed.\n", OutputTone::Error);
        return false;
    }
    LogStatus(log, @"Build successful\n\n");
    SendLog(log, true);
    return true;
}

static NSArray<NSString *> *GoBuildArguments(NSString *target, NSString *program, bool tests, bool debugging)
{
    if (debugging) {
        // Apple LLDB needs uncompressed Go DWARF for source breakpoints and watches.
        return tests ? @[@"test", @"-c", @"-gcflags=all=-N -l", @"-ldflags=-compressdwarf=false", @"-o", program, target] :
                       @[@"build", @"-gcflags=all=-N -l", @"-ldflags=-compressdwarf=false", @"-o", program, target];
    }

    return tests ? @[@"test", @"-c", @"-o", program, target] : @[@"build", @"-o", program, target];
}

static void RunGoModule(RunProject project, NSURL *file, const std::atomic_bool &stop,
                        RunLog &log, ProgramInput &input, void (^ready)(void))
{
    NSString *tool = GetTool(@"go", Language::Go, log);
    if (!tool)
        return;
    NSURL *directory = file.URLByDeletingLastPathComponent;
    if (!PathIsInFolder(directory.path, project.folder.path))
        directory = project.folder;
    DiagnosticContext diagnostics{file, file, directory, file.lastPathComponent, true, Language::Go};
    bool tests = [file.lastPathComponent hasSuffix:@"_test.go"];
    RunFiles files;
    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    if (!files.folder) {
        LogStatus(log, [NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return;
    }
    NSString *program = [files.folder URLByAppendingPathComponent:@"program"].path;
    if (!BuildProgram(tool, GoBuildArguments(@".", program, tests, false), directory, diagnostics, stop, log))
        return;

    if ([NSFileManager.defaultManager isExecutableFileAtPath:program])
        RunProgram(program, tests ? @[@"-test.v"] : @[], directory, stop, log, input, ready);
    else
        LogStatus(log, @"Open a Go file in a main package or a _test.go file to run tests.\n", OutputTone::Error);
}

static NSString *SwiftProduct(NSDictionary *package, NSURL *folder, NSURL *file)
{
    NSMutableArray<NSDictionary *> *executables = [NSMutableArray array];
    for (NSDictionary *product in package[@"products"]) {
        if ([product[@"type"] objectForKey:@"executable"])
            [executables addObject:product];
    }
    if (executables.count == 1)
        return executables.firstObject[@"name"];
    for (NSDictionary *product in executables) {
        for (NSString *name in product[@"targets"]) {
            NSString *path = nil;
            for (NSDictionary *target in package[@"targets"]) {
                if ([target[@"name"] isEqual:name] && [target[@"path"] isKindOfClass:NSString.class]) {
                    path = target[@"path"];
                    break;
                }
            }
            if (!path)
                path = [@"Sources" stringByAppendingPathComponent:name];
            NSURL *source = CanonicalFileURL([folder URLByAppendingPathComponent:path]);
            if (PathIsInFolder(file.path, source.path))
                return product[@"name"];
        }
    }
    return nil;
}

static NSURL *BuildSwiftPackage(RunProject project, NSURL *file, const std::atomic_bool &stop, RunLog &log, bool debugging)
{
    NSString *tool = GetTool(@"swift", Language::Swift, log);
    if (!tool)
        return nil;
    DiagnosticContext diagnostics{file, file, project.folder, file.lastPathComponent, false, Language::Swift};
    std::string manifest;
    if (RunCommand(tool, @[@"package", @"dump-package"], project.folder, &diagnostics, stop, log, nullptr,
                   nil, nullptr, &manifest) != 0 || stop.load(std::memory_order_relaxed))
        return nil;
    NSDictionary *package = JSONDictionary(manifest);
    NSString *product = SwiftProduct(package, project.folder, file);
    if (!product.length) {
        LogStatus(log, @"Open a source file in an executable Swift package target.\n", OutputTone::Error);
        return nil;
    }
    NSArray *arguments = @[@"build", @"--product", product, @"-Xswiftc", @"-color-diagnostics"];
    if (debugging)
        arguments = [arguments arrayByAddingObjectsFromArray:@[@"--configuration", @"debug", @"-Xswiftc", @"-g", @"-Xswiftc", @"-Onone"]];
    if (!BuildProgram(tool, arguments, project.folder, diagnostics, stop, log))
        return nil;

    std::string output;
    NSArray *find = debugging ? @[@"build", @"--configuration", @"debug", @"--show-bin-path"] : @[@"build", @"--show-bin-path"];
    int result = RunCommand(tool, find, project.folder, nullptr, stop, log,
                            nullptr, nil, nullptr, &output);
    if (result || stop.load(std::memory_order_relaxed))
        return nil;
    NSString *path = [[[NSString alloc] initWithBytes:output.data() length:output.size() encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *program = ExecutableAt(path, product);
    if (program)
        return [NSURL fileURLWithPath:program];
    LogStatus(log, @"Swift did not produce an executable.\n", OutputTone::Error);
    return nil;
}

static void RunSwiftPackage(RunProject project, NSURL *file, const std::atomic_bool &stop,
                            RunLog &log, ProgramInput &input, void (^ready)(void))
{
    if (NSURL *program = BuildSwiftPackage(project, file, stop, log, false))
        RunProgram(program.path, @[], project.folder, stop, log, input, ready);
}

static NSString *DotNetExecutable(NSURL *folder, NSString *preferred)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSURL *> *outputs = [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSString *only = nil;
    NSUInteger count = 0;
    for (NSURL *file in outputs) {
        NSString *name = file.lastPathComponent;
        NSString *suffix = @".runtimeconfig.json";
        if (![name hasSuffix:suffix])
            continue;
        NSString *base = [name substringToIndex:name.length - suffix.length];
        NSURL *assembly = [folder URLByAppendingPathComponent:[base stringByAppendingString:@".dll"]];
        if (!ExistingFile(assembly))
            continue;
        if ([base isEqualToString:preferred])
            return assembly.path;
        only = assembly.path;
        ++count;
    }
    return count == 1 ? only : nil;
}

static void BuildAndRunDotNet(NSString *tool, NSURL *source, NSURL *directory,
                              const DiagnosticContext &diagnostics, const std::atomic_bool &stop,
                              RunLog &log, ProgramInput &input, void (^ready)(void))
{
    RunFiles files;
    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    if (!files.folder) {
        LogStatus(log, [NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return;
    }
    NSArray<NSString *> *arguments = @[@"build", source.path, @"--output", files.folder.path,
                                      @"--disable-build-servers", @"--nologo", @"-p:NuGetAudit=false"];
    if ([source.pathExtension.lowercaseString isEqualToString:@"cs"]) {
        // File-based builds default to AOT. Run the managed application with the installed runtime.
        arguments = [arguments arrayByAddingObjectsFromArray:
            @[@"-p:PublishAot=false", @"-p:PublishTrimmed=false", @"-p:SelfContained=false"]];
    }
    if (!BuildProgram(tool, arguments, directory, diagnostics, stop, log))
        return;
    NSString *assembly = DotNetExecutable(files.folder, source.lastPathComponent.stringByDeletingPathExtension);
    if (assembly)
        RunProgram(tool, @[assembly], directory, stop, log, input, ready);
    else
        LogStatus(log, @"The .NET build did not produce a single executable application.\n", OutputTone::Error);
}

static void RunDotNetProject(RunProject project, Language language, NSURL *file, const std::atomic_bool &stop,
                             RunLog &log, ProgramInput &input, void (^ready)(void))
{
    NSString *tool = GetTool(@"dotnet", language, log);
    DiagnosticContext diagnostics{file, file, project.folder, file.lastPathComponent, false, language};
    if (tool)
        BuildAndRunDotNet(tool, project.manifest, project.folder, diagnostics, stop, log, input, ready);
}

static NSArray<NSString *> *ScriptArguments(Language language, NSString *path)
{
    auto flags = ScriptRunFlags(language);
    if (!flags.count)
        return @[path];
    NSString *arguments[4];
    for (unsigned i = 0; i < flags.count; ++i)
        arguments[i] = @(flags.values[i]);
    arguments[flags.count] = path;
    return [NSArray arrayWithObjects:arguments count:flags.count + 1];
}

static NSArray<NSString *> *NativeSourceArguments(Language language, NSString *path, NSString *program,
                                                 NSURL *includes, bool package, bool debugging)
{
    NSArray<NSString *> *args;
    if (language == Language::Rust) {
        args = @[@"--edition=2021", @"--crate-name", @"editor_program", @"--error-format=json",
                 @"--json=diagnostic-rendered-ansi", path, @"-o", program];
        return debugging ? [args arrayByAddingObjectsFromArray:@[@"-C", @"debuginfo=2", @"-C", @"opt-level=0"]] : args;
    }
    if (language == Language::Swift) {
        args = @[@"-color-diagnostics", path, @"-o", program];
        return debugging ? [args arrayByAddingObjectsFromArray:@[@"-g", @"-Onone"]] : args;
    }
    if (language == Language::Go)
        return GoBuildArguments(path, program, false, debugging);

    if (language == Language::Odin) {
        args = @[@"build", package ? path.stringByDeletingLastPathComponent : path,
                 [@"-out:" stringByAppendingString:program], @"-error-pos-style:unix", @"-terse-errors"];
        if (!package)
            args = [args arrayByAddingObject:@"-file"];
        return debugging ? [args arrayByAddingObject:@"-debug"] : args;
    }
    if (language == Language::Zig)
        return @[@"build-exe", @"-O", @"Debug", path, [@"-femit-bin=" stringByAppendingString:program]];
    if (language == Language::Assembly)
        return @[@"-g", path, @"-o", program];
    args = [NativeFlags(language, debugging) arrayByAddingObjectsFromArray:@[@"-iquote", includes.path, path, @"-o", program]];
    return Objective(language) ? [args arrayByAddingObjectsFromArray:@[@"-framework", @"Foundation"]] : args;
}

bool CheckableLanguage(Language language)
{
    return language == Language::Rust || language == Language::JSON || language == Language::JSONC ||
           language == Language::CommonLisp || ToolsForRun(language).check != nil;
}

static void LogSyntaxIssue(RunLog &log, SyntaxIssue issue, NSURL *file, NSString *name, bool utf16 = false)
{
    if (!issue.line || issue.message.empty())
        return;

    NSString *label = issue.column ? [NSString stringWithFormat:@"%@:%zu:%zu", name, issue.line, issue.column] :
                                     [NSString stringWithFormat:@"%@:%zu", name, issue.line];
    NSString *details = ConsoleString(issue.message);
    RunMessage message{[NSString stringWithFormat:@"%@: error: %@\n", label, details], OutputTone::Error,
                       {file, issue.line, issue.column, 0, 0, true, false, utf16}, details};
    message.linkRange = NSMakeRange(0, label.length);
    LogAppend(log, std::move(message));
}

static SyntaxIssue CheckLispText(NSString *text, const std::atomic_bool &stop)
{
    LexState state;
    std::u16string line;
    std::vector<Token> tokens;
    SyntaxIssue open{};
    size_t depth = 0;
    for (NSUInteger start = 0, row = 1; start < text.length; ++row) {
        if (stop.load(std::memory_order_relaxed))
            return {};

        NSUInteger end, content;
        [text getLineStart:nullptr end:&end contentsEnd:&content forRange:NSMakeRange(start, 0)];
        line.resize(content - start);
        [text getCharacters:reinterpret_cast<unichar *>(line.data()) range:NSMakeRange(start, line.size())];
        start = end;
        if (row == 1 && !line.empty() && line.front() == u'\uFEFF')
            line.erase(0, 1);

        tokenize_line(line, Language::CommonLisp, state, tokens);
        size_t token = 0;
        for (size_t column = 0; column < line.size(); ++column) {
            char16_t ch = line[column];
            if (ch != u'(' && ch != u')')
                continue;

            while (token < tokens.size() && tokens[token].start + tokens[token].length <= column)
                ++token;

            if (token < tokens.size() && tokens[token].start <= column && tokens[token].non_code)
                continue;

            if (ch == u'(') {
                if (depth++ == 0)
                    open = {row, column + 1, "Unclosed list."};
            } else {
                if (!depth)
                    return {row, column + 1, "Unmatched ')'."};

                --depth;
            }
        }
    }

    return depth ? open : SyntaxIssue{};
}

static NSString *JavaScriptCheckSuffix(NSURL *file)
{
    NSString *ext = file.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mjs"] || [ext isEqualToString:@"cjs"])
        return [@"." stringByAppendingString:ext];

    NSURL *manifest = ParentManifest(file.URLByDeletingLastPathComponent, nil, @"package.json");
    NSData *data = manifest ? [NSData dataWithContentsOfURL:manifest options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (data.length && data.length <= 1024 * 1024) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id type = [json isKindOfClass:NSDictionary.class] ? json[@"type"] : nil;
        if ([type isEqual:@"module"])
            return @".mjs";
        if ([type isEqual:@"commonjs"])
            return @".cjs";
    }

    return @".js";
}

static NSURL *CheckOdinDirectory(NSURL *folder, RunProject project, const std::vector<CheckSource> &sources,
                                 const std::atomic_bool &stop, RunFiles &files)
{
    NSMutableDictionary<NSString *, NSData *> *edits = nil;
    for (const auto &source : sources) {
        if (!source.saved && [source.file.URLByDeletingLastPathComponent.path isEqualToString:folder.path]) {
            NSData *data = [source.text dataUsingEncoding:NSUTF8StringEncoding];
            if (!data)
                return nil;
            if (!edits)
                edits = [NSMutableDictionary dictionary];

            edits[source.file.path] = data;
        }
    }

    if (!edits.count)
        return folder;

    NSString *root = project.folder.path;
    if (!PathIsInFolder(folder.path, root))
        root = folder.path;

    NSError *error = nil;
    files.folder = CanonicalFileURL(TemporaryFolder(&error));
    if (!files.folder)
        return nil;

    NSURL *mirror = [files.folder URLByAppendingPathComponent:@"source" isDirectory:YES];
    NSMutableSet<NSString *> *branches = [NSMutableSet set];
    AddCheckBranch(branches, folder.path, root);
    return WriteCheckMirror(mirror, root, branches, edits, stop, &error) ? MirroredCheckURL(mirror, folder.path) : nil;
}

static void CheckSourceFile(RunProject project, Language language, NSURL *file, NSString *name, const std::vector<CheckSource> &sources,
                            const std::atomic_bool &stop, RunLog &log)
{
    NSString *text = sources.empty() ? nil : sources.front().text;
    if (!text.length)
        return;

    log.locatedOnly = true;
    if (language == Language::CommonLisp) {
        LogSyntaxIssue(log, CheckLispText(text, stop), file, name, true);
        return;
    }

    if (language == Language::JSON || language == Language::JSONC) {
        LogSyntaxIssue(log, CheckJSONText(UTF8View(text), language == Language::JSONC), file, name);
        return;
    }

    NSString *program = ToolsForRun(language).check;
    NSString *tool = program ? FindTool(program, language) : nil;
    if (!tool || stop.load(std::memory_order_relaxed))
        return;

    NSURL *directory = file.URLByDeletingLastPathComponent;
    bool odinPackage = language == Language::Odin && file;
    RunFiles files;
    NSError *error = nil;
    NSURL *input = file;
    NSURL *mirror = nil;
    if (odinPackage) {
        directory = CheckOdinDirectory(directory, project, sources, stop, files);
        if (!directory)
            return;

        if (files.folder)
            mirror = [files.folder URLByAppendingPathComponent:@"source" isDirectory:YES];
    } else {
        files.folder = TemporaryFolder(&error);
        if (!files.folder)
            return;

        NSString *suffix = language == Language::JavaScript ? JavaScriptCheckSuffix(file) : SourceSuffix(language, file);
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (!data)
            return;

        input = WriteRunSource(files, data, nil, suffix, &error);
        if (!input)
            return;

        input = CanonicalFileURL(input);
    }

    if (!directory)
        directory = files.folder;

    NSString *path = input.path;
    NSArray<NSString *> *args = nil;
    std::optional<ScriptDiagnostic> script;
    if (is_c_family(language)) {
        args = [NativeFlags(language) arrayByAddingObjectsFromArray:@[@"-fsyntax-only", @"-iquote", directory.path, path]];
    } else {
        switch (language) {
        case Language::Python: {
            // compile() reads the snapshot and reports positions without evaluating the program.
            static NSString *const check = @"import sys\n"
                "p = sys.argv[1]\n"
                "try:\n"
                "    compile(open(p, 'rb').read(), p, 'exec')\n"
                "except SyntaxError as e:\n"
                "    n, c = e.lineno or 1, e.offset if e.offset and e.offset > 0 else 1\n"
                "    end = e.end_offset if getattr(e, 'end_lineno', None) == n and e.end_offset else c + 1\n"
                "    sys.stderr.buffer.write(f'{p}:{n}:{c}:{{{n}:{c}-{n}:{max(c+1,end)}}}: error: {e.msg}\\n'.encode('utf-8'))\n"
                "    sys.exit(1)\n";
            args = @[@"-I", @"-S", @"-B", @"-c", check, path];
            break;
        }
        case Language::JavaScript:
            args = @[@"-u", @"NODE_OPTIONS", tool, @"--check", path];
            tool = @"/usr/bin/env";
            script = ScriptDiagnostic::Node;
            break;

        case Language::Go:
            args = @[@"-e", @"-l", path];
            break;

        case Language::Swift:
            args = @[@"-frontend", @"-parse", @"-color-diagnostics", path];
            break;

        case Language::Bash:
            args = @[@"-p", @"-n", path];
            script = ScriptDiagnostic::Shell;
            break;

        case Language::Zsh:
            args = @[@"-dfn", path];
            script = ScriptDiagnostic::Shell;
            break;

        case Language::Fish:
            args = @[@"--no-config", @"--no-execute", path];
            script = ScriptDiagnostic::Shell;
            break;

        case Language::Ruby:
            args = @[@"--disable-gems", @"--disable=rubyopt", @"-c", path];
            script = ScriptDiagnostic::Shell;
            break;

        case Language::PHP:
            args = @[@"-n", @"-l", path];
            script = ScriptDiagnostic::PHP;
            break;

        case Language::Lua:
            args = @[@"-p", path];
            script = ScriptDiagnostic::Shell;
            break;

        case Language::Odin:
            args = @[@"check", odinPackage ? directory.path : path, @"-no-entry-point", @"-error-pos-style:unix", @"-terse-errors"];
            if (!odinPackage)
                args = [args arrayByAddingObject:@"-file"];

            break;

        case Language::Zig:
            args = @[@"ast-check", path];
            break;

        default:
            return;
        }
    }

    if (script) {
        std::string out, errors;
        int status = RunCommand(tool, args, directory, nullptr, stop, log, nullptr, nil, nullptr, &out, &errors);
        if (status > 0 && !stop.load(std::memory_order_relaxed)) {
            auto issue = FindScriptIssue(errors, UTF8View(path), *script);
            if (issue.message.empty())
                issue = FindScriptIssue(out, UTF8View(path), *script);

            LogSyntaxIssue(log, issue, file, name, *script == ScriptDiagnostic::Node);
        }

        return;
    }

    bool bytes = is_c_family(language) || language == Language::Go || language == Language::Swift ||
                 language == Language::Zig || language == Language::Odin;
    DiagnosticContext diagnostics{input, file, directory, name, bytes, language, mirror};
    RunCommand(tool, args, directory, &diagnostics, stop, log);
}

static void RunSource(Language language, NSURL *file, NSString *name, NSString *text, NSURL *workingFolder,
                      const std::atomic_bool &stop, RunLog &log, ProgramInput &inputChannel, void (^ready)(void))
{
    NSString *toolName = ToolName(language);
    if (!toolName) {
        LogStatus(log, @"This file type cannot be run.\n", OutputTone::Error);
        return;
    }
    if (!file && !text) {
        LogStatus(log, @"Save this file before running it.\n", OutputTone::Error);
        return;
    }
    NSURL *directory = file.URLByDeletingLastPathComponent;
    NSString *extension = file.pathExtension.lowercaseString;
    NSString *tool = nil, *launcher = nil;
    bool build = is_c_family(language) || language == Language::Rust || language == Language::Swift ||
        language == Language::Go || language == Language::Odin || language == Language::Assembly;
    bool kotlin = language == Language::Kotlin && ![extension isEqualToString:@"kts"];
    bool mono = false;
    bool dotnet = false;
    if (language == Language::Python) {
        tool = FindPython(workingFolder);
    } else if (language == Language::TypeScript || language == Language::JSX || language == Language::TSX) {
        tool = FindTSX(directory, workingFolder);
    } else if (language == Language::CSharp) {
        if ([extension isEqualToString:@"csx"]) {
            toolName = @"csi";
        } else {
            tool = FindTool(@"dotnet", language);
            dotnet = tool != nil;
            if (!tool) {
                tool = FindTool(@"mcs", language);
                launcher = FindTool(@"mono", language);
                mono = tool && launcher;
                build = mono;
                if (!mono)
                    tool = nil;
            }
        }
    } else if (language == Language::VisualBasic) {
        LogStatus(log, @"Open a file in a Visual Basic .NET project to run it.\n", OutputTone::Error);
        return;
    }
    if (kotlin) {
        launcher = GetTool(@"java", Language::Java, log);
        if (!launcher)
            return;
        build = true;
    }
    if (!tool)
        tool = GetTool(toolName, language, log);
    if (!tool)
        return;

    RunFiles files;
    NSError *error = nil;
    if (text || build)
        files.folder = TemporaryFolder(&error);
    if ((text || build) && !files.folder) {
        LogStatus(log, [NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return;
    }
    NSURL *input = file;
    if (text) {
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (data)
            input = WriteRunSource(files, data, language == Language::Go || dotnet ? nil : directory,
                                   SourceSuffix(language, file), &error);
        else
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
        if (!input || !data) {
            LogStatus(log, [NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
            return;
        }
    }
    NSURL *includes = directory ? directory : files.folder;
    directory = workingFolder ? workingFolder : directory ? directory : files.folder;
    NSString *path = input.path;
    DiagnosticContext diagnostics{input, file, directory, name,
        is_c_family(language) || language == Language::Go || language == Language::Zig || language == Language::Assembly, language};
    if (dotnet) {
        BuildAndRunDotNet(tool, input, directory, diagnostics, stop, log, inputChannel, ready);
        return;
    }
    if (!build) {
        diagnostics.runtimeLocations = language == Language::Python || is_javascript_family(language);
        bool diagnosticsInOutput = diagnostics.runtimeLocations || language == Language::Java || language == Language::Kotlin ||
            language == Language::Zig || language == Language::Dart || language == Language::CSharp || language == Language::FSharp;
        RunProgram(tool, ScriptArguments(language, path), directory, stop, log, inputChannel, ready,
                   diagnosticsInOutput ? &diagnostics : nullptr);
        return;
    }

    NSString *program = [files.folder URLByAppendingPathComponent:kotlin ? @"program.jar" : mono ? @"program.exe" : @"program"].path;
    NSArray<NSString *> *arguments;
    if (kotlin) {
        arguments = @[path, @"-include-runtime", @"-d", program];
    } else if (mono) {
        arguments = @[[@"-out:" stringByAppendingString:program], path];
    } else {
        arguments = NativeSourceArguments(language, path, program, includes, !text && [file.pathExtension isEqualToString:@"odin"], false);
    }
    if (!BuildProgram(tool, arguments, directory, diagnostics, stop, log))
        return;
    if (language == Language::Go && ![NSFileManager.defaultManager isExecutableFileAtPath:program]) {
        LogStatus(log, @"A Go program needs package main and a main function.\n", OutputTone::Error);
        return;
    }
    if (launcher)
        RunProgram(launcher, kotlin ? @[@"-jar", program] : @[program], directory, stop, log, inputChannel, ready);
    else
        RunProgram(program, @[], directory, stop, log, inputChannel, ready);
}

static DebugExecutable *BuildDebugExecutable(RunProject project, Language language, NSURL *file,
                                             const std::atomic_bool &stop, RunLog &log)
{
    if (!file || !DebuggableLanguage(language, file)) {
        LogStatus(log, @"Open a source file that supports debugging or choose Debug Executable.\n", OutputTone::Error);
        return nil;
    }
    NSURL *directory = project.folder ? project.folder : file.URLByDeletingLastPathComponent;
    if (language == Language::CommonLisp || language == Language::Python) {
        NSString *tool = language == Language::Python ? FindPython(directory) : nil;
        if (!tool)
            tool = GetTool(ToolName(language), language, log);

        if (!tool || stop.load(std::memory_order_relaxed))
            return nil;

        DebugBackend backend = language == Language::CommonLisp ? DebugBackend::SBCL : DebugBackend::Debugpy;
        return [[DebugExecutable alloc] initWithFile:file directory:directory backend:backend interpreter:tool];
    }

    RunFiles files;
    NSURL *program = nil;
    if (project.kind == RunKind::NativeProject) {
        program = BuildNativeProject(directory, file, file.lastPathComponent, files, true, stop, log);
    } else if (project.kind == RunKind::Cargo) {
        directory = project.manifest.URLByDeletingLastPathComponent;
        program = RunCargo(project.manifest, file, stop, log, nullptr, nil);
    } else if (project.kind == RunKind::SwiftPackage) {
        program = BuildSwiftPackage(project, file, stop, log, true);
    } else {
        NSString *tool = GetTool(language == Language::Assembly ? @"clang" : ToolName(language), language, log);
        if (!tool)
            return nil;
        NSError *error = nil;
        files.folder = TemporaryFolder(&error);
        if (!files.folder) {
            LogStatus(log, [error.localizedDescription stringByAppendingString:@"\n"], OutputTone::Error);
            return nil;
        }
        program = [files.folder URLByAppendingPathComponent:@"program"];
        NSURL *sourceDirectory = file.URLByDeletingLastPathComponent;
        NSArray *arguments;
        if (project.kind == RunKind::GoModule) {
            directory = sourceDirectory;
            bool test = [file.lastPathComponent hasSuffix:@"_test.go"];
            arguments = GoBuildArguments(@".", program.path, test, true);
        } else {
            arguments = NativeSourceArguments(language, file.path, program.path, sourceDirectory,
                                              project.kind == RunKind::OdinPackage, true);
        }
        DiagnosticContext diagnostics{file, file, directory, file.lastPathComponent,
            is_c_family(language) || language == Language::Go || language == Language::Zig, language};
        if (!BuildProgram(tool, arguments, directory, diagnostics, stop, log))
            return nil;
    }
    if (!program || stop.load(std::memory_order_relaxed))
        return nil;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:program.path]) {
        LogStatus(log, @"The build did not produce an executable.\n", OutputTone::Error);
        return nil;
    }
    DebugExecutable *artifact = [[DebugExecutable alloc] initWithFile:program directory:directory];
    artifact.scratch = files.folder;
    files.folder = nil;
    return artifact;
}

// Track live runs on the main thread, including runs whose source tabs have closed.
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
    std::atomic_bool _stopped;
    ProgramInput _inputChannel;
    RunDelivery _delivery;
}

- (void)startJob:(dispatch_block_t (^)(void))work qos:(qos_class_t)qos cancelled:(dispatch_block_t)cancelled
{
    if (stoppingRunsForQuit) {
        [self stop];
        dispatch_async(dispatch_get_main_queue(), cancelled);
        return;
    }
    if (!activeRuns) {
        activeRuns = dispatch_group_create();
        activeRunners = [[NSMutableSet alloc] init];
    }
    [activeRunners addObject:self];
    dispatch_group_async(activeRuns, dispatch_get_global_queue(qos, 0), ^{
        @autoreleasepool {
            dispatch_block_t finish = work();
            dispatch_async(dispatch_get_main_queue(), ^{
                [activeRunners removeObject:self];
                finish();
            });
        }
    });
}

- (void)startProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
         workingText:(NSString *)text output:(RunOutput)output finished:(void (^)(void))finished
{
    NSString *snapshot = [text copy];
    void (^ready)(void) = self.inputReady;
    [self startJob:^dispatch_block_t {
        RunLog log{};
        log.owner = self;
        log.delivery = &self->_delivery;
        log.output = output;
        switch (project.kind) {
            case RunKind::Cargo:
                RunCargo(project.manifest, file, self->_stopped, log, &self->_inputChannel, ready);
                break;
            case RunKind::NativeProject:
                RunNativeProject(project.folder, file, name, self->_stopped, log, self->_inputChannel, ready);
                break;
            case RunKind::GoModule:
                RunGoModule(project, file, self->_stopped, log, self->_inputChannel, ready);
                break;
            case RunKind::SwiftPackage:
                RunSwiftPackage(project, file, self->_stopped, log, self->_inputChannel, ready);
                break;
            case RunKind::DotNet:
                RunDotNetProject(project, language, file, self->_stopped, log, self->_inputChannel, ready);
                break;
            case RunKind::Script: case RunKind::Source: case RunKind::OdinPackage:
                RunSource(language, file, name, snapshot,
                          project.kind == RunKind::OdinPackage ? nil : project.folder,
                          self->_stopped, log, self->_inputChannel, ready);
                break;
        }
        if (self->_stopped.load(std::memory_order_relaxed)) {
            LogStatus(log, @"Stopped.\n");
        } else if (int code = log.programExitCode; code >= 0) {
            LogStatus(log, [NSString stringWithFormat:@"Process exited with code %d.\n", code],
                       code == 0 ? OutputTone::Text : OutputTone::Error);
        }
        SendLog(log, true);
        return finished;
    } qos:QOS_CLASS_USER_INITIATED cancelled:finished];
}

- (void)checkProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
                 sources:(std::vector<CheckSource>)sources cache:(RustCheckCache *)cache finished:(CheckFinished)finished
{
    auto *snapshot = new std::vector<CheckSource>(std::move(sources));
    [self startJob:^dispatch_block_t {
        RunLog log{};
        log.checking = true;
        if (project.kind == RunKind::Cargo)
            CheckCargo(project.manifest, file, name, *snapshot, cache, self->_stopped, log);
        else if (language == Language::Rust)
            CheckRustFile(file, name, snapshot->empty() ? nil : snapshot->front().text, self->_stopped, log);
        else
            CheckSourceFile(project, language, file, name, *snapshot, self->_stopped, log);

        delete snapshot;
        if (self.isStopped)
            return ^{ finished({}); };

        log.messages.erase(log.messages.begin(), log.messages.begin() + log.first);
        auto *result = new CheckResult{std::move(log.messages), log.errors, log.warnings};
        return ^{
            finished(std::move(*result));
            delete result;
        };
    } qos:QOS_CLASS_UTILITY cancelled:^{
        delete snapshot;
        finished({});
    }];
}

- (void)buildDebugProject:(RunProject)project language:(Language)language file:(NSURL *)file
                   output:(RunOutput)output finished:(void (^)(DebugExecutable *))finished
{
    [self startJob:^dispatch_block_t {
        RunLog log{};
        log.owner = self;
        log.delivery = &self->_delivery;
        log.output = output;
        DebugExecutable *program = BuildDebugExecutable(project, language, file, self->_stopped, log);
        if (self.isStopped)
            LogStatus(log, @"Stopped.\n");
        SendLog(log, true);
        return ^{ finished(program); };
    } qos:QOS_CLASS_USER_INITIATED cancelled:^{ finished(nil); }];
}

- (BOOL)isStopped { return _stopped.load(std::memory_order_relaxed); }

- (void)stop
{
    _stopped.store(true, std::memory_order_relaxed);
    SetProgramInput(_inputChannel, false);
}

- (BOOL)sendInput:(NSString *)text
{
    return QueueProgramInput(_inputChannel, UTF8View(text));
}

@end
