#pragma once

#import <AppKit/AppKit.h>

@class SourceDocument;

inline NSURL *CanonicalFileURL(NSURL *url)
{
    return url.isFileURL ? url.URLByStandardizingPath.URLByResolvingSymlinksInPath : nil;
}

inline bool PathIsInFolder(NSString *path, NSString *folder)
{
    if (!path.length || !folder.length)
        return false;
    return [path isEqualToString:folder] ||
        [path hasPrefix:[folder hasSuffix:@"/"] ? folder : [folder stringByAppendingString:@"/"]];
}

inline bool HiddenWorkspaceItem(NSString *name)
{
    return [name isEqualToString:@".git"] || [name isEqualToString:@".DS_Store"] ||
           [name hasPrefix:@".retina-code-"] || [name hasPrefix:@".source-editor-"];
}

extern NSNotificationName const FolderSidebarChanged;
extern NSNotificationName const FolderDocumentsChanged;
extern NSNotificationName const FolderRunChanged;

@interface FolderWorkspace : NSObject
- (instancetype)initWithFolder:(NSURL *)folder;
@property(nonatomic, readonly) NSURL *folder;
@property(nonatomic, readonly) NSString *tabbingIdentifier;
@property(nonatomic) BOOL sidebarShown;
@property(nonatomic) CGFloat sidebarWidth;
@property(nonatomic, weak) SourceDocument *selectedDocument;
@property(nonatomic, weak) SourceDocument *runningDocument;
@property(nonatomic, readonly) NSArray<SourceDocument *> *documents;
- (void)addDocument:(SourceDocument *)document;
- (void)removeDocument:(SourceDocument *)document;
- (void)documentChanged;
- (void)refresh;
- (NSArray<NSString *> *)sessionExpandedFolders;
- (void)restoreSessionExpandedFolders:(NSArray *)paths;
@end

@interface FolderExplorer : NSView
- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace;
@property(nonatomic, copy) void (^openFile)(NSURL *);
- (void)revealFile:(NSURL *)file expandingFolders:(BOOL)expand;
- (void)focusFiles;
@end