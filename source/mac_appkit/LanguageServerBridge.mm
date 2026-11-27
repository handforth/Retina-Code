#import "LanguageServer.h"
#include "../LSPJson.hpp"
#include "LSPProcess.hpp"

// The editor still uses Foundation values for its menus, hover text, and settings.
NSDictionary *LSPDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : nil; }
NSArray *LSPArray(id value) { return [value isKindOfClass:NSArray.class] ? value : nil; }
NSString *LSPString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
NSNumber *LSPNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }

NSDictionary *LSPPositionValue(LSPPosition position)
{
    return @{@"line":@(position.line), @"character":@(position.character)};
}

static NSString *const serversKey = @"LanguageServers";
static NSString *const disabledToolsKey = @"DisabledLanguageTools";
NSString *const LanguageServerConfigurationChanged = @"RetinaCodeLanguageServerConfigurationChanged";

static NSString *NativeString(std::string_view text)
{
    if (text.empty())
        return nil;
    NSString *value = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    return value ? value : [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSISOLatin1StringEncoding];
}

static std::string_view FilePath(NSURL *url)
{
    const char *path = url.fileSystemRepresentation;
    return path ? std::string_view(path) : std::string_view{};
}

static NSData *EncodeParameters(NSDictionary *parameters)
{
    return parameters ? [NSJSONSerialization dataWithJSONObject:parameters options:0 error:nil] : nil;
}

static std::string_view DataView(NSData *data)
{
    return data.length ? std::string_view(static_cast<const char *>(data.bytes), data.length) : std::string_view{};
}

static id DecodeResult(std::string_view json)
{
    if (json.empty())
        return nil;
    NSData *data = [NSData dataWithBytesNoCopy:const_cast<char *>(json.data()) length:json.size() freeWhenDone:NO];
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
}

static void ReleaseBlock(void *context)
{
    CFRelease(context);
}

static lsp::Reply ReplyCallback(LSPReply reply)
{
    if (!reply)
        return {};
    return {(__bridge_retained void *)[reply copy], [](void *context, std::string_view result, std::string_view error) {
        @autoreleasepool {
            LSPReply block = (__bridge LSPReply)context;
            block(DecodeResult(result), NativeString(error));
        }
    }, ReleaseBlock};
}

NSDictionary *LanguageServerConfiguration(Language language)
{
    return LSPDict([NSUserDefaults.standardUserDefaults dictionaryForKey:serversKey][@(NSInteger(language)).stringValue]);
}

void SetLanguageServerConfiguration(Language language, NSString *path, NSArray<NSString *> *arguments)
{
    NSDictionary *command = path.length ? @{@"path":path, @"arguments":arguments ? arguments : @[]} : nil;
    NSDictionary *previous = LanguageServerConfiguration(language);
    if (previous == command || [previous isEqual:command])
        return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *commands = [[defaults dictionaryForKey:serversKey] mutableCopy];
    if (!commands)
        commands = [NSMutableDictionary dictionary];
    NSNumber *mode = @(NSInteger(language));
    commands[mode.stringValue] = command;
    [defaults setObject:commands forKey:serversKey];
    lsp::Reconfigure(language);
    [NSNotificationCenter.defaultCenter postNotificationName:LanguageServerConfigurationChanged object:mode];
}

static lsp::Command ReadCommand(Language language)
{
    NSDictionary *configured = LanguageServerConfiguration(language);
    lsp::Command command;
    command.executable = UTF8View(LSPString(configured[@"path"]));
    if (!command.executable.empty()) {
        for (id argument in LSPArray(configured[@"arguments"])) {
            if (NSString *text = LSPString(argument))
                lsp::AppendItem(command.arguments, UTF8View(text));
        }
    }
    return command;
}

static void ConfigureLanguageHost()
{
    static const bool configured = [] {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        lsp::Configure({
            std::string(UTF8View(NSHomeDirectory())),
            std::string(UTF8View([support stringByAppendingPathComponent:@"Retina Code/Language Servers"])),
            ReadCommand,
            [](std::string_view key) {
                return bool([[NSUserDefaults.standardUserDefaults arrayForKey:disabledToolsKey] containsObject:NativeString(key)]);
            },
            [](std::string_view key, bool disabled) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                NSArray *saved = [defaults arrayForKey:disabledToolsKey];
                NSMutableOrderedSet *tools = [NSMutableOrderedSet orderedSetWithArray:saved ? saved : @[]];
                NSString *name = NativeString(key);
                if (disabled)
                    [tools addObject:name];
                else
                    [tools removeObject:name];
                [defaults setObject:tools.array forKey:disabledToolsKey];
            }
        });
        return true;
    }();
    (void)configured;
}

@implementation LSPDocument {
    lsp::DocumentID _document;
}

- (instancetype)initWithFile:(NSURL *)file workspace:(NSURL *)workspace language:(Language)language
{
    self = [super init];
    if (!self)
        return nil;
    ConfigureLanguageHost();
    _file = file;
    _language = language;
    __attribute__((objc_precise_lifetime)) NSString *uri = file.absoluteString;
    _document = lsp::CreateDocument(FilePath(file), UTF8View(uri), FilePath(workspace), language, {
        (__bridge void *)self,
        [](void *context, std::string &json) {
            @autoreleasepool {
                LSPDocument *document = (__bridge LSPDocument *)context;
                NSString *(^text)(void) = document.sourceText;
                __attribute__((objc_precise_lifetime)) NSString *source = text ? text() : nil;
                auto bytes = UTF8View(source);
                json.reserve(json.size() + bytes.size() + 8);
                lsp::AppendJsonString(json, bytes);
            }
        },
        [](void *context) {
            LSPDocument *document = (__bridge LSPDocument *)context;
            LSPPosition (^end)(void) = document.endPosition;
            return end ? end() : LSPPosition{};
        },
        [](void *context) {
            LSPDocument *document = (__bridge LSPDocument *)context;
            if (void (^updated)(void) = document.updated)
                updated();
        },
        [](void *context, std::string_view json) {
            @autoreleasepool {
                LSPDocument *document = (__bridge LSPDocument *)context;
                document->_diagnostics = LSPArray(DecodeResult(json));
                if (void (^updated)(void) = document.diagnosticsChanged)
                    updated();
            }
        },
        [](void *context) {
            LSPDocument *document = (__bridge LSPDocument *)context;
            if (void (^changed)(void) = document.inlayHintsChanged)
                changed();
        }
    });
    _root = [NSURL fileURLWithPath:NativeString(lsp::Root(_document)) isDirectory:YES];
    return self;
}

- (void)dealloc
{
    lsp::DestroyDocument(_document);
}

- (LSPState)state { return lsp::State(_document); }
- (NSString *)status { return NativeString(lsp::Status(_document)); }
- (NSString *)failureTitle { return NativeString(lsp::FailureTitle(_document)); }
- (NSString *)serverName { return NativeString(lsp::ServerName(_document)); }
- (BOOL)canInstall { return lsp::CanInstall(_document); }
- (BOOL)canUninstall { return lsp::CanUninstall(_document); }
- (BOOL)customServer { return LanguageServerConfiguration(_language) != nil; }
- (NSUInteger)version { return lsp::Version(_document); }
- (BOOL)sendingChanges { return lsp::SendingChanges(_document); }
- (BOOL)changedSinceSave { return lsp::ChangedSinceSave(_document); }
- (BOOL)handlesDiagnostics { return lsp::HandlesDiagnostics(_document); }
- (BOOL)supports:(NSString *)capability { return lsp::Supports(_document, UTF8View(capability)); }
- (BOOL)triggersCompletion:(NSString *)character { return lsp::TriggersCompletion(_document, UTF8View(character)); }
- (BOOL)resolvesCodeActions { return lsp::ResolvesCodeActions(_document); }

- (void)start { lsp::Start(_document); }
- (void)restart { lsp::Restart(_document); }
- (void)stop { lsp::Stop(_document); }
- (void)close { lsp::Close(_document); }
- (void)install { lsp::Install(_document); }
- (void)cancelInstall { lsp::CancelInstall(_document); }
- (void)uninstall { lsp::Uninstall(_document); }
- (void)saved { lsp::Saved(_document); }

- (void)changed:(std::optional<LSPTextChange>)change
{
    std::optional<lsp::Change> edit;
    if (change)
        edit = lsp::Change{change->start, change->end, UTF8View(change->text)};
    lsp::Changed(_document, edit);
}

- (NSInteger)request:(NSString *)method params:(NSDictionary *)params reply:(LSPReply)reply
{
    __attribute__((objc_precise_lifetime)) NSData *data = EncodeParameters(params);
    return lsp::Request(_document, UTF8View(method), DataView(data), ReplyCallback(reply));
}

- (void)cancelRequest:(NSInteger)identifier { lsp::CancelRequest(_document, identifier); }

- (NSInteger)requestInlayHintsFrom:(LSPPosition)start to:(LSPPosition)end reply:(LSPInlayReply)reply
{
    return lsp::RequestInlayHints(_document, start, end, {
        (__bridge_retained void *)[reply copy],
        [](void *context, std::string_view result, std::string_view error) {
            @autoreleasepool {
                LSPInlayReply block = (__bridge LSPInlayReply)context;
                block(lsp::ReadInlayHints(result), error.empty());
            }
        },
        ReleaseBlock
    });
}

- (void)executeCommand:(NSDictionary *)command applyEdit:(NSString *(^)(id edit))edit reply:(LSPReply)reply
{
    __attribute__((objc_precise_lifetime)) NSData *data = EncodeParameters(command);
    lsp::ApplyEdit apply;
    if (edit) {
        apply = {(__bridge_retained void *)[edit copy], [](void *context, std::string_view value) {
            @autoreleasepool {
                __attribute__((objc_precise_lifetime)) NSString *(^block)(id) = (__bridge NSString *(^)(id))context;
                return std::string(UTF8View(block(DecodeResult(value))));
            }
        }, ReleaseBlock};
    }
    lsp::ExecuteCommand(_document, DataView(data), apply, ReplyCallback(reply));
}

@end

void StopLanguageServers()
{
    lsp::StopAll();
}