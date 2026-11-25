#pragma once

#import <Foundation/Foundation.h>
#include "Lexer.hpp"

enum class OutputTone { Text, Warning, Error };

// ANSI truecolors are opaque RGBA. The low values hold the default and palette indices.
inline constexpr uint32_t defaultOutputColor = 0;
inline constexpr uint32_t outputPaletteStart = 1;

struct OutputColors {
    uint32_t foreground = defaultOutputColor;
    uint32_t background = defaultOutputColor;

    bool operator==(const OutputColors &) const = default;
};

struct OutputColorSpan {
    NSRange range;
    OutputColors colors;
};

inline constexpr NSUInteger outputScrollbackCharacters = 192 * 1024;
inline constexpr NSUInteger outputScrollbackLines = 3000;

constexpr NSUInteger OutputScrollbackCharacterLimit(NSUInteger lines)
{
    if (lines <= outputScrollbackLines)
        return outputScrollbackCharacters;
    return lines * outputScrollbackCharacters / outputScrollbackLines;
}

struct RunLocation {
    NSURL *file = nil;
    NSUInteger line = 0;
    NSUInteger column = 0;
    NSUInteger firstColumn = 0;
    NSUInteger endColumn = 0;
    bool currentSource = false;
    bool byteColumns = true;
};

struct RunMessage {
    NSString *text;
    OutputTone tone = OutputTone::Text;
    RunLocation location;
    NSString *diagnostic = nil;
    bool earlierOutputDiscarded = false;
    NSRange linkRange = {NSNotFound, 0};
    bool usesTerminalColors = false;
    std::vector<OutputColorSpan> colorSpans{};
};

using RunOutput = void (^)(const std::vector<RunMessage> &);

struct CheckSource {
    NSURL *file;
    NSString *text;
};

struct CheckResult {
    std::vector<RunMessage> diagnostics;
    NSUInteger errors = 0;
};

using CheckFinished = void (^)(CheckResult);

@interface RustCheckCache : NSObject
@end

enum class RunKind { Source, Script, Cargo, NativeProject, GoModule, SwiftPackage, DotNet, OdinPackage };

struct RunProject {
    RunKind kind = RunKind::Source;
    NSURL *folder = nil;
    NSURL *manifest = nil;
};

@interface DebugExecutable : NSObject
@property(nonatomic, readonly) NSURL *file;
@property(nonatomic, readonly) NSURL *directory;
- (instancetype)initWithFile:(NSURL *)file directory:(NSURL *)directory;
@end

RunProject LocateRunProject(Language language, NSURL *file, NSURL *folder);
NSURL *ParentManifest(NSURL *directory, NSURL *limit, NSString *name);
bool RunnableLanguage(Language language);
bool DebuggableLanguage(Language language, NSURL *file);
NSString *FindTool(NSString *name, Language language);
bool StopSourceRunsForQuit(dispatch_block_t finished);

@interface SourceRunner : NSObject
@property(nonatomic, copy) void (^inputReady)(void);
@property(nonatomic, readonly, getter=isStopped) BOOL stopped;
- (void)startLanguage:(Language)language file:(NSURL *)file name:(NSString *)name workingText:(NSString *)text
               output:(RunOutput)output finished:(void (^)(void))finished;
- (void)startProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
         workingText:(NSString *)text output:(RunOutput)output finished:(void (^)(void))finished;
- (void)checkRustProject:(RunProject)project file:(NSURL *)file name:(NSString *)name
                 sources:(std::vector<CheckSource>)sources cache:(RustCheckCache *)cache finished:(CheckFinished)finished;
- (void)buildDebugProject:(RunProject)project language:(Language)language file:(NSURL *)file
                   output:(RunOutput)output finished:(void (^)(DebugExecutable *))finished;
- (void)stop;
- (BOOL)sendInput:(NSString *)text;
@end