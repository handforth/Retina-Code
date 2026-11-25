#import "Starters.h"
#import "Editor.h"
#import "Preferences.h"
#import "Runner.h"
#import "Workspace.h"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <iterator>
#include <sys/stat.h>
#include <unistd.h>

struct StarterFile {
    const char *name;
    std::string_view text;
    const char *manifest = nullptr;
};

// Keep these in Language order. Only tool-generated files have a manifest.
static constexpr StarterFile starters[] = {
    {"hello.txt", "Hello, world!\n"},
    {"main.c", R"(#include <stdio.h>

int main(void)
{
    puts("Hello, world!");
    return 0;
}
)"},
    {"main.cpp", R"(#include <iostream>

int main()
{
    std::cout << "Hello, world!\n";
    return 0;
}
)"},
    {"main.py", "print(\"Hello, world!\")\n"},
    {"src/main.rs", {}, "Cargo.toml"},
    {"index.js", "console.log(\"Hello, world!\");\n"},
    {"index.ts", "const message: string = \"Hello, world!\";\nconsole.log(message);\n"},
    {"index.jsx", "console.log(\"Hello, world!\");\n"},
    {"index.tsx", "const message: string = \"Hello, world!\";\nconsole.log(message);\n"},
    {"main.m", R"(#import <Foundation/Foundation.h>

int main(void)
{
    @autoreleasepool {
        NSLog(@"Hello, world!");
    }
    return 0;
}
)"},
    {"main.mm", R"(#import <Foundation/Foundation.h>
#include <iostream>

int main()
{
    @autoreleasepool {
        NSString *message = @"Hello, world!";
        std::cout << message.UTF8String << '\n';
    }
    return 0;
}
)"},
    {"Program.cs", R"(using System;

class Program
{
    static void Main()
    {
        Console.WriteLine("Hello, world!");
    }
}
)"},
    {"Main.java", R"(public class Main {
    public static void main(String[] args) {
        System.out.println("Hello, world!");
    }
}
)"},
    {"Main.kt", "fun main() {\n    println(\"Hello, world!\")\n}\n"},
    {"main.swift", "print(\"Hello, world!\")\n"},
    {"main.go", R"(package main

import "fmt"

func main() {
	fmt.Println("Hello, world!")
}
)", "go.mod"},
    {"main.zig", R"(const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, world!\n", .{});
}
)"},
    {"main.dart", "void main() {\n  print('Hello, world!');\n}\n"},
    {"main.rb", "puts \"Hello, world!\"\n"},
    {"index.php", "<?php\necho \"Hello, world!\\n\";\n"},
    {"main.pl", "use strict;\nuse warnings;\n\nprint \"Hello, world!\\n\";\n"},
    {"main.lua", "print(\"Hello, world!\")\n"},
    {"main.luau", "print(\"Hello, world!\")\n"},
    {"main.sh", "#!/usr/bin/env bash\n\nprintf '%s\\n' 'Hello, world!'\n"},
    {"main.zsh", "#!/usr/bin/env zsh\n\nprintf '%s\\n' 'Hello, world!'\n"},
    {"main.fish", "printf '%s\\n' 'Hello, world!'\n"},
    {"main.ps1", "Write-Output 'Hello, world!'\n"},
    {"main.R", "cat(\"Hello, world!\\n\")\n"},
    {"main.jl", "println(\"Hello, world!\")\n"},
    {"Main.scala", R"(object Main {
    def main(args: Array[String]): Unit = {
        println("Hello, world!")
    }
}
)"},
    {"main.groovy", "println 'Hello, world!'\n"},
    {"Main.hs", "main :: IO ()\nmain = putStrLn \"Hello, world!\"\n"},
    {"main.fsx", "printfn \"Hello, world!\"\n"},
    {"main.exs", "IO.puts(\"Hello, world!\")\n"},
    {"main.clj", "(println \"Hello, world!\")\n"},
    {"Program.vb", {}, "HelloWorld.vbproj"},
    {"main.sql", "SELECT 'Hello, world!' AS message;\n"},
    {"index.html", R"(<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Hello, world!</title>
</head>
<body>
    <h1>Hello, world!</h1>
</body>
</html>
)"},
    {"hello.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<message>Hello, world!</message>\n"},
    {"style.css", "body::before {\n    content: \"Hello, world!\";\n}\n"},
    {"style.scss", "$message: \"Hello, world!\";\n\nbody::before {\n    content: $message;\n}\n"},
    {"style.less", "@message: \"Hello, world!\";\n\nbody::before {\n    content: @message;\n}\n"},
    {"hello.json", "{\n    \"message\": \"Hello, world!\"\n}\n"},
    {"hello.jsonc", "{\n    \"message\": \"Hello, world!\"\n}\n"},
    {"hello.yaml", "message: \"Hello, world!\"\n"},
    {"hello.toml", "message = \"Hello, world!\"\n"},
    {"hello.ini", "[hello]\nmessage=Hello, world!\n"},
    {"README.md", "# Hello, world!\n"},
    {"Makefile", ".PHONY: all\n\nall:\n\t@echo 'Hello, world!'\n"},
    {"CMakeLists.txt", "cmake_minimum_required(VERSION 3.15)\nproject(HelloWorld NONE)\n\nmessage(STATUS \"Hello, world!\")\n"},
    {"Dockerfile", "FROM alpine\nCMD [\"echo\", \"Hello, world!\"]\n"},
    {"main.S", R"(    .text
    .globl _main
_main:
#if defined(__arm64__)
    stp x29, x30, [sp, #-16]!
    adrp x0, message@PAGE
    add x0, x0, message@PAGEOFF
    bl _puts
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret
#else
    pushq %rbp
    leaq message(%rip), %rdi
    callq _puts
    xorl %eax, %eax
    popq %rbp
    retq
#endif

    .section __TEXT,__cstring
message:
    .asciz "Hello, world!"
)"},
    {"main.odin", R"(package main

import "core:fmt"

main :: proc() {
    fmt.println("Hello, world!")
}
)"},
    {"hello.gml", "show_debug_message(\"Hello, world!\");\n"},
    {"main.lisp", "(format t \"Hello, world!~%\")\n"},
};

static_assert(std::size(starters) == size_t(Language::Count));

static NSError *StarterError(NSURL *url, NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:NSCocoaErrorDomain code:code
                           userInfo:@{NSURLErrorKey:url, NSLocalizedDescriptionKey:description}];
}

static NSError *CheckEmptyFolder(NSURL *folder)
{
    if (![CanonicalFileURL(folder).path isEqualToString:folder.path])
        return StarterError(folder, NSFileWriteNoPermissionError, @"The folder has moved.");
    NSError *error = nil;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder.path error:&error];
    for (NSString *name in names) {
        if (!HiddenWorkspaceItem(name))
            return StarterError(folder, NSFileWriteFileExistsError, @"The folder is no longer empty.");
    }
    return error;
}

static NSString *PackageName(NSURL *folder)
{
    std::string name;
    bool separator = false;
    for (unsigned char character : std::string_view(folder.lastPathComponent.UTF8String)) {
        if (character >= 'A' && character <= 'Z')
            character += 'a' - 'A';
        bool digit = character >= '0' && character <= '9';
        if (!digit && !(character >= 'a' && character <= 'z')) {
            separator = !name.empty();
            continue;
        }
        if (name.empty() && digit)
            name = "app-";
        if (separator)
            name += '-';
        name += character;
        separator = false;
        if (name.size() >= 60)
            break;
    }
    return name.empty() ? @"hello-world" : @(name.c_str());
}

static NSError *RunStarterTool(NSString *name, Language language, NSURL *directory, NSArray<NSString *> *arguments)
{
    NSString *tool = FindTool(name, language);
    if (!tool)
        return StarterError(directory, NSFileNoSuchFileError, [NSString stringWithFormat:@"%@ was not found.", name]);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.currentDirectoryURL = directory;
    task.arguments = arguments;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (language == Language::VisualBasic) {
        NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
        [environment addEntriesFromDictionary:@{@"DOTNET_CLI_TELEMETRY_OPTOUT":@"1", @"DOTNET_NOLOGO":@"1",
            @"DOTNET_GENERATE_ASPNET_CERTIFICATE":@"0", @"DOTNET_ADD_GLOBAL_TOOLS_TO_PATH":@"0",
            @"DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE":@"1"}];
        task.environment = environment;
    }
    NSError *error = nil;
    if (![task launchAndReturnError:&error])
        return error;

    NSMutableData *output = [NSMutableData data];
    constexpr NSUInteger limit = 2048;
    NSFileHandle *reader = pipe.fileHandleForReading;
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [reader readDataUpToLength:4096 error:nil];
            if (!chunk.length)
                break;
            [output appendBytes:chunk.bytes length:std::min(chunk.length, limit - output.length)];
        }
    }
    [reader closeAndReturnError:nil];
    [task waitUntilExit];
    if (!task.terminationStatus)
        return nil;
    NSString *message = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    if (!message)
        message = [[NSString alloc] initWithData:output encoding:NSISOLatin1StringEncoding];
    message = [message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!message.length)
        message = [NSString stringWithFormat:@"%@ exited with code %d.", name, task.terminationStatus];
    return StarterError(directory, NSFileWriteUnknownError, message);
}

static NSError *InitializeStarter(Language language, NSURL *folder, NSURL *directory)
{
    if (language == Language::Rust) {
        NSString *name = PackageName(folder);
        NSArray *arguments = @[@"init", @"--bin", @"--vcs", @"none", @"--offline", @"--quiet", @"--name", name];
        NSError *error = RunStarterTool(@"cargo", language, directory, arguments);
        // Cargo reserves names such as "test", even for a binary package.
        if ([error.localizedDescription containsString:@"invalid package name"]) {
            NSMutableArray *retry = [arguments mutableCopy];
            retry[retry.count - 1] = [@"app-" stringByAppendingString:name];
            error = RunStarterTool(@"cargo", language, directory, retry);
        }
        if (!error && ParentManifest(folder.URLByDeletingLastPathComponent, nil, @"Cargo.toml")) {
            // Keep the new package runnable without changing the enclosing workspace.
            NSURL *manifest = [directory URLByAppendingPathComponent:@"Cargo.toml"];
            NSString *text = [NSString stringWithContentsOfURL:manifest encoding:NSUTF8StringEncoding error:&error];
            [[text stringByAppendingString:@"\n[workspace]\n"] writeToURL:manifest atomically:YES
                                                        encoding:NSUTF8StringEncoding error:&error];
        }
        return error;
    }
    if (language == Language::Go) {
        NSString *module = [@"example.com/" stringByAppendingString:PackageName(folder)];
        return RunStarterTool(@"go", language, directory, @[@"mod", @"init", module]);
    }
    return RunStarterTool(@"dotnet", language, directory,
                          @[@"new", @"console", @"--language", @"VB", @"--name", @"HelloWorld", @"--output", @".", @"--no-restore"]);
}

static NSURL *CreateStarterDirectory(NSError **error)
{
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"RetinaCodeStarter-XXXXXX"];
    std::string path(pattern.fileSystemRepresentation);
    if (mkdtemp(path.data()))
        return [NSURL fileURLWithFileSystemRepresentation:path.c_str() isDirectory:YES relativeToURL:nil];
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return nil;
}

static NSURL *InstallStarter(const StarterFile &starter, NSURL *folder, NSURL *staged,
                             FinalNewlineMode newline, NSError **error)
{
    NSString *name = @(starter.name), *manifest = @(starter.manifest);
    NSURL *file = [folder URLByAppendingPathComponent:name isDirectory:NO];
    NSURL *manifestFile = [folder URLByAppendingPathComponent:manifest isDirectory:NO];
    NSData *manifestData = [NSData dataWithContentsOfURL:[staged URLByAppendingPathComponent:manifest] options:0 error:error];
    if (!manifestData)
        return nil;
    NSData *source = starter.text.empty() ?
        [NSData dataWithContentsOfURL:[staged URLByAppendingPathComponent:name] options:0 error:error] :
        [NSData dataWithBytes:starter.text.data() length:starter.text.size()];
    if (!source || (*error = CheckEmptyFolder(folder)))
        return nil;

    manifestData = SourceDataWithFinalNewline(manifestData, newline);
    source = SourceDataWithFinalNewline(source, newline);
    NSURL *parent = file.URLByDeletingLastPathComponent;
    BOOL nested = ![parent.path isEqualToString:folder.path];
    if (nested && mkdir(parent.fileSystemRepresentation, 0777) != 0) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{NSURLErrorKey:parent}];
        return nil;
    }
    if ([manifestData writeToURL:manifestFile options:NSDataWritingWithoutOverwriting error:error]) {
        if ([source writeToURL:file options:NSDataWritingWithoutOverwriting error:error])
            return file;
        unlink(manifestFile.fileSystemRepresentation);
    }
    if (nested)
        rmdir(parent.fileSystemRepresentation);
    return nil;
}

NSURL *CreateStarter(NSURL *folder, Language language, NSError **error)
{
    if ((*error = CheckEmptyFolder(folder)))
        return nil;
    FinalNewlineMode newline = SaveCleanupPreference().finalNewline;
    const StarterFile &starter = starters[size_t(language)];
    // A standalone Go file runs inside a parent go.work without adding a module to it.
    bool standaloneGo = language == Language::Go && ParentManifest(folder.URLByDeletingLastPathComponent, nil, @"go.work");
    if (!starter.manifest || standaloneGo) {
        NSURL *file = [folder URLByAppendingPathComponent:@(starter.name) isDirectory:NO];
        NSData *data = [NSData dataWithBytes:starter.text.data() length:starter.text.size()];
        data = SourceDataWithFinalNewline(data, newline);
        return [data writeToURL:file options:NSDataWritingWithoutOverwriting error:error] ? file : nil;
    }

    // Run initializers away from any parent workspace and install only their source and manifest.
    NSURL *staged = CreateStarterDirectory(error);
    if (!staged)
        return nil;
    *error = InitializeStarter(language, folder, staged);
    NSURL *file = *error ? nil : InstallStarter(starter, folder, staged, newline, error);
    [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
    return file;
}