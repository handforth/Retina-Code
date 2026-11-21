#pragma once

#import <AppKit/AppKit.h>
#include "Typing.h"
#include "VimMulti.hpp"

NSString *TextByApplyingEdits(NSString *source, const Vim::EditBatch &batch);

struct VimBlockCaret {
    NSRect rect;
    NSUInteger position;
};

@interface VimTextView : NSTextView
@property(nonatomic) BOOL vimEnabled;
@property(nonatomic) BOOL smoothScrollingEnabled;
@property(nonatomic, weak) NSDocument *vimDocument;
@property(nonatomic, copy) void (^vimStatusChanged)(void);
@property(nonatomic, copy) void (^vimAction)(Vim::Action, NSString *, BOOL);
@property(nonatomic, readonly) NSUInteger vimCursor;
@property(nonatomic, readonly) NSUInteger vimDisplayedCursor;
@property(nonatomic, readonly) NSUInteger vimTabStop;
@property(nonatomic, readonly) BOOL vimCommandLine;
@property(nonatomic, readonly) BOOL vimInserting;
@property(nonatomic, readonly) BOOL vimCanComplete;
@property(nonatomic, readonly) BOOL trackingVimMouseSelection;
@property(nonatomic, readonly) NSString *vimStatus;
@property(nonatomic, readonly) NSUInteger vimCommandCaret;
@property(nonatomic, readonly) NSUInteger cursorCount;

- (NSUInteger)vimDocumentLineCount;
- (NSUInteger)vimLineAtOffset:(NSUInteger)offset;
- (NSUInteger)vimOffsetAtLine:(NSUInteger)line;
- (BOOL)vimStructuralCharacterAtOffset:(NSUInteger)offset;
- (Vim::Comments)vimComments;
- (NSUInteger)vimDefinitionAt:(NSUInteger)position;
- (void)configureVimState:(Vim::State &)state;
- (BOOL)hasVimFolds;
- (NSUInteger)vimFold:(char32_t)command at:(NSUInteger)position;
- (NSUInteger)vimStepRow:(NSUInteger)row down:(BOOL)down count:(NSUInteger)count;
- (NSUInteger)vimHiddenRows:(Vim::Range)rows;
- (void)revealVimFoldAt:(NSUInteger)position;
+ (void)jumpToVimFileMark:(char32_t)mark exact:(BOOL)exact;
+ (void)vimStorage:(NSTextStorage *)storage edited:(NSRange)range newLength:(NSUInteger)length;
+ (const Vim::EditBatch *)cursorBatchForStorage:(NSTextStorage *)storage;
+ (void)vimStorage:(NSTextStorage *)storage editedBatch:(const Vim::EditBatch &)batch;
- (NSRange)selectedCharacterRange;
- (BOOL)insertionLocationsMatch:(BOOL (^)(NSUInteger position))test;
- (NSRect)vimCaretAt:(NSUInteger)position;
- (std::optional<Vim::InsertEdit>)planVimInsert:(Vim::Key)key at:(NSUInteger)position
                                      tabWidth:(unsigned)tabWidth indentWidth:(unsigned)indentWidth
                                        spaces:(BOOL)spaces automaticIndent:(BOOL)automatic;
- (void)finishVimInsertEdit;
- (std::optional<TypingEdit>)planCursorTyping:(Vim::Key)key selected:(NSRange)range
                                indentation:(const Indentation &)indentation;
- (Indentation)cursorIndentation;
- (Indentation)vimIndentation;
- (void)setVimIndentation:(Indentation)indentation;
- (void)didTypeAtCursors:(const std::vector<TypingEdit> &)edits;
- (BOOL)stageCursorTyping:(const TypingEdit &)edit;
- (void)prepareCursorBatch;
- (NSString *)vimIndentAfter:(NSUInteger)position tabWidth:(unsigned)tabWidth
                  indentWidth:(unsigned)indentWidth spaces:(BOOL)spaces;
- (NSString *)vimLineNumber:(NSUInteger)line current:(NSUInteger)current;
- (void)drawVimOverlays:(NSRect)dirty selection:(NSColor *)selection flash:(NSColor *)flash
        selectedRanges:(std::vector<NSRange> *)ranges blockCarets:(std::vector<VimBlockCaret> *)blocks;
- (void)drawVimComposition:(NSRect)dirty;
- (void)invalidateVimCaret;
- (void)refreshVimCaret;
- (void)vimDidLiveScroll;
- (void)finishVimChange;
- (std::vector<Vim::Offset>)editingCaretOffsets;
- (std::vector<Vim::Range>)editingSelections;
- (BOOL)applyDocumentEdits:(Vim::EditBatch)batch undoName:(NSString *)name;
- (BOOL)applyDocumentEdits:(Vim::EditBatch)batch undoName:(NSString *)name
          insertionAdvance:(Vim::Offset (*)(Vim::Text))advance;
- (void)loadVimMappings:(NSString *)text;
- (void)vimDocumentReplaced;
- (void)vimStorageEdited:(NSRange)range newLength:(NSUInteger)length;
- (void)vimStorageEditedBatch:(const Vim::EditBatch &)batch;
- (void)visitVimFileMark:(NSUInteger)offset exact:(BOOL)exact;
- (void)revealSearchMatch:(NSRange)range;
- (NSArray<NSArray<NSNumber *> *> *)sessionCursors;
- (void)restoreSessionCursors:(NSArray *)positions;
- (void)restoreSessionScroll:(NSPoint)origin;
- (void)applyVimKey:(Vim::Key)key text:(NSString *)text;
- (IBAction)addCursorAbove:(id)sender;
- (IBAction)addCursorBelow:(id)sender;
- (IBAction)addNextOccurrence:(id)sender;
- (IBAction)selectAllOccurrences:(id)sender;
- (IBAction)addCursorsToLineEnds:(id)sender;
- (IBAction)undoCursorChange:(id)sender;
@end