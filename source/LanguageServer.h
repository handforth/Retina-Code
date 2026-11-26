#pragma once

#import <Foundation/Foundation.h>
#include "LanguageServer.hpp"

NSDictionary *LSPDict(id value);
NSArray *LSPArray(id value);
NSString *LSPString(id value);
NSNumber *LSPNumber(id value);
NSDictionary *LSPPositionValue(LSPPosition position);
extern NSString *const LanguageServerConfigurationChanged;
NSDictionary *LanguageServerConfiguration(Language language);
void SetLanguageServerConfiguration(Language language, NSString *path, NSArray<NSString *> *arguments);

struct LSPTextChange {
    LSPPosition start, end;
    NSString *text;
};

using LSPReply = void (^)(id result, NSString *error);
using LSPInlayReply = void (^)(lsp::InlayHints hints, BOOL succeeded);

@interface LSPDocument : NSObject
- (instancetype)initWithFile:(NSURL *)file workspace:(NSURL *)workspace language:(Language)language;
@property(nonatomic, readonly) NSURL *file;
@property(nonatomic, readonly) NSURL *root;
@property(nonatomic, readonly) Language language;
@property(nonatomic, readonly) LSPState state;
@property(nonatomic, readonly) NSString *serverName;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSString *failureTitle;
@property(nonatomic, readonly) BOOL canInstall;
@property(nonatomic, readonly) BOOL canUninstall;
@property(nonatomic, readonly) BOOL customServer;
@property(nonatomic, readonly) NSUInteger version;
@property(nonatomic, readonly) BOOL sendingChanges;
@property(nonatomic, readonly) BOOL changedSinceSave;
@property(nonatomic, readonly) BOOL handlesDiagnostics;
@property(nonatomic, readonly) NSArray<NSDictionary *> *diagnostics;
@property(nonatomic, copy) NSString *(^sourceText)(void);
@property(nonatomic, copy) LSPPosition (^endPosition)(void);
@property(nonatomic, copy) void (^updated)(void);
@property(nonatomic, copy) void (^diagnosticsChanged)(void);
@property(nonatomic, copy) void (^inlayHintsChanged)(void);

- (void)start;
- (void)restart;
- (void)stop;
- (void)close;
- (void)install;
- (void)cancelInstall;
- (void)uninstall;
- (void)changed:(std::optional<LSPTextChange>)change;
- (void)saved;
- (BOOL)supports:(NSString *)capability;
- (BOOL)resolvesCodeActions;
- (BOOL)triggersCompletion:(NSString *)character;
- (NSInteger)request:(NSString *)method params:(NSDictionary *)params reply:(LSPReply)reply;
- (NSInteger)requestInlayHintsFrom:(LSPPosition)start to:(LSPPosition)end reply:(LSPInlayReply)reply;
- (void)cancelRequest:(NSInteger)identifier;
- (void)executeCommand:(NSDictionary *)command applyEdit:(NSString *(^)(id edit))edit reply:(LSPReply)reply;
@end

void StopLanguageServers();