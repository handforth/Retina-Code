#pragma once

#import <AppKit/AppKit.h>

NSView *CreateEditorPreview(bool compact = false);
NSView *CommandPaletteHost(NSWindow *window);
void PreviewEditorTheme(NSView *host, NSInteger index);
NSArray<NSString *> *EditorLanguageNames();
NSArray<NSMenuItem *> *LanguageFeatureCommands();

@class FolderWorkspace, SourceDocument;
FolderWorkspace *WorkspaceForEditorWindow(NSWindow *window);
NSArray<NSMenuItem *> *FileIndentationCommands(SourceDocument *document);
NSArray<SourceDocument *> *EditorWindowTabs(NSWindow *window);
SourceDocument *FocusedEditorDocument(NSWindow *window);
NSWindow *RestoreWorkspaceWindow(FolderWorkspace *workspace, NSArray<SourceDocument *> *tabs, SourceDocument *selected);
BOOL EditorWindowShowsTabBar(NSWindow *window);
BOOL EditorWindowOutputShown(NSWindow *window);
void RestoreEditorWindowOutput(NSWindow *window, BOOL shown);
void RequestEditorWindowClose(NSWindow *window);
BOOL ShowFolderSearch(NSWindow *window, BOOL replace = NO);
enum class FinalNewlineMode;
NSString *DecodeSourceText(NSData *data, BOOL *hasBOM = nullptr);
NSData *SourceDataWithFinalNewline(NSData *data, FinalNewlineMode mode);
bool IsWholeSourceWord(NSString *text, NSRange range);
namespace Vim { struct EditBatch; }
using CloseReviewCompletion = void (^)(NSSet<SourceDocument *> *discarded);
void ReviewDocumentsForClosing(NSArray<SourceDocument *> *documents, CloseReviewCompletion completion);
using SourceOpenCompletion = void (^)(NSDocument *, BOOL, NSError *);
void OpenSourceTab(NSURL *url, NSWindow *window, SourceOpenCompletion completion);

@protocol SourceFileOpening <NSObject>
- (void)openSourceURL:(NSURL *)url inWindow:(NSWindow *)window asTab:(BOOL)asTab
    completionHandler:(SourceOpenCompletion)completion;
@end

@interface SourceDocument : NSDocument
@property(nonatomic, readonly, getter=isUnusedUntitled) BOOL unusedUntitled;
@property(nonatomic, readonly) NSWindow *editorHostWindow;
@property(nonatomic) FolderWorkspace *workspace;
@property(nonatomic, readonly) NSUInteger tabSize;
@property(nonatomic, readonly) NSInteger languageMode;
@property(nonatomic, readonly) BOOL automaticLanguageMode;
- (NSString *)sourceText;
- (NSArray<NSMenuItem *> *)languagePaletteCommands;
- (BOOL)applyFolderSearchEdits:(Vim::EditBatch)batch error:(NSError **)error;
- (BOOL)applySourceEdits:(Vim::EditBatch)batch undoName:(NSString *)name error:(NSError **)error;
- (NSUInteger)languageVersion;
- (BOOL)joinTabsInWindow:(NSWindow *)window;
- (BOOL)joinNavigationTabInWindow:(NSWindow *)window;
- (BOOL)takeWindowFromUnusedDocument:(SourceDocument *)document;
- (void)setFileURLFromExplorer:(NSURL *)url;
- (void)loadExample;
- (NSDictionary *)sessionStateDiscardingChanges:(BOOL)discard;
- (BOOL)needsCloseReview;
- (BOOL)canApplySessionDraft:(NSDictionary *)state;
- (void)applySessionContents:(NSDictionary *)state recoveredFile:(BOOL)recoveredFile;
- (void)applySessionView:(NSDictionary *)state;
- (void)markSessionDraftEdited;
- (IBAction)runDocument:(id)sender;
- (IBAction)debugCommand:(NSMenuItem *)sender;
- (IBAction)toggleExplorer:(id)sender;
- (IBAction)closeEditorSplit:(id)sender;
- (IBAction)selectTheme:(NSMenuItem *)sender;
- (IBAction)selectSmoothing:(NSMenuItem *)sender;
- (IBAction)selectFont:(NSMenuItem *)sender;
- (IBAction)changeFontSize:(NSMenuItem *)sender;
- (IBAction)toggleVimMode:(NSMenuItem *)sender;
- (IBAction)setIndentationKind:(NSMenuItem *)sender;
- (IBAction)setTabSize:(NSMenuItem *)sender;
- (IBAction)convertIndentation:(NSMenuItem *)sender;
- (IBAction)detectFileIndentation:(id)sender;
- (IBAction)resetFileIndentation:(id)sender;
- (IBAction)setIndentationAsDefault:(id)sender;
- (IBAction)changeLanguageMode:(NSMenuItem *)sender;
@end