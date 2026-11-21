#pragma once

#import <AppKit/AppKit.h>

@class FolderWorkspace, FolderExplorer, SourceDocument, FolderSearchPattern;

using FolderSearchOpenMatch = void (^)(NSURL *file, SourceDocument *document, FolderSearchPattern *pattern, NSRange range);
bool FolderSearchRangeMatches(NSString *text, NSRange range, FolderSearchPattern *pattern);

@interface FolderSidebar : NSView
- (instancetype)initWithWorkspace:(FolderWorkspace *)workspace;
@property(nonatomic, readonly) FolderExplorer *explorer;
@property(nonatomic, copy) FolderSearchOpenMatch openMatch;
- (void)showSearch:(NSString *)selection replace:(BOOL)replace;
- (void)refreshSearch;
@end