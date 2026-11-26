#pragma once

#import "Rendering.h"
#import "Typing.h"
#include "Themes.h"

extern NSString *const EditorPreferencesChanged;
extern NSString *const AutoSavePreferencesChanged;
extern NSString *const OutputScrollbackPreferencesChanged;
extern NSString *const UnusedWarningsPreferencesChanged;
extern NSString *const InlayPreferencesChanged;
extern NSString *const themeKey;
extern NSString *const smoothingKey;
extern NSString *const sizeKey;
extern NSString *const vimModeKey;
extern NSString *const smoothScrollingKey;
extern NSString *const bracketColorizationKey;

inline constexpr CGFloat defaultFontSize = 11;
inline constexpr NSUInteger commonTabSizeLimit = 8;
inline constexpr NSUInteger maximumTabSize = 32;

NSUInteger OutputScrollbackLinesPreference();
BOOL ClearOutputOnRunPreference();

struct IndentationSettings {
    NSUInteger tabSize = 4;
    bool tabs = false;
    bool detect = true;

    bool operator==(const IndentationSettings &) const = default;
};

IndentationSettings IndentationPreference();
void SetIndentationPreference(IndentationSettings settings);
NSArray<NSNumber *> *EncodeIndentation(Indentation indentation);
std::optional<Indentation> DecodeIndentation(id record);
std::optional<Indentation> FileIndentationPreference(NSURL *url);
void SetFileIndentationPreference(NSURL *url, std::optional<Indentation> indentation);
void MoveFileIndentationPreferences(NSURL *from, NSURL *to, bool subtree);
void ImportSessionIndentationPreferences(NSArray *windows);
NSArray<NSMenuItem *> *TabSizeItems(NSUInteger current, id target, SEL action, BOOL largerSizes);
NSMenu *TabSizeMenu(NSUInteger current, id target, SEL action);

enum class AutoSaveMode { Off, AfterDelay, OnFocusChange, OnWindowChange };

struct AutoSaveSettings {
    AutoSaveMode mode = AutoSaveMode::Off;
    NSInteger delayMilliseconds = 1000;
    bool workspaceFilesOnly = false;
    bool whenNoErrors = false;

    bool operator==(const AutoSaveSettings &) const = default;
};

AutoSaveSettings AutoSavePreference();
void SetAutoSavePreference(AutoSaveSettings settings);

enum class FinalNewlineMode { Preserve, InsertIfMissing, TrimExtras, KeepExactlyOne, RemoveAll };

struct SaveCleanupSettings {
    bool trimTrailingWhitespace = false;
    FinalNewlineMode finalNewline = FinalNewlineMode::Preserve;
};

SaveCleanupSettings SaveCleanupPreference();
void SetSaveCleanupPreference(SaveCleanupSettings settings);
NSArray<NSString *> *FinalNewlineModeNames();

void PopulateThemeMenu(NSMenu *menu, SEL action);
NSInteger ThemePreference();
ThemeRef ThemeAt(NSInteger index);
ThemeRef SelectedTheme();
void SelectEditorTheme(NSInteger index);
BOOL BracketColorizationPreference();
Smoothing SmoothingPreference();
BOOL SmoothScrollingPreference();
RenderSettings RenderingPreference();
void SetRenderingPreference(RenderSettings settings);
CGFloat FontSizePreference();
NSFont *EditorFontPreference();
void ApplyWindowAppearancePreference();
void SetEditorPreference(NSString *key, id value);
void SetEditorFont(NSFont *font);
void SetUpEditorFontManager();

bool ShowUnusedWarnings();
bool ShowInlayHints();
NSFont *InlayFont(NSFont *editor);

@interface PreferencesController : NSWindowController
+ (PreferencesController *)sharedController;
- (void)showPane:(NSString *)identifier;
- (void)showLSPPaneForLanguage:(Language)language;
@end