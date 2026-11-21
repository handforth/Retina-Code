#import "Runner.h"
#import "Preferences.h"
#import "Workspace.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iterator>
#include <memory>
#include <mutex>
#include <string>

#include <crt_externs.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

static bool ExistingFile(NSURL *url)
{
    NSNumber *regular = nil;
    return [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] && regular.boolValue;
}

static NSURL *ParentManifest(NSURL *directory, NSURL *limit, NSString *name)
{
    while (directory.path.length) {
        NSURL *manifest = [directory URLByAppendingPathComponent:name];
        if (ExistingFile(manifest))
            return manifest;
        if ([directory.path isEqualToString:limit.path] || [directory.path isEqualToString:@"/"])
            break;
        directory = directory.URLByDeletingLastPathComponent;
    }
    return nil;
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

    if (language == Language::Rust || (language == Language::Plain && !file && folder)) {
        if (NSURL *manifest = ParentManifest(directory, limit, @"Cargo.toml"))
            return {RunKind::Cargo, folder ? folder : manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (language == Language::Go && file) {
        if (NSURL *manifest = ParentManifest(directory, limit, @"go.mod"))
            return {RunKind::GoModule, manifest.URLByDeletingLastPathComponent, manifest};
    }
    if (language == Language::Swift && file) {
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
    if (folder && (CFamily(language) || (language == Language::Plain && !file)))
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
        TokenizeLine(row, language, state, tokens);
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
            } else if (IsASCIIIdentifierStart(unit)) {
                size_t first = i - 1;
                while (i < row.size() && IsASCIIIdentifierPart(row[i]))
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

static NSString *ToolName(Language language)
{
    switch (language) {
        case Language::C: case Language::ObjectiveC: return @"clang";
        case Language::Cpp: case Language::ObjectiveCpp: return @"clang++";
        case Language::Python: return @"python3";
        case Language::Rust: return @"rustc";
        case Language::JavaScript: case Language::TypeScript: return @"node";
        case Language::JSX: case Language::TSX: return @"tsx";
        case Language::CSharp: case Language::FSharp: case Language::VisualBasic: return @"dotnet";
        case Language::Java: return @"java";
        case Language::Kotlin: return @"kotlinc";
        case Language::Swift: return @"swiftc";
        case Language::Go: return @"go";
        case Language::Odin: return @"odin";
        case Language::Zig: return @"zig";
        case Language::Dart: return @"dart";
        case Language::Ruby: return @"ruby";
        case Language::PHP: return @"php";
        case Language::Perl: return @"perl";
        case Language::Lua: return @"lua";
        case Language::Luau: return @"luau";
        case Language::Bash: return @"bash";
        case Language::Zsh: return @"zsh";
        case Language::Fish: return @"fish";
        case Language::PowerShell: return @"pwsh";
        case Language::R: return @"Rscript";
        case Language::Julia: return @"julia";
        case Language::Scala: return @"scala";
        case Language::Groovy: return @"groovy";
        case Language::Haskell: return @"runghc";
        case Language::Elixir: return @"elixir";
        case Language::Clojure: return @"clojure";
        case Language::CommonLisp: return @"sbcl";
        default: return nil;
    }
}

bool RunnableLanguage(Language language)
{
    return ToolName(language) != nil;
}

static NSString *SourceSuffix(Language language, NSURL *file)
{
    NSString *ext = file.pathExtension.lowercaseString;
    switch (language) {
        case Language::C: return @".c";
        case Language::Cpp: return @".cpp";
        case Language::ObjectiveC: return @".m";
        case Language::ObjectiveCpp: return @".mm";
        case Language::Python: return @".py";
        case Language::Rust: return @".rs";
        case Language::JavaScript:
            return [@[@"mjs", @"cjs"] containsObject:ext] ? [@"." stringByAppendingString:ext] : @".js";
        case Language::TypeScript:
            return [@[@"mts", @"cts"] containsObject:ext] ? [@"." stringByAppendingString:ext] : @".ts";
        case Language::JSX: return @".jsx";
        case Language::TSX: return @".tsx";
        case Language::CSharp: return [ext isEqualToString:@"csx"] ? @".csx" : @".cs";
        case Language::FSharp: return @".fsx";
        case Language::Java: return @".java";
        case Language::Kotlin: return [ext isEqualToString:@"kts"] ? @".kts" : @".kt";
        case Language::Swift: return @".swift";
        case Language::Go: return @".go";
        case Language::Odin: return @".odin";
        case Language::Zig: return @".zig";
        case Language::Dart: return @".dart";
        case Language::Ruby: return @".rb";
        case Language::PHP: return @".php";
        case Language::Perl: return @".pl";
        case Language::Lua: return @".lua";
        case Language::Luau: return @".luau";
        case Language::Bash: return @".sh";
        case Language::Zsh: return @".zsh";
        case Language::Fish: return @".fish";
        case Language::PowerShell: return @".ps1";
        case Language::R: return @".R";
        case Language::Julia: return @".jl";
        case Language::Scala: return [ext isEqualToString:@"sc"] ? @".sc" : @".scala";
        case Language::Groovy: return @".groovy";
        case Language::Haskell: return @".hs";
        case Language::Elixir: return @".exs";
        case Language::Clojure: return @".clj";
        case Language::CommonLisp: return @".lisp";
        default: return @"";
    }
}

static NSString *ExecutableAt(NSString *folder, NSString *name)
{
    if (!folder.isAbsolutePath)
        return nil;
    NSString *candidate = [folder stringByAppendingPathComponent:name];
    BOOL directory = NO;
    NSFileManager *files = NSFileManager.defaultManager;
    return [files fileExistsAtPath:candidate isDirectory:&directory] && !directory &&
        [files isExecutableFileAtPath:candidate] ? candidate : nil;
}

static NSString *FindTool(NSString *name, Language language)
{
    NSString *path = NSProcessInfo.processInfo.environment[@"PATH"];
    for (NSString *folder in [path componentsSeparatedByString:@":"]) {
        if (NSString *tool = ExecutableAt(folder, name))
            return tool;
    }
    for (NSString *folder in @[@"/opt/homebrew/bin", @"/usr/local/bin", @"/usr/bin", @"/bin"]) {
        if (NSString *tool = ExecutableAt(folder, name))
            return tool;
    }
    if (language == Language::Go)
        return ExecutableAt(@"/usr/local/go/bin", name);
    if (language == Language::Rust)
        return ExecutableAt([NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin"], name);
    if (language == Language::Odin) {
        if (NSString *tool = ExecutableAt(NSProcessInfo.processInfo.environment[@"ODIN_ROOT"], name))
            return tool;
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

static NSURL *TemporaryFolder(NSError **error)
{
    NSString *name = [NSTemporaryDirectory() stringByAppendingPathComponent:@"RetinaCode-XXXXXX"];
    std::string path(name.fileSystemRepresentation);
    if (mkdtemp(path.data()))
        return [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:YES relativeToURL:nil];
    *error = RunError(errno);
    return nil;
}

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

static void AddOutputColors(std::vector<OutputColorSpan> &spans, NSRange range, OutputColors colors)
{
    if (!range.length || colors == OutputColors{})
        return;
    if (!spans.empty() && spans.back().colors == colors && NSMaxRange(spans.back().range) == range.location)
        spans.back().range.length += range.length;
    else
        spans.push_back({range, colors});
}

static std::string_view TakeColorParameter(std::string_view &parameters, char separator)
{
    size_t end = parameters.find(separator);
    std::string_view parameter = parameters.substr(0, end);
    if (end == std::string_view::npos)
        parameters = {};
    else
        parameters.remove_prefix(end + 1);
    return parameter;
}

static int ColorParameter(std::string_view text)
{
    if (text.empty())
        return -1;
    int number = 0;
    for (char digit : text) {
        if (digit < '0' || digit > '9')
            return -1;
        number = number * 10 + (digit - '0');
        if (number > 255)
            return -1;
    }
    return number;
}

static uint32_t ExtendedOutputColor(std::string_view &parameters, char separator)
{
    int kind = ColorParameter(TakeColorParameter(parameters, separator));
    if (kind == 5) {
        int value = ColorParameter(TakeColorParameter(parameters, separator));
        return value < 0 ? defaultOutputColor : outputPaletteStart + uint32_t(value);
    }
    if (kind != 2)
        return defaultOutputColor;
    // Colon notation can include a color space field before the RGB components.
    if (separator == ':' && std::count(parameters.begin(), parameters.end(), ':') >= 3)
        TakeColorParameter(parameters, separator);
    int red = ColorParameter(TakeColorParameter(parameters, separator));
    int green = ColorParameter(TakeColorParameter(parameters, separator));
    int blue = ColorParameter(TakeColorParameter(parameters, separator));
    if (red < 0 || green < 0 || blue < 0)
        return defaultOutputColor;
    return uint32_t((red << 16) | (green << 8) | blue);
}

struct TerminalDecoder {
    enum class State { Text, Escape, EscapeSuffix, CSI, ControlString, StringEscape };
    State state = State::Text;
    std::array<char, 64> parameters;
    size_t parameterCount = 0;
    OutputColors colors;
    bool sawSGR = false;

    void applySGR(std::string_view values)
    {
        sawSGR = true;
        do {
            std::string_view value = TakeColorParameter(values, ';');
            bool colon = value.find(':') != std::string_view::npos;
            auto mode = TakeColorParameter(value, ':');
            int code = mode.empty() ? 0 : ColorParameter(mode);
            if (code == 0) {
                colors = {};
            } else if (code == 39) {
                colors.foreground = defaultOutputColor;
            } else if (code == 49) {
                colors.background = defaultOutputColor;
            } else if (code == 38 || code == 48) {
                uint32_t color = colon ? ExtendedOutputColor(value, ':') : ExtendedOutputColor(values, ';');
                if (color != defaultOutputColor)
                    (code == 38 ? colors.foreground : colors.background) = color;
            } else if (code >= 30 && code <= 37) {
                colors.foreground = outputPaletteStart + uint32_t(code - 30);
            } else if (code >= 40 && code <= 47) {
                colors.background = outputPaletteStart + uint32_t(code - 40);
            } else if (code >= 90 && code <= 97) {
                colors.foreground = outputPaletteStart + uint32_t(code - 82);
            } else if (code >= 100 && code <= 107) {
                colors.background = outputPaletteStart + uint32_t(code - 92);
            }
        } while (values.data()); // An empty parameter still means reset.
    }

    void readControl(unichar character)
    {
        switch (state) {
            case State::Text:
                if (character == 0x1B)
                    state = State::Escape;
                break;
            case State::Escape:
                if (character == '[') {
                    state = State::CSI;
                    parameterCount = 0;
                } else if (character == ']' || character == 'P' || character == 'X' || character == '^' || character == '_') {
                    state = State::ControlString;
                } else if (character >= 0x20 && character <= 0x2F) {
                    state = State::EscapeSuffix;
                } else if (character != 0x1B) {
                    state = State::Text;
                }
                break;
            case State::EscapeSuffix:
                if (character == 0x1B)
                    state = State::Escape;
                else if (character < 0x20 || character > 0x2F)
                    state = State::Text;
                break;
            case State::CSI:
                if (character == 0x1B) {
                    state = State::Escape;
                } else if (character >= 0x40 && character <= 0x7E) {
                    if (character == 'm' && parameterCount <= parameters.size())
                        applySGR({parameters.data(), parameterCount});
                    state = State::Text;
                } else if (parameterCount < parameters.size() &&
                           ((character >= '0' && character <= '9') || character == ';' || character == ':')) {
                    parameters[parameterCount++] = char(character);
                } else {
                    parameterCount = parameters.size() + 1;
                }
                break;
            case State::ControlString:
                if (character == '\a')
                    state = State::Text;
                else if (character == 0x1B)
                    state = State::StringEscape;
                break;
            case State::StringEscape:
                if (character == '\\' || character == '\a')
                    state = State::Text;
                else if (character != 0x1B)
                    state = State::ControlString;
                break;
        }
    }

    RunMessage decode(NSString *source)
    {
        static NSCharacterSet *const controlCharacters = [] {
            auto set = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0, 32)];
            [set removeCharactersInString:@"\t\n"];
            [set addCharactersInString:@"\u007F"];
            return [set copy];
        }();
        RunMessage result{};
        NSUInteger length = source.length;
        NSMutableString *text = nil;
        for (NSUInteger at = 0; at < length;) {
            if (state == State::Text) {
                NSRange search = NSMakeRange(at, length - at);
                NSRange control = [source rangeOfCharacterFromSet:controlCharacters options:0 range:search];
                NSUInteger end = control.location == NSNotFound ? length : control.location;
                if (!at && end == length) {
                    result.text = source;
                    AddOutputColors(result.colorSpans, NSMakeRange(0, length), colors);
                    break;
                }
                if (!text)
                    text = [NSMutableString stringWithCapacity:length];
                if (end > at) {
                    AddOutputColors(result.colorSpans, NSMakeRange(text.length, end - at), colors);
                    [text appendString:[source substringWithRange:NSMakeRange(at, end - at)]];
                    at = end;
                }
                if (at == length)
                    break;
            }
            unichar character = [source characterAtIndex:at++];
            if (character == '\n') {
                // A malformed escape must not swallow the next line of the log.
                state = State::Text;
                if (!text)
                    text = [NSMutableString stringWithCapacity:length];
                AddOutputColors(result.colorSpans, NSMakeRange(text.length, 1), colors);
                [text appendString:@"\n"];
            } else {
                readControl(character);
            }
        }
        if (text)
            result.text = text;
        result.usesTerminalColors = sawSGR;
        return result;
    }
};

static void ReplaceOutputText(RunMessage &message, NSRange range, NSString *replacement)
{
    NSUInteger replacementLength = replacement.length;
    NSUInteger end = NSMaxRange(range);
    auto offset = [&](NSUInteger index) {
        if (index <= range.location)
            return index;
        if (index < end)
            return range.location + std::min(index - range.location, replacementLength);
        return index - range.length + replacementLength;
    };
    for (auto &span : message.colorSpans) {
        NSUInteger start = offset(span.range.location);
        span.range = NSMakeRange(start, offset(NSMaxRange(span.range)) - start);
    }
    std::erase_if(message.colorSpans, [](const OutputColorSpan &span) { return !span.range.length; });
    message.text = [message.text stringByReplacingCharactersInRange:range withString:replacement];
}

struct DiagnosticContext {
    NSURL *input;
    NSURL *original;
    NSURL *directory;
    NSString *name;
    bool byteColumns;
    Language language = Language::C;
};

static OutputTone ToneForLine(NSString *line, bool stderrLine)
{
    auto starts = [&](NSString *prefix) {
        return [line rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound;
    };
    if (starts(@"warning:") || starts(@"warning[") ||
        (stderrLine && [line rangeOfString:@"warning:" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        [line hasSuffix:@" warning generated.\n"] || [line hasSuffix:@" warnings generated.\n"])
        return OutputTone::Warning;
    if (starts(@"note:") || starts(@"help:") || starts(@"In file included from "))
        return OutputTone::Text;
    return stderrLine || starts(@"error:") || starts(@"fatal error:") ? OutputTone::Error : OutputTone::Text;
}

static RunMessage CompilerMessage(RunMessage message, const DiagnosticContext &context, bool stderrLine)
{
    NSString *line = message.text;
    static NSRegularExpression *diagnostic = [NSRegularExpression regularExpressionWithPattern:
        @"^(.+?):([0-9]+)(?::([0-9]+))?:((?:\\{[^}]*\\}:)*)[ \\t]*((?:(?:fatal|syntax) )?error|warning|note|help)(?:\\[[^\\]]*\\])?:"
        options:NSRegularExpressionCaseInsensitive error:nil];
    static NSRegularExpression *goDiagnostic = [NSRegularExpression regularExpressionWithPattern:
        @"^(.+?\\.go):([0-9]+)(?::([0-9]+))?:[ \\t]*(.+)" options:0 error:nil];
    static NSRegularExpression *dotnetDiagnostic = [NSRegularExpression regularExpressionWithPattern:
        @"^(.+?)\\(([0-9]+),([0-9]+)(?:,[0-9]+,[0-9]+)?\\):[ \\t]*(error|warning)\\b"
        options:NSRegularExpressionCaseInsensitive error:nil];
    static NSRegularExpression *kotlinDiagnostic = [NSRegularExpression regularExpressionWithPattern:
        @"^[ewi]:[ \\t]*(.+?):([0-9]+):([0-9]+)(?::)?[ \\t]+(.+)"
        options:0 error:nil];
    enum class Format { Standard, Go, DotNet, Kotlin };
    Format format = Format::Standard;
    NSRange whole = NSMakeRange(0, line.length);
    auto match = [diagnostic firstMatchInString:line options:0 range:whole];
    if (!match && context.language == Language::Go) {
        format = Format::Go;
        match = [goDiagnostic firstMatchInString:line options:0 range:whole];
    } else if (!match && (context.language == Language::CSharp || context.language == Language::FSharp ||
                          context.language == Language::VisualBasic)) {
        format = Format::DotNet;
        match = [dotnetDiagnostic firstMatchInString:line options:0 range:whole];
    } else if (!match && context.language == Language::Kotlin) {
        format = Format::Kotlin;
        match = [kotlinDiagnostic firstMatchInString:line options:0 range:whole];
    }
    if (!match) {
        message.tone = ToneForLine(line, stderrLine);
        return message;
    }
    auto field = [&](NSUInteger index) -> NSString * {
        NSRange range = [match rangeAtIndex:index];
        return range.location == NSNotFound ? @"" : [line substringWithRange:range];
    };
    NSString *path = field(1);
    NSString *severity = format == Format::Standard ? field(5).lowercaseString :
        format == Format::DotNet ? field(4).lowercaseString :
        format == Format::Kotlin && [line hasPrefix:@"w:"] ? @"warning" :
        format == Format::Kotlin && [line hasPrefix:@"i:"] ? @"note" : @"error";
    message.tone = [severity hasSuffix:@"error"] ? OutputTone::Error :
                      [severity isEqualToString:@"warning"] ? OutputTone::Warning : OutputTone::Text;
    if ([path hasPrefix:@"<"])
        return message;

    NSURL *url = [path hasPrefix:@"file://"] ? [NSURL URLWithString:path] :
        [NSURL fileURLWithPath:path isDirectory:NO relativeToURL:context.directory].URLByStandardizingPath;
    if (!url.isFileURL)
        return message;
    bool current = [url isEqual:context.input.URLByStandardizingPath] ||
                   [url.URLByResolvingSymlinksInPath isEqual:context.input.URLByResolvingSymlinksInPath];
    RunLocation location = {current ? context.original : url, NSUInteger(field(2).integerValue),
                            NSUInteger(field(3).integerValue), 0, 0, current, context.byteColumns};
    NSString *spans = format == Format::Standard ? field(4) : nil;
    if (spans.length) {
        static NSRegularExpression *ranges = [NSRegularExpression regularExpressionWithPattern:
            @"\\{([0-9]+):([0-9]+)-([0-9]+):([0-9]+)\\}" options:0 error:nil];
        for (NSTextCheckingResult *span in [ranges matchesInString:spans options:0 range:NSMakeRange(0, spans.length)]) {
            auto value = [&](NSUInteger i) { return NSUInteger([spans substringWithRange:[span rangeAtIndex:i]].integerValue); };
            if (value(1) == location.line && value(3) == location.line &&
                value(2) <= location.column && value(4) > location.column) {
                location.firstColumn = value(2);
                location.endColumn = value(4);
                break;
            }
        }
    }
    NSString *label = current ? context.name : path;
    NSUInteger start = [match rangeAtIndex:format == Format::Standard ? 5 : 4].location;
    NSMutableString *display = [NSMutableString stringWithFormat:@"%@:%lu", label, (unsigned long)location.line];
    if (location.column)
        [display appendFormat:@":%lu", (unsigned long)location.column];
    NSString *details = [line substringFromIndex:start];
    if (format == Format::Go || format == Format::Kotlin) {
        details = [NSString stringWithFormat:@"%@: %@", severity, details];
        [display appendFormat:@": %@: ", severity];
    } else {
        [display appendString:@": "];
    }
    ReplaceOutputText(message, NSMakeRange(0, start), display);
    message.location = location;
    if (message.tone == OutputTone::Error)
        message.diagnostic = [details stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return message;
}

struct RunLog {
    RunOutput output;
    std::deque<RunMessage> messages;
    NSMutableString *mergedTail = nil;
    std::shared_ptr<std::atomic_uint> deliveries = std::make_shared<std::atomic_uint>(0);
    Clock::time_point nextUpdate{};
    NSUInteger characters = 0;
    int programExitCode = -1;
    bool buildError = false;
    bool discarded = false;

    void append(RunMessage message)
    {
        NSUInteger length = message.text.length;
        if (!length)
            return;
        NSUInteger lines = OutputScrollbackLinesPreference();
        NSUInteger characterLimit = OutputScrollbackCharacterLimit(lines);
        if (length > characterLimit) {
            NSUInteger start = length - characterLimit;
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
            characters = 0;
            discarded = true;
        }
        if (message.diagnostic.length > 2048) {
            NSUInteger end = CFStringIsSurrogateHighCharacter([message.diagnostic characterAtIndex:2047]) ? 2047 : 2048;
            message.diagnostic = [[message.diagnostic substringToIndex:end] stringByAppendingString:@"…"];
        }
        // Coalesce plain lines within a delivery instead of making a text run for every line.
        if (!message.location.line && !messages.empty() && !messages.back().location.line &&
            messages.back().tone == message.tone && messages.back().usesTerminalColors == message.usesTerminalColors &&
            messages.back().text.length + length <= 8192) {
            auto &tail = messages.back();
            NSUInteger start = tail.text.length;
            if (!mergedTail) {
                mergedTail = [tail.text mutableCopy];
                tail.text = mergedTail;
            }
            [mergedTail appendString:message.text];
            for (const auto &span : message.colorSpans)
                AddOutputColors(tail.colorSpans, NSMakeRange(start + span.range.location, span.range.length), span.colors);
        } else {
            mergedTail = nil;
            messages.push_back(std::move(message));
        }
        characters += length;
        // A queued record can be a fragment or several lines. The pane counts complete lines.
        NSUInteger messageLimit = std::max(lines, outputScrollbackLines);
        while (characters > characterLimit || messages.size() > messageLimit) {
            characters -= messages.front().text.length;
            messages.pop_front();
            discarded = true;
        }
    }

    void status(NSString *text, OutputTone tone = OutputTone::Text)
    {
        append({text, tone, {}});
    }

    void send(bool now = false)
    {
        auto time = Clock::now();
        if (messages.empty() || (!now && (time < nextUpdate || deliveries->load(std::memory_order_relaxed))))
            return;
        messages.front().earlierOutputDiscarded = discarded;
        auto batch = std::make_shared<const std::vector<RunMessage>>(std::make_move_iterator(messages.begin()),
                                                                    std::make_move_iterator(messages.end()));
        messages.clear();
        mergedTail = nil;
        characters = 0;
        discarded = false;
        auto active = deliveries;
        active->fetch_add(1, std::memory_order_relaxed);
        RunOutput handler = output;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                handler(*batch);
            }
            active->fetch_sub(1, std::memory_order_relaxed);
        });
        nextUpdate = time + 24ms;
    }
};

static int PrepareDescriptors(int (&ends)[2])
{
    for (int &fd : ends) {
        if (fd <= STDERR_FILENO) {
            int spare = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
            if (spare < 0)
                return errno;
            close(fd);
            fd = spare;
        } else if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
            return errno;
        }
    }
    return 0;
}

struct ProgramInput {
    std::mutex mutex;
    std::string queued;
    bool open = false;

    void setOpen(bool enabled)
    {
        std::lock_guard lock(mutex);
        open = enabled;
        if (!open)
            queued.clear();
    }

    void take(std::string &pending)
    {
        std::lock_guard lock(mutex);
        pending.swap(queued);
    }
};

static NSDictionary *JSONDictionary(std::string_view bytes)
{
    if (bytes.empty() || bytes.front() != '{')
        return nil;
    NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
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
        result = TerminalDecoder{}.decode(rendered);
    rendered = result.text.length ? result.text : nil;
    if (!rendered) {
        result.text = [NSString stringWithFormat:@"%@: %@\n", level, details];
        result.usesTerminalColors = false;
    } else if (![rendered hasSuffix:@"\n"]) {
        rendered = result.text = [rendered stringByAppendingString:@"\n"];
    }
    result.tone = tone;
    if (tone == OutputTone::Error)
        result.diagnostic = details;

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
    file = CanonicalFileURL(file);
    NSUInteger line = [primary[@"line_start"] unsignedIntegerValue];
    NSUInteger column = [primary[@"column_start"] unsignedIntegerValue];
    NSUInteger end = [primary[@"line_end"] unsignedIntegerValue] == line ? [primary[@"column_end"] unsignedIntegerValue] : 0;
    bool current = [file.path isEqualToString:CanonicalFileURL(context.input).path];
    result.location = {current ? context.original : file, line, column, end > column ? column : 0, end, current, false};
    NSString *label = current && context.name.length ? context.name : path;
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

template<typename Emit>
static std::string_view ReceiveDiagnosticRecords(std::string_view bytes, std::string &record, bool &dropping, Emit emit)
{
    constexpr size_t limit = 2 * 1024 * 1024;
    while (!bytes.empty()) {
        size_t newline = bytes.find('\n');
        size_t count = newline == std::string_view::npos ? bytes.size() : newline + 1;
        // A malformed or unusually large compiler record cannot grow the reader indefinitely.
        if (count > limit - record.size()) {
            record.clear();
            dropping = true;
        }
        if (!dropping)
            record.append(bytes.substr(0, count));
        bytes.remove_prefix(count);
        if (newline == std::string_view::npos)
            break;
        bool keepReading = dropping || emit(record);
        record.clear();
        dropping = false;
        if (!keepReading)
            break;
    }
    return bytes;
}

struct CargoSession {
    DiagnosticContext diagnostics;
    ProgramInput &input;
    void (^ready)(void);
    std::string record;
    bool dropping = false;
    bool finished = false;
    bool built = false;
    TerminalDecoder terminal{};

    void emit(std::string_view bytes, RunLog &log)
    {
        NSDictionary *data = JSONDictionary(bytes);
        NSString *reason = data[@"reason"];
        if ([reason isEqualToString:@"build-finished"]) {
            finished = true;
            built = [data[@"success"] boolValue];
            if (built) {
                log.status(@"Build successful\n");
                log.send(true);
                input.setOpen(true);
                if (ready)
                    dispatch_async(dispatch_get_main_queue(), ready);
            }
            return;
        }
        if ([reason isEqualToString:@"compiler-message"]) {
            log.append(RustDiagnostic(data[@"message"], diagnostics, data[@"manifest_path"]));
        } else if (!reason.length && !bytes.empty()) {
            log.append(terminal.decode(ConsoleString(bytes)));
        }
    }

    std::string_view receive(std::string_view bytes, RunLog &log)
    {
        return ReceiveDiagnosticRecords(bytes, record, dropping, [&](std::string_view line) {
            emit(line, log);
            return !finished;
        });
    }
};

struct RunStream {
    int ends[2] = {-1, -1};
    std::string pending;
    OutputTone lineTone = OutputTone::Text;
    bool continued = false;
    bool droppingRecord = false;
    TerminalDecoder terminal{};

    ~RunStream()
    {
        for (int fd : ends) {
            if (fd >= 0)
                close(fd);
        }
    }

    int open()
    {
        if (pipe(ends) != 0)
            return errno;
        return PrepareDescriptors(ends);
    }

    int openTerminal()
    {
        struct winsize size = {24, 80, 0, 0};
        if (openpty(&ends[0], &ends[1], nullptr, nullptr, &size) != 0)
            return errno;
        int error = PrepareDescriptors(ends);
        if (error)
            return error;
        struct termios attributes;
        if (tcgetattr(ends[1], &attributes) != 0)
            return errno;
        // The editable line in Output already echoes what the user types.
        attributes.c_lflag &= ~(ECHO | ECHONL);
        if (tcsetattr(ends[1], TCSANOW, &attributes) != 0 || fcntl(ends[0], F_SETFL, O_NONBLOCK) < 0)
            return errno;
        return 0;
    }

    void emit(std::string_view bytes, const DiagnosticContext *diagnostics, bool stderrLine, RunLog &log)
    {
        if (stderrLine && diagnostics && diagnostics->language == Language::Rust) {
            if (NSDictionary *record = JSONDictionary(bytes)) {
                log.append(RustDiagnostic(record, *diagnostics));
                return;
            }
        }
        RunMessage message = terminal.decode(ConsoleString(bytes));
        if (!message.text.length)
            return;
        if (diagnostics && !continued) {
            message = CompilerMessage(std::move(message), *diagnostics, stderrLine);
            log.buildError |= message.tone == OutputTone::Error && message.location.line != 0;
            lineTone = message.tone;
        } else {
            if (!continued)
                lineTone = ToneForLine(message.text, stderrLine);
            message.tone = lineTone;
        }
        log.append(std::move(message));
        continued = bytes.back() != '\n';
    }

    void flushPartial(bool stderrLine, RunLog &log, const DiagnosticContext *diagnostics = nullptr)
    {
        if (pending.empty())
            return;
        // Leave an incomplete UTF-8 character for the next read.
        size_t end = pending.size(), start = end - 1;
        while (start && (uint8_t(pending[start]) & 0xC0) == 0x80)
            --start;
        uint8_t lead = pending[start];
        size_t width = lead < 0xC2 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : lead < 0xF5 ? 4 : 1;
        if (end - start < width)
            end = start;
        if (end) {
            emit(std::string_view(pending).substr(0, end), diagnostics, stderrLine, log);
            pending.erase(0, end);
        }
    }

    void receive(const char *bytes, size_t length, const DiagnosticContext *diagnostics, bool stderrLine, RunLog &log)
    {
        if (stderrLine && diagnostics && diagnostics->language == Language::Rust) {
            ReceiveDiagnosticRecords({bytes, length}, pending, droppingRecord, [&](std::string_view line) {
                emit(line, diagnostics, stderrLine, log);
                return true;
            });
            return;
        }
        pending.append(bytes, length);
        size_t start = 0;
        for (;;) {
            size_t end = pending.find('\n', start);
            if (end == std::string::npos)
                break;
            emit(std::string_view(pending).substr(start, end + 1 - start), diagnostics, stderrLine, log);
            start = end + 1;
        }
        pending.erase(0, start);
        if (pending.size() >= 16 * 1024)
            flushPartial(stderrLine, log, diagnostics);
    }
};

static int SpawnDirectory(posix_spawn_file_actions_t *actions, NSURL *directory)
{
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *))
        return posix_spawn_file_actions_addchdir(actions, directory.fileSystemRepresentation);
#endif
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return posix_spawn_file_actions_addchdir_np(actions, directory.fileSystemRepresentation);
#pragma clang diagnostic pop
}

static int Spawn(pid_t *pid, NSString *tool, NSArray<NSString *> *arguments, NSURL *directory,
                 RunStream (&pipes)[2], bool interactive)
{
    int error = interactive ? pipes[0].openTerminal() : pipes[0].open();
    if (!error)
        error = pipes[1].open();
    if (error)
        return error;
    posix_spawn_file_actions_t actions = nullptr;
    posix_spawnattr_t attributes = nullptr;
    error = posix_spawn_file_actions_init(&actions);
    if (!error)
        error = posix_spawnattr_init(&attributes);
    if (!error)
        error = SpawnDirectory(&actions, directory);
    if (!error)
        error = interactive ? posix_spawn_file_actions_adddup2(&actions, pipes[0].ends[1], STDIN_FILENO) :
                              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!error)
        error = posix_spawn_file_actions_adddup2(&actions, pipes[0].ends[1], STDOUT_FILENO);
    if (!error)
        error = posix_spawn_file_actions_adddup2(&actions, pipes[1].ends[1], STDERR_FILENO);
    if (!error)
        error = posix_spawnattr_setpgroup(&attributes, 0);
    if (!error) {
        // A dispatch worker can have SIGCHLD blocked. Toolchains need to reap their own children.
        sigset_t allowedSignals;
        sigemptyset(&allowedSignals);
        error = posix_spawnattr_setsigmask(&attributes, &allowedSignals);
    }
    if (!error)
        error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                                                     POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!error) {
        std::vector<const char *> argv{tool.fileSystemRepresentation};
        for (NSString *argument in arguments)
            argv.push_back(argument.fileSystemRepresentation);
        argv.push_back(nullptr);
        error = posix_spawn(pid, argv.front(), &actions, &attributes,
                            const_cast<char **>(argv.data()), *_NSGetEnviron());
    }
    if (attributes)
        posix_spawnattr_destroy(&attributes);
    if (actions)
        posix_spawn_file_actions_destroy(&actions);
    for (RunStream &pipe : pipes) {
        close(pipe.ends[1]);
        pipe.ends[1] = -1;
    }
    return error;
}

static int RunCommand(NSString *tool, NSArray<NSString *> *arguments, NSURL *directory,
                      const DiagnosticContext *diagnostics, const std::atomic_bool &stop, RunLog &log,
                      ProgramInput *input = nullptr, void (^ready)(void) = nil,
                      CargoSession *cargo = nullptr, std::string *capture = nullptr)
{
    if (stop.load(std::memory_order_relaxed))
        return -1;
    RunStream streams[2];
    pid_t child = 0;
    int error = Spawn(&child, tool, arguments, directory, streams, input != nullptr);
    if (error) {
        log.status([NSString stringWithFormat:@"%@: %@\n", tool.lastPathComponent, RunError(error).localizedDescription],
                   OutputTone::Error);
        return -1;
    }
    if (input && !cargo) {
        input->setOpen(true);
        if (ready)
            dispatch_async(dispatch_get_main_queue(), ready);
    }

    std::array<pollfd, 2> watches = {{{streams[0].ends[0], POLLIN, 0}, {streams[1].ends[0], POLLIN, 0}}};
    std::string outgoing;
    int status = 0;
    auto exited = Clock::time_point::max();
    auto forceStop = Clock::time_point::max();
    bool stopping = false;
    for (;;) {
        if (!stopping && stop.load(std::memory_order_relaxed)) {
            stopping = true;
            kill(-child, SIGTERM);
            forceStop = Clock::now() + 300ms;
        }
        if (Clock::now() >= forceStop) {
            kill(-child, SIGKILL);
            forceStop = Clock::time_point::max();
        }
        bool reaped = exited != Clock::time_point::max();
        if (input && !stopping && !reaped && outgoing.empty())
            input->take(outgoing);
        watches[0].events = POLLIN | (!stopping && !reaped && !outgoing.empty() ? POLLOUT : 0);
        int count = poll(watches.data(), watches.size(), reaped ? 0 : 40);
        if (count < 0 && errno != EINTR) {
            error = errno;
            if (!reaped) {
                kill(-child, SIGKILL);
                while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            }
            break;
        }
        if (reaped && (count == 0 || Clock::now() - exited > 150ms))
            break;
        if (count > 0 && (watches[0].revents & POLLOUT)) {
            ssize_t written = write(watches[0].fd, outgoing.data(), outgoing.size());
            if (written > 0)
                outgoing.erase(0, size_t(written));
            else if (written < 0 && errno != EAGAIN && errno != EINTR) {
                outgoing.clear();
                input->setOpen(false);
            }
        }
        @autoreleasepool {
            for (size_t i = 0; count > 0 && i < watches.size(); ++i) {
                if (!(watches[i].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)))
                    continue;
                char bytes[8192];
                ssize_t length = read(watches[i].fd, bytes, sizeof(bytes));
                if (length > 0) {
                    std::string_view received(bytes, size_t(length));
                    if (i == 0 && capture) {
                        constexpr size_t limit = 8 * 1024 * 1024;
                        if (capture->size() < limit)
                            capture->append(received.substr(0, limit - capture->size()));
                        continue;
                    }
                    if (i == 0 && cargo && !cargo->finished)
                        received = cargo->receive(received, log);
                    if (!received.empty())
                        streams[i].receive(received.data(), received.size(), diagnostics, i == 1, log);
                } else if (!length || (errno != EINTR && errno != EAGAIN)) {
                    watches[i].fd = -1;
                }
            }
            if ((!diagnostics || input) && count == 0) {
                for (size_t i = 0; i < watches.size(); ++i)
                    streams[i].flushPartial(i == 1, log);
            }
            log.send();
        }
        if (!reaped) {
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child)
                exited = Clock::now();
            else if (result < 0 && errno != EINTR) {
                error = errno;
                break;
            }
        }
    }
    if (input)
        input->setOpen(false);
    if (stopping)
        kill(-child, SIGKILL);
    for (size_t i = 0; i < watches.size(); ++i) {
        auto &stream = streams[i];
        if (!stream.pending.empty() || stream.continued) {
            stream.pending.push_back('\n');
            stream.emit(stream.pending, diagnostics, i == 1, log);
        }
    }
    if (error) {
        log.status([NSString stringWithFormat:@"%@\n", RunError(error).localizedDescription], OutputTone::Error);
        return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void RunProgram(NSString *program, NSArray<NSString *> *arguments, NSURL *directory,
                       const std::atomic_bool &stop, RunLog &log, ProgramInput &input, void (^ready)(void),
                       const DiagnosticContext *diagnostics = nullptr)
{
    int result = RunCommand(program, arguments, directory, diagnostics, stop, log, &input, ready);
    if (result > 0 && diagnostics && log.buildError)
        log.status(@"Build failed.\n", OutputTone::Error);
    else
        log.programExitCode = result;
}

static NSString *GetTool(NSString *name, Language language, RunLog &log)
{
    NSString *tool = FindTool(name, language);
    if (!tool)
        log.status([NSString stringWithFormat:@"%@ was not found.\n", name], OutputTone::Error);
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

static NSArray<NSString *> *NativeFlags(Language language)
{
    bool cpp = CPlusPlus(language);
    NSString *kind = Objective(language) ? (cpp ? @"objective-c++" : @"objective-c") : (cpp ? @"c++" : @"c");
    return @[@"-x", kind, cpp ? @"-std=c++20" : @"-std=c17", @"-Wall", @"-Wextra",
             @"-fcolor-diagnostics", @"-fno-caret-diagnostics", @"-fdiagnostics-print-source-range-info"];
}

static void RunNativeProject(NSURL *folder, NSURL *file, NSString *name, const std::atomic_bool &stop,
                             RunLog &log, ProgramInput &input, void (^ready)(void))
{
    auto sources = SelectNativeSources(folder, CanonicalFileURL(file), stop);
    if (stop.load(std::memory_order_relaxed))
        return;
    if (sources.files.empty()) {
        log.status(sources.error, OutputTone::Error);
        return;
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
        return;

    RunFiles files;
    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    if (!files.folder) {
        log.status([NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return;
    }
    NSURL *program = [files.folder URLByAppendingPathComponent:@"program"];
    NSArray<NSString *> *includes = @[@"-I", sources.directory.path,
        @"-I", [folder URLByAppendingPathComponent:@"include" isDirectory:YES].path, @"-I", folder.path];
    NSURL *active = CanonicalFileURL(file);
    DiagnosticContext diagnostics{active, active, folder, name, true};
    log.status(@"Building...\n");
    log.send(true);

    int result = 0;
    if (mixed) {
        NSMutableArray<NSString *> *objects = [NSMutableArray arrayWithCapacity:sources.files.size() + 2];
        for (const auto &unit : sources.files) {
            bool cplusplus = CPlusPlus(unit.language);
            NSString *object = [files.folder URLByAppendingPathComponent:
                [NSString stringWithFormat:@"%lu.o", (unsigned long)objects.count]].path;
            NSMutableArray<NSString *> *arguments = [NativeFlags(unit.language) mutableCopy];
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
            [objects addObjectsFromArray:@[@"-o", program.path]];
            result = RunCommand(cpp ? clangXX : clang, objects, folder, &diagnostics, stop, log);
        }
    } else {
        NSMutableArray<NSString *> *arguments = [NativeFlags(firstLanguage) mutableCopy];
        [arguments addObjectsFromArray:includes];
        for (const auto &unit : sources.files)
            [arguments addObject:unit.url.path];
        if (objective)
            [arguments addObjectsFromArray:@[@"-framework", @"Foundation"]];
        [arguments addObjectsFromArray:@[@"-o", program.path]];
        result = RunCommand(cpp ? clangXX : clang, arguments, folder, &diagnostics, stop, log);
    }
    if (stop.load(std::memory_order_relaxed))
        return;
    if (result) {
        log.status(@"Build failed.\n", OutputTone::Error);
        return;
    }
    log.status(@"Build successful\n");
    log.send(true);
    RunProgram(program.path, @[], folder, stop, log, input, ready);
}

static void AddCargoTarget(NSMutableArray<NSString *> *arguments, NSDictionary *metadata,
                           NSURL *manifest, NSURL *file)
{
    NSString *active = CanonicalFileURL(file).path;
    BOOL packageManifest = NO;
    NSSet<NSString *> *defaultMembers = [NSSet setWithArray:metadata[@"workspace_default_members"] ?
        metadata[@"workspace_default_members"] : metadata[@"workspace_members"]];
    NSString *onlyPackage = nil, *onlyTarget = nil;
    NSUInteger defaults = 0;
    for (NSDictionary *package in metadata[@"packages"]) {
        NSString *manifestPath = package[@"manifest_path"];
        if (!manifestPath.length)
            continue;
        BOOL current = [CanonicalFileURL([NSURL fileURLWithPath:manifestPath]).path isEqualToString:manifest.path];
        packageManifest |= current;
        BOOL workspaceDefault = [defaultMembers containsObject:package[@"id"]];
        NSString *defaultRun = package[@"default_run"];
        for (NSDictionary *target in package[@"targets"]) {
            NSArray<NSString *> *kind = target[@"kind"];
            BOOL binary = [kind containsObject:@"bin"];
            BOOL example = [kind containsObject:@"example"] && [target[@"crate_types"] containsObject:@"bin"];
            NSString *targetPath = target[@"src_path"];
            NSString *name = target[@"name"];
            if (!name.length)
                continue;
            if ((binary || example) && active.length && targetPath.length &&
                [CanonicalFileURL([NSURL fileURLWithPath:targetPath]).path isEqualToString:active]) {
                if (!current)
                    [arguments addObjectsFromArray:@[@"--package", package[@"name"]]];
                [arguments addObjectsFromArray:@[binary ? @"--bin" : @"--example", name]];
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
}

static void RunCargo(NSURL *manifest, NSURL *file, const std::atomic_bool &stop, RunLog &log,
                     ProgramInput &input, void (^ready)(void))
{
    NSString *tool = GetTool(@"cargo", Language::Rust, log);
    if (!tool)
        return;
    NSURL *directory = manifest.URLByDeletingLastPathComponent;
    log.status(@"Building...\n");
    log.send(true);

    std::string information;
    int result = RunCommand(tool, @[@"metadata", @"--no-deps", @"--format-version", @"1",
        @"--manifest-path", manifest.path], directory, nullptr, stop, log, nullptr, nil, nullptr, &information);
    if (stop.load(std::memory_order_relaxed))
        return;
    NSDictionary *metadata = result ? nil : JSONDictionary(information);
    if (!metadata) {
        log.status(@"Could not read the Cargo project.\n", OutputTone::Error);
        return;
    }
    NSString *root = metadata[@"workspace_root"];
    NSURL *workspace = root.length ? [NSURL fileURLWithPath:root isDirectory:YES] : directory;
    NSMutableArray<NSString *> *arguments = [@[@"run", @"--quiet", @"--color", @"always",
        @"--message-format=json,json-diagnostic-rendered-ansi", @"--manifest-path", manifest.path] mutableCopy];
    AddCargoTarget(arguments, metadata, manifest, file);
    NSURL *active = CanonicalFileURL(file);
    CargoSession cargo{{active, active, workspace, nil, false, Language::Rust}, input, ready, {}};
    result = RunCommand(tool, arguments, directory, nullptr, stop, log, &input, ready, &cargo);
    if (stop.load(std::memory_order_relaxed))
        return;
    if (cargo.built)
        log.programExitCode = result;
    else
        log.status(@"Build failed.\n", OutputTone::Error);
}

static bool BuildProgram(NSString *tool, NSArray<NSString *> *arguments, NSURL *directory,
                         const DiagnosticContext &diagnostics, const std::atomic_bool &stop, RunLog &log)
{
    log.status(@"Building...\n");
    log.send(true);
    int result = RunCommand(tool, arguments, directory, &diagnostics, stop, log);
    if (stop.load(std::memory_order_relaxed))
        return false;
    if (result) {
        log.status(@"Build failed.\n", OutputTone::Error);
        return false;
    }
    log.status(@"Build successful\n");
    log.send(true);
    return true;
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
    if ([file.lastPathComponent hasSuffix:@"_test.go"]) {
        RunProgram(tool, @[@"test", @"-v", @"."], directory, stop, log, input, ready, &diagnostics);
        return;
    }

    RunFiles files;
    NSError *error = nil;
    files.folder = TemporaryFolder(&error);
    if (!files.folder) {
        log.status([NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
        return;
    }
    NSString *program = [files.folder URLByAppendingPathComponent:@"program"].path;
    if (!BuildProgram(tool, @[@"build", @"-o", program, @"."], directory, diagnostics, stop, log))
        return;
    if ([NSFileManager.defaultManager isExecutableFileAtPath:program])
        RunProgram(program, @[], directory, stop, log, input, ready);
    else
        log.status(@"Open a Go file in a main package or a _test.go file to run tests.\n", OutputTone::Error);
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

static void RunSwiftPackage(RunProject project, NSURL *file, const std::atomic_bool &stop,
                            RunLog &log, ProgramInput &input, void (^ready)(void))
{
    NSString *tool = GetTool(@"swift", Language::Swift, log);
    if (!tool)
        return;
    DiagnosticContext diagnostics{file, file, project.folder, file.lastPathComponent, false, Language::Swift};
    std::string manifest;
    if (RunCommand(tool, @[@"package", @"dump-package"], project.folder, &diagnostics, stop, log, nullptr,
                   nil, nullptr, &manifest) != 0 || stop.load(std::memory_order_relaxed))
        return;
    NSDictionary *package = JSONDictionary(manifest);
    NSString *product = SwiftProduct(package, project.folder, file);
    if (!product.length) {
        log.status(@"Open a source file in an executable Swift package target.\n", OutputTone::Error);
        return;
    }
    if (!BuildProgram(tool, @[@"build", @"--product", product, @"-Xswiftc", @"-color-diagnostics"],
                      project.folder, diagnostics, stop, log))
        return;

    std::string output;
    int result = RunCommand(tool, @[@"build", @"--show-bin-path"], project.folder, nullptr, stop, log,
                            nullptr, nil, nullptr, &output);
    if (result || stop.load(std::memory_order_relaxed))
        return;
    NSString *path = [[[NSString alloc] initWithBytes:output.data() length:output.size() encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *program = ExecutableAt(path, product);
    if (program)
        RunProgram(program, @[], project.folder, stop, log, input, ready);
    else
        log.status(@"Swift did not produce an executable.\n", OutputTone::Error);
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
        log.status([NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
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
        log.status(@"The .NET build did not produce a single executable application.\n", OutputTone::Error);
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
    switch (language) {
        case Language::Python: return @[@"-B", @"-u", path];
        case Language::Zig: case Language::Dart: return @[@"run", path];
        case Language::Kotlin: return @[@"-script", path];
        case Language::FSharp: return @[@"fsi", @"--exec", path];
        case Language::PowerShell: return @[@"-NoLogo", @"-NoProfile", @"-File", path];
        case Language::R: return @[@"--no-save", @"--no-restore", path];
        case Language::Clojure: return @[@"-M", path];
        case Language::CommonLisp: return @[@"--script", path];
        default: return @[path];
    }
}

static void RunSource(Language language, NSURL *file, NSString *name, NSString *text, NSURL *workingFolder,
                      const std::atomic_bool &stop, RunLog &log, ProgramInput &inputChannel, void (^ready)(void))
{
    NSString *toolName = ToolName(language);
    if (!toolName) {
        log.status(@"This file type cannot be run.\n", OutputTone::Error);
        return;
    }
    if (!file && !text) {
        log.status(@"Save this file before running it.\n", OutputTone::Error);
        return;
    }
    NSURL *directory = file.URLByDeletingLastPathComponent;
    NSString *extension = file.pathExtension.lowercaseString;
    NSString *tool = nil, *launcher = nil;
    bool build = CFamily(language) || language == Language::Rust || language == Language::Swift ||
        language == Language::Go || language == Language::Odin;
    bool kotlin = language == Language::Kotlin && ![extension isEqualToString:@"kts"];
    bool mono = false;
    bool dotnet = false;
    if (language == Language::Python && workingFolder) {
        for (NSString *environment in @[@".venv/bin", @"venv/bin"]) {
            tool = ExecutableAt([workingFolder.path stringByAppendingPathComponent:environment], @"python");
            if (tool)
                break;
        }
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
        log.status(@"Open a file in a Visual Basic .NET project to run it.\n", OutputTone::Error);
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
        log.status([NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
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
            log.status([NSString stringWithFormat:@"%@\n", error.localizedDescription], OutputTone::Error);
            return;
        }
    }
    NSURL *includes = directory ? directory : files.folder;
    directory = workingFolder ? workingFolder : directory ? directory : files.folder;
    NSString *path = input.path;
    DiagnosticContext diagnostics{input, file, directory, name,
        CFamily(language) || language == Language::Go || language == Language::Zig, language};
    if (dotnet) {
        BuildAndRunDotNet(tool, input, directory, diagnostics, stop, log, inputChannel, ready);
        return;
    }
    if (!build) {
        bool diagnosticsInOutput = language == Language::Java || language == Language::Kotlin || language == Language::Zig ||
            language == Language::Dart || language == Language::CSharp || language == Language::FSharp;
        RunProgram(tool, ScriptArguments(language, path), directory, stop, log, inputChannel, ready,
                   diagnosticsInOutput ? &diagnostics : nullptr);
        return;
    }

    NSString *program = [files.folder URLByAppendingPathComponent:kotlin ? @"program.jar" : mono ? @"program.exe" : @"program"].path;
    NSArray<NSString *> *arguments;
    if (language == Language::Rust) {
        arguments = @[@"--edition=2021", @"--crate-name", @"editor_program", @"--error-format=json",
                      @"--json=diagnostic-rendered-ansi", path, @"-o", program];
    } else if (language == Language::Swift) {
        arguments = @[@"-color-diagnostics", path, @"-o", program];
    } else if (language == Language::Go) {
        arguments = @[@"build", @"-o", program, path];
    } else if (language == Language::Odin) {
        bool package = !text && [file.pathExtension isEqualToString:@"odin"];
        arguments = @[@"build", package ? file.URLByDeletingLastPathComponent.path : path,
                      [@"-out:" stringByAppendingString:program], @"-error-pos-style:unix", @"-terse-errors"];
        if (!package)
            arguments = [arguments arrayByAddingObject:@"-file"];
    } else if (kotlin) {
        arguments = @[path, @"-include-runtime", @"-d", program];
    } else if (mono) {
        arguments = @[[@"-out:" stringByAppendingString:program], path];
    } else {
        arguments = [NativeFlags(language) arrayByAddingObjectsFromArray:@[@"-iquote", includes.path, path, @"-o", program]];
        if (Objective(language))
            arguments = [arguments arrayByAddingObjectsFromArray:@[@"-framework", @"Foundation"]];
    }
    if (!BuildProgram(tool, arguments, directory, diagnostics, stop, log))
        return;
    if (language == Language::Go && ![NSFileManager.defaultManager isExecutableFileAtPath:program]) {
        log.status(@"A Go program needs package main and a main function.\n", OutputTone::Error);
        return;
    }
    if (launcher)
        RunProgram(launcher, kotlin ? @[@"-jar", program] : @[program], directory, stop, log, inputChannel, ready);
    else
        RunProgram(program, @[], directory, stop, log, inputChannel, ready);
}

// Track live runs on the main thread, including runs whose source tabs have closed.
static NSMutableSet<SourceRunner *> *activeRunners;
static dispatch_group_t activeRuns;
static bool quitting;

bool StopSourceRunsForQuit(dispatch_block_t finished)
{
    quitting = true;
    if (!activeRuns || dispatch_group_wait(activeRuns, DISPATCH_TIME_NOW) == 0)
        return false;

    for (SourceRunner *runner in activeRunners)
        [runner stop];
    dispatch_group_notify(activeRuns, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), finished);
    return true;
}

@implementation SourceRunner {
    std::atomic_bool _stopped;
    ProgramInput _inputChannel;
}

- (void)startLanguage:(Language)language file:(NSURL *)file name:(NSString *)name workingText:(NSString *)text
               output:(RunOutput)output finished:(void (^)(void))finished
{
    _stopped.store(false, std::memory_order_relaxed);
    [self startProject:{} language:language file:file name:name workingText:text output:output finished:finished];
}

- (void)startProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
         workingText:(NSString *)text output:(RunOutput)output finished:(void (^)(void))finished
{
    if (quitting) {
        [self stop];
        dispatch_async(dispatch_get_main_queue(), finished);
        return;
    }
    if (!activeRuns) {
        activeRuns = dispatch_group_create();
        activeRunners = [[NSMutableSet alloc] init];
    }
    [activeRunners addObject:self];
    NSString *snapshot = [text copy];
    void (^ready)(void) = self.inputReady;
    dispatch_group_async(activeRuns, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            RunLog log{};
            log.output = output;
            switch (project.kind) {
                case RunKind::Cargo:
                    RunCargo(project.manifest, file, self->_stopped, log, self->_inputChannel, ready);
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
                log.status(@"Stopped.\n");
            } else if (int code = log.programExitCode; code >= 0) {
                log.status([NSString stringWithFormat:@"Process exited with code %d.\n", code],
                           code == 0 ? OutputTone::Text : OutputTone::Error);
            }
            log.send(true);
            dispatch_async(dispatch_get_main_queue(), ^{
                [activeRunners removeObject:self];
                finished();
            });
        }
    });
}

- (BOOL)isStopped { return _stopped.load(std::memory_order_relaxed); }

- (void)stop
{
    _stopped.store(true, std::memory_order_relaxed);
    _inputChannel.setOpen(false);
}

- (BOOL)sendInput:(NSString *)text
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    std::lock_guard lock(_inputChannel.mutex);
    if (!_inputChannel.open || !data.length || data.length > 65536 - _inputChannel.queued.size())
        return NO;
    _inputChannel.queued.append(static_cast<const char *>(data.bytes), data.length);
    return YES;
}

@end