#pragma once

#import <Foundation/Foundation.h>
#include "Lexer.hpp"

enum class OutputTone { Text, Warning, Error };

inline constexpr uint32_t defaultOutputColor = 0xFFFFFFFF;
inline constexpr uint32_t outputPaletteStart = 0x1000000;

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

enum class RunKind { Source, Script, Cargo, NativeProject, GoModule, SwiftPackage, DotNet, OdinPackage };

struct RunProject {
    RunKind kind = RunKind::Source;
    NSURL *folder = nil;
    NSURL *manifest = nil;
};

RunProject LocateRunProject(Language language, NSURL *file, NSURL *folder);
bool RunnableLanguage(Language language);
bool StopSourceRunsForQuit(dispatch_block_t finished);

@interface SourceRunner : NSObject
@property(nonatomic, copy) void (^inputReady)(void);
@property(nonatomic, readonly, getter=isStopped) BOOL stopped;
- (void)startLanguage:(Language)language file:(NSURL *)file name:(NSString *)name workingText:(NSString *)text
               output:(RunOutput)output finished:(void (^)(void))finished;
- (void)startProject:(RunProject)project language:(Language)language file:(NSURL *)file name:(NSString *)name
         workingText:(NSString *)text output:(RunOutput)output finished:(void (^)(void))finished;
- (void)stop;
- (BOOL)sendInput:(NSString *)text;
@end