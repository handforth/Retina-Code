#import "Preferences.h"
#import "Editor.h"
#import "Runner.h"
#import "SessionState.h"
#import "Workspace.h"
#include "Themes.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <optional>
#include <string_view>
#include <vector>

NSString *const EditorPreferencesChanged = @"RetinaCodePreferencesChanged";
NSString *const AutoSavePreferencesChanged = @"RetinaCodeAutoSavePreferencesChanged";
NSString *const OutputScrollbackPreferencesChanged = @"RetinaCodeOutputScrollbackPreferencesChanged";
NSString *const themeKey = @"EditorTheme";
NSString *const smoothingKey = @"FontSmoothing";
NSString *const sizeKey = @"EditorFontSize";
NSString *const vimModeKey = @"VimMode";
NSString *const smoothScrollingKey = @"SmoothScrolling";
NSString *const bracketColorizationKey = @"BracketColorization";
static NSString *const typefaceKey = @"EditorTypeface";
static NSString *const renderingKey = @"EditorRendering";
static NSString *const customThemesKey = @"CustomThemes";
static NSString *const darkWindowAppearanceKey = @"DarkWindowAppearance";
static NSString *const autoSaveKey = @"AutoSave";
static NSString *const trimTrailingWhitespaceKey = @"TrimTrailingWhitespace";
static NSString *const finalNewlineKey = @"FinalNewline";
static NSString *const saveCleanupPreferencesChanged = @"RetinaCodeSaveCleanupPreferencesChanged";
static NSString *const indentationKey = @"EditorIndentation";
static NSString *const fileIndentationKey = @"EditorFileIndentation";
static NSString *const outputScrollbackKey = @"OutputScrollbackLines";
static NSString *const clearOutputOnRunKey = @"ClearOutputOnRun";
static constexpr long long maximumOutputScrollbackLines = 50000;

static std::atomic<NSUInteger> &CurrentOutputScrollbackLines()
{
    static std::atomic<NSUInteger> lines = [] {
        NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:outputScrollbackKey];
        if (![stored isKindOfClass:NSNumber.class])
            return outputScrollbackLines;
        return NSUInteger(std::clamp(stored.longLongValue, 1LL, maximumOutputScrollbackLines));
    }();
    return lines;
}

NSUInteger OutputScrollbackLinesPreference()
{
    return CurrentOutputScrollbackLines().load(std::memory_order_relaxed);
}

BOOL ClearOutputOnRunPreference()
{
    id value = [NSUserDefaults.standardUserDefaults objectForKey:clearOutputOnRunKey];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : YES;
}

static void SetOutputScrollbackLinesPreference(double value)
{
    NSUInteger lines = NSUInteger(std::clamp(value, 1.0, double(maximumOutputScrollbackLines)));
    if (CurrentOutputScrollbackLines().exchange(lines, std::memory_order_relaxed) == lines)
        return;
    [NSUserDefaults.standardUserDefaults setInteger:NSInteger(lines) forKey:outputScrollbackKey];
    [NSNotificationCenter.defaultCenter postNotificationName:OutputScrollbackPreferencesChanged object:nil];
}

static NSNumberFormatter *ScrollbackFormatter()
{
    static NSNumberFormatter *formatter = [] {
        NSNumberFormatter *number = [[NSNumberFormatter alloc] init];
        number.numberStyle = NSNumberFormatterDecimalStyle;
        number.allowsFloats = NO;
        return number;
    }();
    return formatter;
}

static IndentationSettings &CurrentIndentationSettings()
{
    static IndentationSettings settings = [] {
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:indentationKey];
        IndentationSettings value;
        NSNumber *size = stored[@"tabSize"];
        if ([size isKindOfClass:NSNumber.class] && size.integerValue >= 1 && size.integerValue <= NSInteger(maximumTabSize))
            value.tabSize = size.unsignedIntegerValue;
        if ([stored[@"tabs"] isKindOfClass:NSNumber.class])
            value.tabs = [stored[@"tabs"] boolValue];
        if ([stored[@"detect"] isKindOfClass:NSNumber.class])
            value.detect = [stored[@"detect"] boolValue];
        return value;
    }();
    return settings;
}

IndentationSettings IndentationPreference() { return CurrentIndentationSettings(); }

void SetIndentationPreference(IndentationSettings settings)
{
    settings.tabSize = std::clamp(settings.tabSize, NSUInteger(1), maximumTabSize);
    IndentationSettings &current = CurrentIndentationSettings();
    if (current == settings)
        return;
    current = settings;
    [NSUserDefaults.standardUserDefaults setObject:@{@"tabSize":@(settings.tabSize),
        @"tabs":@(settings.tabs), @"detect":@(settings.detect)} forKey:indentationKey];
    [NSNotificationCenter.defaultCenter postNotificationName:EditorPreferencesChanged object:nil];
}

NSArray<NSNumber *> *EncodeIndentation(Indentation indentation)
{
    return @[@(indentation.tabWidth), @(indentation.width), @(indentation.tabs)];
}

std::optional<Indentation> DecodeIndentation(id record)
{
    NSArray *values = SessionArray(record);
    if (values.count != 3)
        return std::nullopt;
    NSInteger tab = [SessionNumber(values[0]) integerValue];
    NSInteger width = [SessionNumber(values[1]) integerValue];
    NSNumber *tabs = SessionNumber(values[2]);
    if (tab < 1 || tab > NSInteger(maximumTabSize) || width < 1 || width > NSInteger(maximumTabSize) || !tabs)
        return std::nullopt;
    return Indentation{NSUInteger(tab), NSUInteger(width), tabs.boolValue != NO, true};
}

std::optional<Indentation> FileIndentationPreference(NSURL *url)
{
    NSString *path = CanonicalFileURL(url).path;
    if (!path)
        return std::nullopt;
    return DecodeIndentation([NSUserDefaults.standardUserDefaults dictionaryForKey:fileIndentationKey][path]);
}

void SetFileIndentationPreference(NSURL *url, std::optional<Indentation> indentation)
{
    NSString *path = CanonicalFileURL(url).path;
    if (!path)
        return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [defaults dictionaryForKey:fileIndentationKey];
    NSArray *record = indentation ? EncodeIndentation(*indentation) : nil;
    id previous = saved[path];
    if (previous == record || [previous isEqual:record])
        return;
    NSMutableDictionary *updated = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    updated[path] = record;
    [defaults setObject:updated forKey:fileIndentationKey];
}

void MoveFileIndentationPreferences(NSURL *from, NSURL *to, bool subtree)
{
    NSString *source = from.URLByStandardizingPath.path;
    NSString *destination = to.URLByStandardizingPath.path;
    if (!source.length || [source isEqualToString:destination])
        return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *saved = [defaults dictionaryForKey:fileIndentationKey];
    NSMutableDictionary *updated = nil;
    for (NSString *path in saved) {
        if (subtree ? !PathIsInFolder(path, source) : ![path isEqualToString:source])
            continue;
        if (!updated)
            updated = [saved mutableCopy];
        [updated removeObjectForKey:path];
        if (destination) {
            NSString *suffix = [path substringFromIndex:source.length];
            updated[[destination stringByAppendingString:suffix]] = saved[path];
        }
    }
    if (updated)
        [defaults setObject:updated forKey:fileIndentationKey];
}

void ImportSessionIndentationPreferences(NSArray *windows)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Older builds stored overrides in the open session. Import them once.
    if ([defaults dictionaryForKey:fileIndentationKey])
        return;
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    for (id window in windows) {
        for (id entry in SessionArray(SessionDictionary(window)[@"tabs"])) {
            NSDictionary *tab = SessionDictionary(entry);
            NSString *path = SessionString(tab[@"path"]);
            auto indentation = DecodeIndentation(SessionDictionary(tab[@"view"])[@"indentation"]);
            if (path.isAbsolutePath && indentation) {
                NSURL *file = CanonicalFileURL([NSURL fileURLWithPath:path]);
                files[file.path] = EncodeIndentation(*indentation);
            }
        }
    }
    [defaults setObject:files forKey:fileIndentationKey];
}

static NSMenuItem *TabSizeItem(NSUInteger size, NSUInteger current, id target, SEL action)
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@(size).stringValue action:action keyEquivalent:@""];
    item.target = target;
    item.tag = NSInteger(size);
    item.state = size == current ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

NSArray<NSMenuItem *> *TabSizeItems(NSUInteger current, id target, SEL action, BOOL largerSizes)
{
    NSUInteger first = largerSizes ? commonTabSizeLimit + 1 : 1;
    NSUInteger last = largerSizes ? maximumTabSize : commonTabSizeLimit;
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray arrayWithCapacity:last - first + 1];
    for (NSUInteger size = first; size <= last; ++size)
        [items addObject:TabSizeItem(size, current, target, action)];
    if (!largerSizes && current > commonTabSizeLimit)
        [items addObject:TabSizeItem(current, current, target, action)];
    return items;
}

NSMenu *TabSizeMenu(NSUInteger current, id target, SEL action)
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Tab Size"];
    for (NSMenuItem *item in TabSizeItems(current, target, action, NO))
        [menu addItem:item];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *more = [menu addItemWithTitle:@"More" action:nullptr keyEquivalent:@""];
    more.submenu = [[NSMenu alloc] initWithTitle:more.title];
    for (NSMenuItem *item in TabSizeItems(current, target, action, YES))
        [more.submenu addItem:item];
    return menu;
}

static AutoSaveSettings &CurrentAutoSaveSettings()
{
    static AutoSaveSettings settings = [] {
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:autoSaveKey];
        AutoSaveSettings value;
        NSNumber *mode = stored[@"mode"];
        if ([mode isKindOfClass:NSNumber.class] && mode.integerValue >= NSInteger(AutoSaveMode::Off) &&
            mode.integerValue <= NSInteger(AutoSaveMode::OnWindowChange))
            value.mode = AutoSaveMode(mode.integerValue);
        NSNumber *delay = stored[@"delay"];
        if ([delay isKindOfClass:NSNumber.class] && delay.integerValue >= 0)
            value.delayMilliseconds = delay.integerValue;
        if ([stored[@"workspaceFilesOnly"] isKindOfClass:NSNumber.class])
            value.workspaceFilesOnly = [stored[@"workspaceFilesOnly"] boolValue];
        if ([stored[@"whenNoErrors"] isKindOfClass:NSNumber.class])
            value.whenNoErrors = [stored[@"whenNoErrors"] boolValue];
        return value;
    }();
    return settings;
}

AutoSaveSettings AutoSavePreference() { return CurrentAutoSaveSettings(); }

void SetAutoSavePreference(AutoSaveSettings settings)
{
    if (settings.mode < AutoSaveMode::Off || settings.mode > AutoSaveMode::OnWindowChange)
        settings.mode = AutoSaveMode::Off;
    settings.delayMilliseconds = std::max<NSInteger>(0, settings.delayMilliseconds);
    AutoSaveSettings &current = CurrentAutoSaveSettings();
    if (settings == current)
        return;
    current = settings;
    [NSUserDefaults.standardUserDefaults setObject:@{@"mode":@(NSInteger(settings.mode)),
         @"delay":@(settings.delayMilliseconds), @"workspaceFilesOnly":@(settings.workspaceFilesOnly),
         @"whenNoErrors":@(settings.whenNoErrors)} forKey:autoSaveKey];
    [NSNotificationCenter.defaultCenter postNotificationName:AutoSavePreferencesChanged object:nil];
}

SaveCleanupSettings SaveCleanupPreference()
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger mode = [defaults integerForKey:finalNewlineKey];
    if (mode < NSInteger(FinalNewlineMode::Preserve) || mode > NSInteger(FinalNewlineMode::RemoveAll))
        mode = NSInteger(FinalNewlineMode::Preserve);
    return {bool([defaults boolForKey:trimTrailingWhitespaceKey]), FinalNewlineMode(mode)};
}

void SetSaveCleanupPreference(SaveCleanupSettings settings)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:settings.trimTrailingWhitespace forKey:trimTrailingWhitespaceKey];
    [defaults setInteger:NSInteger(settings.finalNewline) forKey:finalNewlineKey];
    [NSNotificationCenter.defaultCenter postNotificationName:saveCleanupPreferencesChanged object:nil];
}

NSArray<NSString *> *FinalNewlineModeNames()
{
    static NSArray<NSString *> *names = @[@"Preserve", @"Insert If Missing", @"Trim Extras", @"Keep Exactly One", @"Remove All"];
    return names;
}

static constexpr NSInteger lightHeading = -1;
static constexpr NSInteger darkHeading = -2;
static constexpr size_t whitespaceColorIndex = 8;

template<typename Palette>
static auto ColorFields(Palette &theme)
{
    // Keep a slot for the optional caret in the existing color order.
    return std::array{
        &theme.paper, &theme.line, &theme.selection, &theme.gutter, &theme.rule, &theme.lineNumber,
        &theme.activeNumber, decltype(&theme.paper){}, &theme.whitespace,
        &theme.ink[size_t(Ink::Text)], &theme.ink[size_t(Ink::Keyword)], &theme.ink[size_t(Ink::Control)],
        &theme.ink[size_t(Ink::Type)], &theme.ink[size_t(Ink::Function)], &theme.ink[size_t(Ink::Name)],
        &theme.ink[size_t(Ink::String)], &theme.ink[size_t(Ink::Number)], &theme.ink[size_t(Ink::Comment)],
        &theme.ink[size_t(Ink::Directive)], &theme.ink[size_t(Ink::Constant)], &theme.ink[size_t(Ink::Escape)],
        &theme.accents.completionPaper, &theme.accents.completionBorder, &theme.accents.completionSelection,
        &theme.accents.completionSelectedText, &theme.accents.wordMatch, &theme.accents.bracketMatch,
        &theme.accents.vimFlash, &theme.accents.commandCaret,
    };
}

static std::optional<Col32> EditableThemeColor(const Theme &theme, const Col32 *field)
{
    return field ? std::optional{*field} : theme.caret;
}

static std::optional<Col32> SavedThemeColor(id value, bool packed)
{
    if (![value isKindOfClass:NSNumber.class])
        return {};
    auto color = [value unsignedLongLongValue];
    if (packed)
        return color <= UINT32_MAX ? std::optional{Col32(color)} : std::nullopt;
    if (color > (UINT32_MAX >> 8))
        return {};
    // Earlier versions stored opaque colors as RRGGBB.
    return rgb(color >> 16, color >> 8, color);
}

struct CustomTheme {
    NSString *identifier;
    NSString *title;
    Theme palette;
    std::vector<Col32> brackets;

    CustomTheme(NSString *identifier, NSString *title, Theme palette, std::vector<Col32> brackets)
        : identifier([identifier copy]), title([title copy]), palette(palette), brackets(std::move(brackets))
    {
        this->palette.name = nullptr;
        this->palette.bracketColors = this->brackets;
    }
};

static auto &CustomThemes()
{
    static auto records = [] {
        std::vector<std::shared_ptr<const CustomTheme>> list;
        for (id item in [NSUserDefaults.standardUserDefaults arrayForKey:customThemesKey]) {
            if (![item isKindOfClass:NSDictionary.class])
                continue;
            NSDictionary *row = item;
            NSString *identifier = row[@"id"];
            NSString *title = row[@"name"];
            NSArray *values = row[@"colors"];
            Theme theme = themes[0];
            auto fields = ColorFields(theme);
            if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
                ![title isKindOfClass:NSString.class] || !title.length ||
                ![values isKindOfClass:NSArray.class] ||
                (values.count != fields.size() && values.count != fields.size() - 1))
                continue;

            bool packed = [row[@"colorFormat"] isEqual:@"RGBA"];
            bool missingWhitespace = values.count < fields.size();
            bool hasWhitespaceColor = false;
            for (size_t i = 0; i < values.count; ++i) {
                Col32 *field = fields[i + (missingWhitespace && i >= whitespaceColorIndex)];
                auto color = SavedThemeColor(values[i], packed);
                if (!field) {
                    theme.caret = color;
                } else if (color) {
                    *field = *color;
                    hasWhitespaceColor |= field == &theme.whitespace;
                }
            }
            id dark = row[@"dark"];
            id italicTypes = row[@"italicTypes"];
            id italicComments = row[@"italicComments"];
            id contrastingSelectionText = row[@"contrastingSelectionText"];
            theme.dark = [dark isKindOfClass:NSNumber.class] && [dark boolValue];
            theme.italicTypes = [italicTypes isKindOfClass:NSNumber.class] && [italicTypes boolValue];
            theme.italicComments = [italicComments isKindOfClass:NSNumber.class] && [italicComments boolValue];
            theme.contrastingSelectionText = [contrastingSelectionText isKindOfClass:NSNumber.class] &&
                                              [contrastingSelectionText boolValue];
            theme.blockCaretText = SavedThemeColor(row[@"blockCaretText"], packed);
            if (!hasWhitespaceColor)
                theme.whitespace = DefaultWhitespaceColor(theme.paper, theme.line, theme.selection, theme.lineNumber, theme.dark);
            std::vector<Col32> brackets;
            if ([row[@"brackets"] isKindOfClass:NSArray.class]) {
                for (id value in row[@"brackets"]) {
                    if (auto color = SavedThemeColor(value, packed))
                        brackets.push_back(*color);
                }
            }
            list.push_back(std::make_shared<const CustomTheme>(identifier, title, theme, std::move(brackets)));
        }
        return list;
    }();
    return records;
}

static constexpr NSInteger builtinThemeCount = std::size(themes);

// Preserve the saved slots after the retired Xcode Presentation presets.
static constexpr NSInteger firstRetiredThemeSlot = 110;
static constexpr NSInteger retiredThemeReplacements[] = {104, 105, 104, 105};
static constexpr NSInteger retiredThemeSlotCount = std::size(retiredThemeReplacements);
static_assert(std::string_view(themes[retiredThemeReplacements[0]].name) == "Xcode Default (Dark)");
static_assert(std::string_view(themes[retiredThemeReplacements[1]].name) == "Xcode Default (Light)");

static NSInteger ThemeCount()
{
    return builtinThemeCount + NSInteger(CustomThemes().size());
}

static bool IsCustomTheme(NSInteger index)
{
    return index >= builtinThemeCount && index < ThemeCount();
}

static NSInteger CustomThemeIndex(NSString *identifier)
{
    const auto &records = CustomThemes();
    for (size_t i = 0; i < records.size(); ++i) {
        if ([records[i]->identifier isEqualToString:identifier])
            return builtinThemeCount + NSInteger(i);
    }
    return -1;
}

ThemeRef ThemeAt(NSInteger index)
{
    if (IsCustomTheme(index)) {
        const auto &record = CustomThemes()[index - builtinThemeCount];
        return ThemeRef(record, &record->palette);
    }
    return StaticTheme(&themes[index >= 0 && index < builtinThemeCount ? index : 0]);
}

static NSString *ThemeRowTitle(NSInteger index)
{
    if (index == lightHeading)
        return @"Light";
    if (index == darkHeading)
        return @"Dark";
    if (IsCustomTheme(index))
        return CustomThemes()[index - builtinThemeCount]->title;
    return @(themes[index].name);
}

static std::vector<NSInteger> ThemeRows()
{
    const NSInteger count = ThemeCount();
    std::vector<NSInteger> rows;
    rows.reserve(count + 2);
    for (bool dark : {false, true}) {
        rows.push_back(dark ? darkHeading : lightHeading);
        size_t sectionStart = rows.size();
        for (NSInteger index = 0; index < count; ++index) {
            if (ThemeAt(index)->dark == dark)
                rows.push_back(index);
        }
        std::sort(rows.begin() + sectionStart, rows.end(), [](NSInteger first, NSInteger second) {
            NSComparisonResult order = [ThemeRowTitle(first) localizedStandardCompare:ThemeRowTitle(second)];
            return order == NSOrderedSame ? first < second : order == NSOrderedAscending;
        });
    }
    return rows;
}

void PopulateThemeMenu(NSMenu *menu, SEL action)
{
    [menu removeAllItems];
    for (NSInteger index : ThemeRows()) {
        if (index == darkHeading) {
            NSMenuItem *separator = NSMenuItem.separatorItem;
            separator.tag = -1;
            [menu addItem:separator];
        }

        NSString *title = ThemeRowTitle(index);
        NSMenuItem *item;
        if (index < 0) {
            if (@available(macOS 14.0, *))
                item = [NSMenuItem sectionHeaderWithTitle:title];
            else
                item = [[NSMenuItem alloc] initWithTitle:title action:nullptr keyEquivalent:@""];
            item.enabled = NO;
        } else {
            item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        }
        item.tag = index;
        [menu addItem:item];
    }
}

NSInteger ThemePreference()
{
    id selection = [NSUserDefaults.standardUserDefaults objectForKey:themeKey];
    if ([selection isKindOfClass:NSString.class]) {
        NSInteger index = CustomThemeIndex(selection);
        if (index >= 0)
            return index;
    } else if ([selection isKindOfClass:NSNumber.class]) {
        NSInteger index = [selection integerValue];
        if (index >= firstRetiredThemeSlot) {
            NSInteger retiredIndex = index - firstRetiredThemeSlot;
            if (retiredIndex < retiredThemeSlotCount)
                return retiredThemeReplacements[retiredIndex];
            index -= retiredThemeSlotCount;
        }
        if (index >= 0 && index < builtinThemeCount)
            return index;
    }
    return 0;
}

ThemeRef SelectedTheme()
{
    return ThemeAt(ThemePreference());
}

void SelectEditorTheme(NSInteger index)
{
    if (IsCustomTheme(index))
        SetEditorPreference(themeKey, CustomThemes()[index - builtinThemeCount]->identifier);
    else if (index >= 0 && index < builtinThemeCount) {
        NSInteger slot = index < firstRetiredThemeSlot ? index : index + retiredThemeSlotCount;
        SetEditorPreference(themeKey, @(slot));
    }
}

BOOL BracketColorizationPreference()
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return ![defaults objectForKey:bracketColorizationKey] || [defaults boolForKey:bracketColorizationKey];
}

Smoothing SmoothingPreference()
{
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:smoothingKey];
    if (value == NSInteger(Smoothing::RetinaWeb) || value == NSInteger(Smoothing::System))
        return Smoothing(value);
    return Smoothing::RetinaLCD;
}

BOOL SmoothScrollingPreference()
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:smoothScrollingKey] ? [defaults boolForKey:smoothScrollingKey] : YES;
}

static constexpr CGFloat minimumBrightness = 0.5;
static constexpr CGFloat maximumBrightness = 1.5;

static CGFloat RenderingFactor(NSDictionary *values, NSString *key, CGFloat fallback, CGFloat minimum = 0, CGFloat maximum = 2)
{
    NSNumber *number = values[key];
    if (![number isKindOfClass:NSNumber.class] || !std::isfinite(number.doubleValue))
        return fallback;
    return std::clamp(number.doubleValue, minimum, maximum);
}

RenderSettings RenderingPreference()
{
    NSDictionary *values = [NSUserDefaults.standardUserDefaults dictionaryForKey:renderingKey];
    RenderSettings settings;
    settings.smoothing = SmoothingPreference();
    settings.saturation = RenderingFactor(values, @"saturation", settings.saturation);
    settings.strokeWeight = RenderingFactor(values, @"stroke", settings.strokeWeight);
    settings.fringing = RenderingFactor(values, @"fringing", settings.fringing);
    settings.softness = RenderingFactor(values, @"softness", settings.softness);
    settings.brightness = RenderingFactor(values, @"brightness", settings.brightness, minimumBrightness, maximumBrightness);
    NSNumber *whitespace = values[@"whitespace"];
    if ([whitespace isKindOfClass:NSNumber.class] && whitespace.integerValue >= NSInteger(WhitespaceMode::None) &&
        whitespace.integerValue <= NSInteger(WhitespaceMode::All))
        settings.whitespace = WhitespaceMode(whitespace.integerValue);
    return settings;
}

CGFloat FontSizePreference()
{
    CGFloat size = [NSUserDefaults.standardUserDefaults doubleForKey:sizeKey];
    return std::isfinite(size) && size > 0 ? size : defaultFontSize;
}

NSFont *EditorFontPreference()
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    CGFloat size = FontSizePreference();
    NSDictionary *typeface = [defaults dictionaryForKey:typefaceKey];
    NSString *name = typeface[@"name"];
    if ([name isKindOfClass:NSString.class] && name.length) {
        NSFont *named = [NSFont fontWithName:name size:size];
        if (named) {
            NSData *archive = typeface[@"descriptor"];
            if ([archive isKindOfClass:NSData.class]) {
                NSFontDescriptor *descriptor = [NSKeyedUnarchiver unarchivedObjectOfClass:NSFontDescriptor.class
                                                                                 fromData:archive error:nil];
                NSFont *face = descriptor ? [NSFont fontWithDescriptor:descriptor size:size] : nil;
                if ([face.fontName isEqualToString:named.fontName])
                    return face;
            }
            return named;
        }
    } else if ([defaults integerForKey:@"EditorFont"] == 1) {
        NSFont *monaco = [NSFont fontWithName:@"Monaco" size:size];
        if (monaco)
            return monaco;
    }
    NSFont *menlo = [NSFont fontWithName:@"Menlo-Regular" size:size];
    return menlo ? menlo : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

static void PublishPreferences()
{
    [NSNotificationCenter.defaultCenter postNotificationName:EditorPreferencesChanged object:nil];
}

void ApplyWindowAppearancePreference()
{
    BOOL dark = [NSUserDefaults.standardUserDefaults boolForKey:darkWindowAppearanceKey];
    NSApp.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

static NSUInteger themeListRevision = 0;

static void SaveCustomThemes()
{
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:CustomThemes().size()];
    for (const auto &record : CustomThemes()) {
        auto fields = ColorFields(record->palette);
        NSMutableArray *colors = [NSMutableArray arrayWithCapacity:fields.size()];
        for (auto field : fields) {
            auto color = EditableThemeColor(record->palette, field);
            [colors addObject:color ? @(*color) : @(-1)];
        }
        NSMutableArray *brackets = [NSMutableArray arrayWithCapacity:record->brackets.size()];
        for (Col32 color : record->brackets)
            [brackets addObject:@(color)];
        NSMutableDictionary *row = [@{@"id":record->identifier, @"name":record->title, @"colors":colors,
            @"colorFormat":@"RGBA",
            @"dark":@(record->palette.dark), @"italicTypes":@(record->palette.italicTypes),
            @"italicComments":@(record->palette.italicComments), @"brackets":brackets} mutableCopy];
        if (record->palette.blockCaretText)
            row[@"blockCaretText"] = @(*record->palette.blockCaretText);
        if (record->palette.contrastingSelectionText)
            row[@"contrastingSelectionText"] = @YES;
        [rows addObject:row];
    }
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:customThemesKey];
}

static NSString *UniqueThemeName(NSString *name, NSInteger except = -1)
{
    NSString *title = name;
    for (NSUInteger suffix = 2;; ++suffix) {
        bool found = false;
        for (NSInteger i = 0; i < ThemeCount(); ++i) {
            if (i != except && [title caseInsensitiveCompare:ThemeRowTitle(i)] == NSOrderedSame) {
                found = true;
                break;
            }
        }
        if (!found)
            return title;
        title = [NSString stringWithFormat:@"%@ %lu", name, (unsigned long)suffix];
    }
}

static NSInteger DuplicateTheme(NSInteger index, std::vector<Col32> brackets)
{
    auto theme = ThemeAt(index);
    NSString *title = UniqueThemeName([ThemeRowTitle(index) stringByAppendingString:@" Copy"]);
    NSInteger selected = ThemeCount();
    CustomThemes().push_back(std::make_shared<const CustomTheme>(NSUUID.UUID.UUIDString, title, *theme,
                                                                 std::move(brackets)));
    ++themeListRevision;
    SaveCustomThemes();
    SelectEditorTheme(selected);
    return selected;
}

static void UpdateCustomTheme(NSInteger index, NSString *title, const Theme &theme,
                              std::vector<Col32> brackets)
{
    if (!IsCustomTheme(index))
        return;
    auto &record = CustomThemes()[index - builtinThemeCount];
    if (![record->title isEqualToString:title] || record->palette.dark != theme.dark)
        ++themeListRevision;
    record = std::make_shared<const CustomTheme>(record->identifier, title, theme, std::move(brackets));
    SaveCustomThemes();
    PublishPreferences();
}

static std::vector<Col32> CopyBrackets(const Theme &theme)
{
    return {theme.bracketColors.begin(), theme.bracketColors.end()};
}

static void SetBracketPalette(NSInteger index, std::vector<Col32> brackets)
{
    if (!IsCustomTheme(index)) {
        DuplicateTheme(index, std::move(brackets));
        return;
    }
    auto theme = ThemeAt(index);
    UpdateCustomTheme(index, ThemeRowTitle(index), *theme, std::move(brackets));
}

static std::optional<Col32> RGBValue(NSColor *color)
{
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!srgb)
        return {};
    auto component = [](CGFloat value) {
        return uint8_t(std::lround(std::clamp(value, CGFloat(0), CGFloat(1)) * 255));
    };
    return rgb(component(srgb.redComponent), component(srgb.greenComponent), component(srgb.blueComponent));
}

void SetEditorPreference(NSString *key, id value)
{
    [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    PublishPreferences();
}

void SetEditorFont(NSFont *font)
{
    if (!font || font.pointSize <= 0 || !std::isfinite(font.pointSize))
        return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:font.fontDescriptor
                                           requiringSecureCoding:YES error:nil];
    NSMutableDictionary *typeface = [@{@"name":font.fontName} mutableCopy];
    if (archive)
        typeface[@"descriptor"] = archive;
    [defaults setObject:typeface forKey:typefaceKey];
    [defaults setDouble:font.pointSize forKey:sizeKey];
    PublishPreferences();
}

void SetRenderingPreference(RenderSettings value)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:NSInteger(value.smoothing) forKey:smoothingKey];
    [defaults setObject:@{@"saturation":@(value.saturation), @"stroke":@(value.strokeWeight),
                          @"fringing":@(value.fringing), @"softness":@(value.softness),
                          @"brightness":@(value.brightness), @"whitespace":@(NSInteger(value.whitespace))}
                forKey:renderingKey];
    PublishPreferences();
}

static NSTextField *Label(NSView *parent, NSString *text, NSRect frame, NSTextAlignment alignment)
{
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.alignment = alignment;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [parent addSubview:label];
    return label;
}

static NSTabViewItem *AddPreferencesTab(NSTabView *tabs, NSString *title)
{
    NSTabViewItem *tab = [[NSTabViewItem alloc] initWithIdentifier:title];
    tab.label = title;
    [tabs addTabViewItem:tab];
    tab.view.frame = tabs.contentRect;
    return tab;
}

static void AddPreview(NSView *pane, NSRect frame)
{
    Label(pane, @"Preview", NSMakeRect(NSMinX(frame), NSMaxY(frame) + 5, NSWidth(frame), 17), NSTextAlignmentLeft);
    NSView *preview = CreateEditorPreview();
    preview.frame = frame;
    [pane addSubview:preview];
}

static constexpr Smoothing smoothingChoices[] = {Smoothing::RetinaLCD, Smoothing::RetinaWeb, Smoothing::System};
static const struct {
    NSString *label;
    CGFloat RenderSettings::*factor;
} renderingSliders[] = {
    {@"Brightness", &RenderSettings::brightness},
    {@"Saturation", &RenderSettings::saturation},
    {@"Stroke Weight", &RenderSettings::strokeWeight},
    {@"RGB Fringing", &RenderSettings::fringing},
    {@"Edge Softness", &RenderSettings::softness},
};
static constexpr CGFloat preferencesHeight = 506;
static constexpr CGFloat editingHeight = 267;
static constexpr CGFloat filesHeight = 296;
static constexpr CGFloat outputHeight = 166;

@interface PreferencesContent : NSView
@end

@implementation PreferencesContent

- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirty
{
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
}

- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

static NSString *const colorTitles[] = {
    @"Background", @"Current Line", @"Selection", @"Gutter", @"Divider", @"Line Numbers",
    @"Current Line Number", @"Caret", @"Whitespace",
    @"Text", @"Keyword", @"Control Flow", @"Type", @"Function", @"Identifier", @"String", @"Number",
    @"Comment", @"Directive", @"Constant", @"Escape",
    @"Completion Background", @"Completion Border", @"Completion Selection", @"Selected Completion Text",
    @"Word Match", @"Matching Bracket", @"Yank Flash", @"Command Caret",
};

static_assert(std::size(colorTitles) == std::tuple_size_v<decltype(ColorFields(std::declval<Theme &>()))>);

@interface PreferencesController () <NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
- (NSMenu *)menuForThemeRow:(NSInteger)row;
@end

@interface ThemeTable : NSTableView
@property(nonatomic, weak) PreferencesController *preferences;
@end

@implementation ThemeTable

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    return [self.preferences menuForThemeRow:[self rowAtPoint:point]];
}

@end

@implementation PreferencesController {
    NSTabView *_preferenceTabs;
    NSTableView *_themes;
    std::vector<NSInteger> _themeRows;
    NSUInteger _themeRevision;
    BOOL _refreshingThemes;
    NSPopUpButton *_smoothing;
    NSPopUpButton *_renderWhitespace;
    NSTextField *_fontDescription;
    NSButton *_smoothScrolling;
    NSButton *_vimMode;
    NSSegmentedControl *_indentKind;
    NSPopUpButton *_tabSize;
    NSUInteger _displayedTabSize;
    NSButton *_detectIndentation;
    NSPopUpButton *_autoSaveMode;
    NSTextField *_autoSaveDelay;
    NSButton *_autoSaveWorkspaceFilesOnly;
    NSButton *_autoSaveWhenNoErrors;
    NSButton *_trimTrailingWhitespace;
    NSPopUpButton *_finalNewline;
    NSTextField *_outputScrollback;
    NSButton *_colorizeBrackets;
    NSScrollView *_bracketScroll;
    NSView *_bracketStrip;
    NSMutableArray<NSColorWell *> *_bracketWells;
    NSButton *_addBracket;
    NSButton *_removeBracket;
    CGFloat _bracketX;
    NSInteger _bracketTheme;
    NSPanel *_themeEditor;
    NSTextField *_themeName;
    NSPopUpButton *_themeStyle;
    NSButton *_italicTypes;
    NSMutableArray<NSColorWell *> *_themeWells;
    NSInteger _editingTheme;
    NSMutableArray<NSSlider *> *_sliders;
    NSMutableArray<NSTextField *> *_values;
}

- (instancetype)init
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, preferencesHeight)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self)
        return nil;
    window.title = @"Preferences";
    window.restorable = NO;
    [window center];
    _themeRows = ThemeRows();
    _themeRevision = themeListRevision;
    _bracketTheme = -1;
    _editingTheme = -1;

    NSView *body = [[PreferencesContent alloc] initWithFrame:window.contentView.bounds];
    window.contentView = body;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(body.bounds, 12, 12)];
    _preferenceTabs = tabs;
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [body addSubview:tabs];

    NSTabViewItem *appearance = AddPreferencesTab(tabs, @"Appearance");
    [self buildAppearance:appearance.view];
    appearance.initialFirstResponder = _themes;

    NSTabViewItem *rendering = AddPreferencesTab(tabs, @"Rendering");
    [self buildRendering:rendering.view];
    rendering.initialFirstResponder = _smoothing;

    NSTabViewItem *editing = AddPreferencesTab(tabs, @"Editing");
    [self buildEditing:editing.view];
    editing.initialFirstResponder = _smoothScrolling;

    NSTabViewItem *files = AddPreferencesTab(tabs, @"Files");
    [self buildFiles:files.view];
    files.initialFirstResponder = _autoSaveMode;

    NSTabViewItem *output = AddPreferencesTab(tabs, @"Output");
    [self buildOutput:output.view];
    output.initialFirstResponder = _outputScrollback;

    [tabs selectTabViewItem:appearance];
    tabs.delegate = self;
    window.initialFirstResponder = _themes;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged:)
                                               name:EditorPreferencesChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(autoSavePreferencesChanged:)
                                               name:AutoSavePreferencesChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(saveCleanupPreferencesChanged:)
                                               name:saveCleanupPreferencesChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(finishScrollbackEditing:)
                                               name:NSWindowWillCloseNotification object:window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(finishScrollbackEditing:)
                                               name:NSApplicationWillTerminateNotification object:NSApp];
    [self preferencesChanged:nil];
    [self autoSavePreferencesChanged:nil];
    [self saveCleanupPreferencesChanged:nil];
    return self;
}

- (void)buildAppearance:(NSView *)pane
{
    const CGFloat margin = 16;
    const CGFloat listWidth = 224;
    CGFloat width = NSWidth(pane.bounds);
    CGFloat height = NSHeight(pane.bounds);
    CGFloat appearanceY = height - 31;
    Label(pane, @"Window Appearance", NSMakeRect(margin, appearanceY, 132, 18), NSTextAlignmentLeft);
    NSSegmentedControl *windowAppearance = [NSSegmentedControl segmentedControlWithLabels:@[@"Light", @"Dark"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeWindowAppearance:)];
    windowAppearance.frame = NSMakeRect(margin + 134, appearanceY - 3, 116, 24);
    windowAppearance.accessibilityLabel = @"Window Appearance";
    windowAppearance.selectedSegment = [NSUserDefaults.standardUserDefaults boolForKey:darkWindowAppearanceKey] ? 1 : 0;
    [pane addSubview:windowAppearance];

    CGFloat listTop = height - 69;
    Label(pane, @"Color Scheme", NSMakeRect(margin, listTop + 5, listWidth, 17), NSTextAlignmentLeft);

    NSRect listFrame = NSMakeRect(margin, 52, listWidth, listTop - 52);
    NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:listFrame];
    listScroll.borderType = NSBezelBorder;
    listScroll.scrollerStyle = NSScrollerStyleLegacy;
    listScroll.hasVerticalScroller = YES;
    listScroll.autohidesScrollers = YES;
    ThemeTable *table = [[ThemeTable alloc] initWithFrame:NSMakeRect(0, 0, listScroll.contentSize.width,
                                                                    listScroll.contentSize.height)];
    table.preferences = self;
    _themes = table;
    _themes.style = NSTableViewStylePlain;
    _themes.headerView = nil;
    _themes.rowHeight = 19;
    _themes.intercellSpacing = NSZeroSize;
    _themes.allowsEmptySelection = NO;
    _themes.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _themes.autoresizingMask = NSViewWidthSizable;
    _themes.accessibilityLabel = @"Color Scheme";
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"ColorScheme"];
    column.width = listScroll.contentSize.width;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_themes addTableColumn:column];
    _themes.dataSource = self;
    _themes.delegate = self;
    listScroll.documentView = _themes;
    [pane addSubview:listScroll];
    NSButton *duplicate = [NSButton buttonWithTitle:@"Duplicate" target:self action:@selector(duplicateTheme:)];
    duplicate.frame = NSMakeRect(margin - 4, 17, 98, 28);
    [pane addSubview:duplicate];
    NSButton *edit = [NSButton buttonWithTitle:@"Edit…" target:self action:@selector(editTheme:)];
    edit.frame = NSMakeRect(margin + 98, 17, 87, 28);
    [pane addSubview:edit];

    CGFloat previewX = NSMaxX(listFrame) + margin;
    CGFloat previewWidth = width - previewX - margin;
    AddPreview(pane, NSMakeRect(previewX, 111, previewWidth, listTop - 111));

    _colorizeBrackets = [NSButton checkboxWithTitle:@"Colorize brackets" target:self action:@selector(toggleBrackets:)];
    _colorizeBrackets.frame = NSMakeRect(previewX, 67, 148, 22);
    [pane addSubview:_colorizeBrackets];
    _bracketX = previewX + 148;
    _bracketScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(_bracketX, 51, previewWidth - 232, 41)];
    _bracketScroll.drawsBackground = NO;
    _bracketScroll.hasHorizontalScroller = YES;
    _bracketScroll.autohidesScrollers = YES;
    _bracketScroll.scrollerStyle = NSScrollerStyleOverlay;
    _bracketScroll.accessibilityLabel = @"Bracket Colors";
    _bracketStrip = [[NSView alloc] initWithFrame:NSZeroRect];
    _bracketScroll.documentView = _bracketStrip;
    [pane addSubview:_bracketScroll];
    _bracketWells = [NSMutableArray array];
    _addBracket = [NSButton buttonWithTitle:@"+" target:self action:@selector(addBracketColor:)];
    _addBracket.accessibilityLabel = @"Add Bracket Color";
    [pane addSubview:_addBracket];
    _removeBracket = [NSButton buttonWithTitle:@"−" target:self action:@selector(removeBracketColor:)];
    _removeBracket.frame = NSMakeRect(width - margin - 38, 63, 38, 28);
    _removeBracket.accessibilityLabel = @"Remove Bracket Color";
    [pane addSubview:_removeBracket];

    Label(pane, @"Font", NSMakeRect(previewX, 24, 32, 18), NSTextAlignmentLeft);
    _fontDescription = Label(pane, @"", NSMakeRect(previewX + 40, 24, previewWidth - 153, 18), NSTextAlignmentLeft);
    NSButton *choose = [NSButton buttonWithTitle:@"Choose…" target:NSFontManager.sharedFontManager
                                         action:@selector(orderFrontFontPanel:)];
    choose.frame = NSMakeRect(width - margin - 105, 18, 105, 28);
    [pane addSubview:choose];
}

- (void)buildRendering:(NSView *)pane
{
    CGFloat width = NSWidth(pane.bounds);
    CGFloat height = NSHeight(pane.bounds);
    CGFloat y = height - 43;
    Label(pane, @"Smoothing", NSMakeRect(16, y, 116, 18), NSTextAlignmentRight);
    _smoothing = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(142, y - 4, 250, 26) pullsDown:NO];
    [_smoothing addItemsWithTitles:@[@"Retina LCD", @"Retina Web", @"System"]];
    _smoothing.target = self;
    _smoothing.action = @selector(changeRendering:);
    [_smoothing setAccessibilityLabel:@"Smoothing"];
    [pane addSubview:_smoothing];

    NSButton *reset = [NSButton buttonWithTitle:@"Reset Rendering" target:self action:@selector(resetRendering:)];
    reset.frame = NSMakeRect(width - 147, y - 6, 131, 28);
    [pane addSubview:reset];

    y -= 33;
    Label(pane, @"Render Whitespace", NSMakeRect(4, y, 128, 18), NSTextAlignmentRight);
    _renderWhitespace = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(142, y - 4, 250, 26) pullsDown:NO];
    [_renderWhitespace addItemsWithTitles:@[@"None", @"Boundary", @"Selection", @"Trailing", @"All"]];
    _renderWhitespace.accessibilityLabel = @"Render Whitespace";
    [_renderWhitespace itemAtIndex:NSInteger(WhitespaceMode::Boundary)].toolTip =
        @"Show tabs, indentation, repeated spaces, and trailing whitespace.";
    _renderWhitespace.target = self;
    _renderWhitespace.action = @selector(changeRendering:);
    [pane addSubview:_renderWhitespace];

    _sliders = [NSMutableArray arrayWithCapacity:std::size(renderingSliders)];
    _values = [NSMutableArray arrayWithCapacity:std::size(renderingSliders)];
    y -= 33;
    constexpr RenderSettings defaults{};
    for (const auto &row : renderingSliders) {
        Label(pane, row.label, NSMakeRect(16, y, 116, 18), NSTextAlignmentRight);
        bool brightness = row.factor == &RenderSettings::brightness;
        NSSlider *slider = [NSSlider sliderWithValue:defaults.*row.factor minValue:brightness ? minimumBrightness : 0
                                           maxValue:brightness ? maximumBrightness : 2
                                               target:self action:@selector(changeRendering:)];
        slider.continuous = YES;
        slider.frame = NSMakeRect(144, y - 1, width - 225, 21);
        [slider setAccessibilityLabel:row.label];
        [pane addSubview:slider];
        [_sliders addObject:slider];
        [_values addObject:Label(pane, @"", NSMakeRect(width - 70, y, 54, 18), NSTextAlignmentRight)];
        y -= 28;
    }

    AddPreview(pane, NSMakeRect(16, 16, width - 32, y - 19));
}

- (void)buildEditing:(NSView *)pane
{
    CGFloat y = NSHeight(pane.bounds) - 46;
    _smoothScrolling = [NSButton checkboxWithTitle:@"Smooth scrolling" target:self
                                            action:@selector(toggleSmoothScrolling:)];
    _smoothScrolling.frame = NSMakeRect(20, y, 240, 22);
    _smoothScrolling.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_smoothScrolling];

    _vimMode = [NSButton checkboxWithTitle:@"Vim Mode" target:self action:@selector(toggleVimMode:)];
    _vimMode.frame = NSMakeRect(20, y - 30, 240, 22);
    _vimMode.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_vimMode];

    y -= 77;
    Label(pane, @"Indent Using", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _indentKind = [NSSegmentedControl segmentedControlWithLabels:@[@"Spaces", @"Tabs"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeIndentation:)];
    _indentKind.frame = NSMakeRect(127, y - 3, 130, 24);
    _indentKind.autoresizingMask = NSViewMinYMargin;
    _indentKind.accessibilityLabel = @"Indent Using";
    [pane addSubview:_indentKind];

    y -= 32;
    Label(pane, @"Tab Size", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _tabSize = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(126, y - 3, 83, 24) pullsDown:NO];
    _tabSize.accessibilityLabel = @"Tab Size";
    _tabSize.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_tabSize];

    y -= 32;
    _detectIndentation = [NSButton checkboxWithTitle:@"Detect indentation" target:self action:@selector(changeIndentation:)];
    _detectIndentation.frame = NSMakeRect(128, y, 252, 22);
    _detectIndentation.autoresizingMask = NSViewMinYMargin;
    _detectIndentation.toolTip = @"Detect indentation in files without saved indentation settings.";
    [pane addSubview:_detectIndentation];
}

- (IBAction)changeIndentation:(id)sender
{
    (void)sender;
    auto settings = IndentationPreference();
    settings.tabs = _indentKind.selectedSegment == 1;
    settings.detect = _detectIndentation.state == NSControlStateValueOn;
    SetIndentationPreference(settings);
}

- (IBAction)changeDefaultTabSize:(NSMenuItem *)sender
{
    if (sender.tag < 1 || sender.tag > NSInteger(maximumTabSize))
        return;
    auto settings = IndentationPreference();
    settings.tabSize = NSUInteger(sender.tag);
    SetIndentationPreference(settings);
    [_tabSize selectItemWithTag:sender.tag];
}

- (void)buildFiles:(NSView *)pane
{
    CGFloat y = NSHeight(pane.bounds) - 46;
    Label(pane, @"Auto Save", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _autoSaveMode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(126, y - 3, 188, 24) pullsDown:NO];
    [_autoSaveMode addItemsWithTitles:@[@"Off", @"After Delay", @"On Focus Change", @"On Window Change"]];
    _autoSaveMode.target = self;
    _autoSaveMode.action = @selector(changeAutoSaveMode:);
    _autoSaveMode.autoresizingMask = NSViewMinYMargin;
    _autoSaveMode.accessibilityLabel = @"Auto Save";
    [pane addSubview:_autoSaveMode];

    y -= 34;
    Label(pane, @"Delay", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _autoSaveDelay = [NSTextField textFieldWithString:@""];
    _autoSaveDelay.frame = NSMakeRect(130, y - 2, 88, 22);
    _autoSaveDelay.autoresizingMask = NSViewMinYMargin;
    _autoSaveDelay.accessibilityLabel = @"Auto Save Delay (ms)";
    _autoSaveDelay.toolTip = @"Used by After Delay.";
    _autoSaveDelay.delegate = self;
    [pane addSubview:_autoSaveDelay];
    Label(pane, @"ms", NSMakeRect(225, y, 32, 18), NSTextAlignmentLeft).autoresizingMask = NSViewMinYMargin;

    _autoSaveWorkspaceFilesOnly = [NSButton checkboxWithTitle:@"Only save workspace files"
                                                     target:self action:@selector(changeAutoSaveConditions:)];
    _autoSaveWorkspaceFilesOnly.frame = NSMakeRect(128, y - 34, 274, 22);
    _autoSaveWorkspaceFilesOnly.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_autoSaveWorkspaceFilesOnly];

    _autoSaveWhenNoErrors = [NSButton checkboxWithTitle:@"Only save files without errors"
                                                target:self action:@selector(changeAutoSaveConditions:)];
    _autoSaveWhenNoErrors.frame = NSMakeRect(128, y - 60, 274, 22);
    _autoSaveWhenNoErrors.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_autoSaveWhenNoErrors];

    y -= 78;
    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(20, y, NSWidth(pane.bounds) - 40, 1)];
    divider.boxType = NSBoxSeparator;
    divider.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
    [pane addSubview:divider];

    y -= 32;
    _trimTrailingWhitespace = [NSButton checkboxWithTitle:@"Trim trailing whitespace on save"
                                                    target:self action:@selector(changeTrimTrailingWhitespace:)];
    _trimTrailingWhitespace.frame = NSMakeRect(128, y, 274, 22);
    _trimTrailingWhitespace.autoresizingMask = NSViewMinYMargin;
    [pane addSubview:_trimTrailingWhitespace];

    y -= 30;
    Label(pane, @"Final newline", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _finalNewline = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(126, y - 3, 188, 24) pullsDown:NO];
    [_finalNewline addItemsWithTitles:FinalNewlineModeNames()];
    _finalNewline.target = self;
    _finalNewline.action = @selector(changeFinalNewline:);
    _finalNewline.autoresizingMask = NSViewMinYMargin;
    _finalNewline.accessibilityLabel = @"Final newline";
    _finalNewline.toolTip = @"Set how the file ends when saved.";
    [pane addSubview:_finalNewline];
}

- (void)buildOutput:(NSView *)pane
{
    CGFloat y = NSHeight(pane.bounds) - 46;
    Label(pane, @"Scrollback", NSMakeRect(20, y, 98, 18), NSTextAlignmentRight).autoresizingMask = NSViewMinYMargin;
    _outputScrollback = [NSTextField textFieldWithString:@""];
    _outputScrollback.stringValue = [ScrollbackFormatter() stringFromNumber:@(OutputScrollbackLinesPreference())];
    _outputScrollback.frame = NSMakeRect(130, y - 2, 88, 22);
    _outputScrollback.autoresizingMask = NSViewMinYMargin;
    _outputScrollback.accessibilityLabel = @"Output Scrollback (lines)";
    _outputScrollback.toolTip = [NSString stringWithFormat:@"1–%lld lines.", maximumOutputScrollbackLines];
    _outputScrollback.delegate = self;
    [pane addSubview:_outputScrollback];
    Label(pane, @"lines", NSMakeRect(225, y, 45, 18), NSTextAlignmentLeft).autoresizingMask = NSViewMinYMargin;

    NSButton *clearOnRun = [NSButton checkboxWithTitle:@"Clear on Run" target:self action:@selector(changeClearOutputOnRun:)];
    clearOnRun.frame = NSMakeRect(128, y - 34, 216, 22);
    clearOnRun.autoresizingMask = NSViewMinYMargin;
    clearOnRun.state = ClearOutputOnRunPreference() ? NSControlStateValueOn : NSControlStateValueOff;
    [pane addSubview:clearOnRun];
}

- (IBAction)changeClearOutputOnRun:(NSButton *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:clearOutputOnRunKey];
}

- (IBAction)changeTrimTrailingWhitespace:(NSButton *)sender
{
    auto settings = SaveCleanupPreference();
    settings.trimTrailingWhitespace = sender.state == NSControlStateValueOn;
    SetSaveCleanupPreference(settings);
}

- (IBAction)changeFinalNewline:(NSPopUpButton *)sender
{
    auto settings = SaveCleanupPreference();
    settings.finalNewline = FinalNewlineMode(sender.indexOfSelectedItem);
    SetSaveCleanupPreference(settings);
}

- (void)saveCleanupPreferencesChanged:(NSNotification *)notification
{
    (void)notification;
    auto settings = SaveCleanupPreference();
    _trimTrailingWhitespace.state = settings.trimTrailingWhitespace ? NSControlStateValueOn : NSControlStateValueOff;
    [_finalNewline selectItemAtIndex:NSInteger(settings.finalNewline)];
}

- (void)autoSavePreferencesChanged:(NSNotification *)notification
{
    (void)notification;
    AutoSaveSettings settings = AutoSavePreference();
    [_autoSaveMode selectItemAtIndex:NSInteger(settings.mode)];
    if (!_autoSaveDelay.currentEditor)
        _autoSaveDelay.integerValue = settings.delayMilliseconds;
    _autoSaveWorkspaceFilesOnly.state = settings.workspaceFilesOnly ? NSControlStateValueOn : NSControlStateValueOff;
    _autoSaveWhenNoErrors.state = settings.whenNoErrors ? NSControlStateValueOn : NSControlStateValueOff;
}

- (IBAction)changeAutoSaveMode:(NSPopUpButton *)sender
{
    AutoSaveSettings settings = AutoSavePreference();
    settings.mode = AutoSaveMode(sender.indexOfSelectedItem);
    SetAutoSavePreference(settings);
}

- (IBAction)changeAutoSaveConditions:(NSButton *)sender
{
    (void)sender;
    AutoSaveSettings settings = AutoSavePreference();
    settings.workspaceFilesOnly = _autoSaveWorkspaceFilesOnly.state == NSControlStateValueOn;
    settings.whenNoErrors = _autoSaveWhenNoErrors.state == NSControlStateValueOn;
    SetAutoSavePreference(settings);
}

- (void)tabView:(NSTabView *)tabs didSelectTabViewItem:(NSTabViewItem *)item
{
    (void)tabs;
    NSWindow *window = self.window;
    CGFloat height = [item.identifier isEqual:@"Editing"] ? editingHeight : preferencesHeight;
    if ([item.identifier isEqual:@"Files"])
        height = filesHeight;
    else if ([item.identifier isEqual:@"Output"])
        height = outputHeight;
    CGFloat delta = height - NSHeight(window.contentView.bounds);
    if (delta) {
        NSRect frame = window.frame;
        frame.origin.y -= delta;
        frame.size.height += delta;
        [window setFrame:frame display:window.isVisible];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return NSInteger(_themeRows.size());
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
    (void)tableView;
    return _themeRows[row] < 0;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    (void)tableView;
    return _themeRows[row] >= 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSInteger index = _themeRows[row];
    bool heading = index < 0;
    NSString *identifier = heading ? @"ThemeHeading" : @"ThemeName";
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:nil];
    if (!cell) {
        CGFloat width = column ? column.width : NSWidth(tableView.bounds);
        CGFloat inset = heading ? 8 : 17;
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, tableView.rowHeight)];
        cell.identifier = identifier;
        cell.textField = Label(cell, @"", NSMakeRect(inset, 1, width - inset - 5, 17), NSTextAlignmentLeft);
        cell.textField.autoresizingMask = NSViewWidthSizable;
        cell.textField.font = heading ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:12];
        if (heading)
            cell.textField.textColor = NSColor.secondaryLabelColor;
    }
    cell.textField.stringValue = ThemeRowTitle(index);
    cell.toolTip = heading ? nil : cell.textField.stringValue;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    NSInteger row = _themes.selectedRow;
    if (!_refreshingThemes && row >= 0 && row < NSInteger(_themeRows.size()) &&
        _themeRows[row] >= 0 && _themeRows[row] != ThemePreference())
        SelectEditorTheme(_themeRows[row]);
}

- (NSMenu *)menuForThemeRow:(NSInteger)row
{
    if (row < 0 || row >= NSInteger(_themeRows.size()) || !IsCustomTheme(_themeRows[row]))
        return nil;
    NSInteger index = _themeRows[row];
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *remove = [menu addItemWithTitle:@"Remove" action:@selector(removeTheme:) keyEquivalent:@""];
    remove.target = self;
    remove.representedObject = CustomThemes()[index - builtinThemeCount]->identifier;
    return menu;
}

- (IBAction)removeTheme:(NSMenuItem *)sender
{
    NSInteger index = CustomThemeIndex(sender.representedObject);
    if (index < 0 || _themeEditor)
        return;
    BOOL selected = ThemePreference() == index;
    NSInteger replacement = 0;
    if (selected) {
        // Prefer the preceding scheme in the same section.
        auto row = std::find(_themeRows.begin(), _themeRows.end(), index);
        if (row != _themeRows.end()) {
            if (row[-1] >= 0)
                replacement = row[-1];
            else if (row + 1 != _themeRows.end() && row[1] >= 0)
                replacement = row[1];
        }
    }
    auto &records = CustomThemes();
    records.erase(records.begin() + (index - builtinThemeCount));
    ++themeListRevision;
    SaveCustomThemes();
    if (selected)
        SelectEditorTheme(replacement > index ? replacement - 1 : replacement);
    else
        PublishPreferences();
}

- (void)preferencesChanged:(NSNotification *)notification
{
    (void)notification;
    _refreshingThemes = YES;
    if (_themeRevision != themeListRevision) {
        _themeRows = ThemeRows();
        _themeRevision = themeListRevision;
        [_themes reloadData];
    }
    auto selected = std::find(_themeRows.begin(), _themeRows.end(), ThemePreference()) - _themeRows.begin();
    if (_themes.selectedRow != selected) {
        [_themes selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        [_themes scrollRowToVisible:selected];
    }
    _refreshingThemes = NO;
    _colorizeBrackets.state = BracketColorizationPreference() ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshBracketColors];
    _smoothScrolling.state = SmoothScrollingPreference() ? NSControlStateValueOn : NSControlStateValueOff;
    _vimMode.state = [NSUserDefaults.standardUserDefaults boolForKey:vimModeKey] ?
                     NSControlStateValueOn : NSControlStateValueOff;
    IndentationSettings indentation = IndentationPreference();
    _indentKind.selectedSegment = indentation.tabs ? 1 : 0;
    if (_displayedTabSize != indentation.tabSize) {
        _tabSize.menu = TabSizeMenu(indentation.tabSize, self, @selector(changeDefaultTabSize:));
        [_tabSize selectItemWithTag:NSInteger(indentation.tabSize)];
        _displayedTabSize = indentation.tabSize;
    }
    _detectIndentation.state = indentation.detect ? NSControlStateValueOn : NSControlStateValueOff;
    NSFont *font = EditorFontPreference();
    _fontDescription.stringValue = [NSString stringWithFormat:@"%@, %g pt", font.displayName, font.pointSize];

    RenderSettings settings = RenderingPreference();
    auto smoothing = std::find(std::begin(smoothingChoices), std::end(smoothingChoices), settings.smoothing);
    [_smoothing selectItemAtIndex:smoothing - std::begin(smoothingChoices)];
    [_renderWhitespace selectItemAtIndex:NSInteger(settings.whitespace)];
    for (NSUInteger i = 0; i < std::size(renderingSliders); ++i) {
        CGFloat factor = settings.*renderingSliders[i].factor;
        _sliders[i].doubleValue = factor;
        _sliders[i].enabled = i < 2 || (i == 2 && settings.smoothing != Smoothing::System) ||
                              settings.smoothing == Smoothing::RetinaLCD;
        _values[i].stringValue = [NSString stringWithFormat:@"%.0f%%", 100 * factor];
        _values[i].textColor = _sliders[i].enabled ? NSColor.labelColor : NSColor.disabledControlTextColor;
    }
}

- (void)refreshBracketColors
{
    constexpr CGFloat pitch = 33;
    NSInteger index = ThemePreference();
    auto theme = ThemeAt(index);
    auto colors = theme->bracketColors;
    if (index != _bracketTheme || colors.size() != _bracketWells.count) {
        BOOL changedTheme = index != _bracketTheme;
        _bracketTheme = index;
        for (NSColorWell *well in _bracketWells) {
            [well deactivate];
            [well removeFromSuperview];
        }
        [_bracketWells removeAllObjects];
        [_bracketStrip setFrameSize:NSMakeSize(std::max(NSWidth(_bracketScroll.bounds), pitch * colors.size()), 39)];
        for (size_t i = 0; i < colors.size(); ++i) {
            NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(pitch * i + 1, 15, 29, 22)];
            well.tag = NSInteger(i);
            well.target = self;
            well.action = @selector(changeBracketColor:);
            // Color-panel changes must send an action to update the theme.
            well.continuous = YES;
            well.accessibilityLabel = [NSString stringWithFormat:@"Bracket Level %lu", (unsigned long)i + 1];
            [_bracketStrip addSubview:well];
            [_bracketWells addObject:well];
        }
        if (changedTheme) {
            [_bracketScroll.contentView scrollToPoint:NSZeroPoint];
            [_bracketScroll reflectScrolledClipView:_bracketScroll.contentView];
        }
    }
    for (size_t i = 0; i < colors.size(); ++i)
        _bracketWells[i].color = SRGBColor(colors[i]);
    _bracketScroll.hidden = colors.empty();
    _removeBracket.hidden = colors.empty();
    CGFloat left = colors.empty() ? _bracketX : NSMaxX(_bracketScroll.frame) + 4;
    _addBracket.frame = NSMakeRect(left, 63, 38, 28);
}

- (void)chooseBracketColor:(NSUInteger)level
{
    if (level >= _bracketWells.count)
        return;
    NSColorWell *well = _bracketWells[level];
    [_bracketStrip scrollRectToVisible:well.frame];
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.showsAlpha = NO;
    [well activate:YES];
    [panel orderFront:nil];
}

- (IBAction)toggleBrackets:(NSButton *)sender
{
    SetEditorPreference(bracketColorizationKey, @(sender.state == NSControlStateValueOn));
}

- (IBAction)addBracketColor:(id)sender
{
    (void)sender;
    NSInteger index = ThemePreference();
    auto theme = ThemeAt(index);
    auto colors = CopyBrackets(*theme);
    constexpr Col32 light[] = {
        rgb(22, 90, 148), rgb(119, 56, 147), rgb(138, 97, 0),
        rgb(23, 106, 74), rgb(161, 45, 70), rgb(0, 105, 120),
    };
    constexpr Col32 dark[] = {
        rgb(135, 206, 250), rgb(218, 112, 214), rgb(255, 215, 0),
        rgb(157, 211, 132), rgb(255, 165, 140), rgb(127, 213, 203),
    };
    auto level = colors.size();
    colors.push_back((theme->dark ? dark : light)[level % std::size(light)]);
    SetBracketPalette(index, std::move(colors));
    [self chooseBracketColor:level];
}

- (IBAction)changeBracketColor:(NSColorWell *)sender
{
    NSInteger index = ThemePreference();
    auto theme = ThemeAt(index);
    auto color = RGBValue(sender.color);
    if (!color || index != _bracketTheme || sender.tag < 0 || size_t(sender.tag) >= theme->bracketColors.size() ||
        theme->bracketColors[sender.tag] == *color)
        return;
    NSUInteger level = sender.tag;
    bool keepActive = sender.isActive && !IsCustomTheme(index);
    auto colors = CopyBrackets(*theme);
    colors[level] = *color;
    SetBracketPalette(index, std::move(colors));
    if (keepActive)
        [self chooseBracketColor:level];
}

- (IBAction)removeBracketColor:(id)sender
{
    (void)sender;
    NSInteger index = ThemePreference();
    auto colors = CopyBrackets(*ThemeAt(index));
    if (colors.empty())
        return;
    size_t level = colors.size() - 1;
    for (NSColorWell *well in _bracketWells) {
        if (well.isActive) {
            level = size_t(well.tag);
            break;
        }
    }
    colors.erase(colors.begin() + level);
    SetBracketPalette(index, std::move(colors));
}

- (IBAction)duplicateTheme:(id)sender
{
    (void)sender;
    NSInteger index = ThemePreference();
    DuplicateTheme(index, CopyBrackets(*ThemeAt(index)));
}

- (IBAction)editTheme:(id)sender
{
    (void)sender;
    if (_themeEditor)
        return;
    NSInteger index = ThemePreference();
    _editingTheme = IsCustomTheme(index) ? index : DuplicateTheme(index, CopyBrackets(*ThemeAt(index)));
    auto theme = ThemeAt(_editingTheme);
    const CGFloat width = 398, height = 428;
    _themeEditor = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    _themeEditor.title = @"Edit Theme";
    NSView *body = [[PreferencesContent alloc] initWithFrame:_themeEditor.contentView.bounds];
    _themeEditor.contentView = body;
    Label(body, @"Name", NSMakeRect(20, height - 34, 62, 18), NSTextAlignmentLeft);
    _themeName = [[NSTextField alloc] initWithFrame:NSMakeRect(83, height - 37, width - 103, 24)];
    _themeName.delegate = self;
    _themeName.stringValue = ThemeRowTitle(_editingTheme);
    _themeName.accessibilityLabel = @"Theme Name";
    [body addSubview:_themeName];

    Label(body, @"Style", NSMakeRect(20, height - 68, 62, 18), NSTextAlignmentLeft);
    _themeStyle = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(80, height - 74, 111, 27) pullsDown:NO];
    [_themeStyle addItemsWithTitles:@[@"Light", @"Dark"]];
    [_themeStyle selectItemAtIndex:theme->dark ? 1 : 0];
    _themeStyle.target = self;
    _themeStyle.action = @selector(changeThemeStyle:);
    _themeStyle.accessibilityLabel = @"Theme Style";
    [body addSubview:_themeStyle];
    _italicTypes = [NSButton checkboxWithTitle:@"Italic types" target:self action:@selector(changeThemeStyle:)];
    _italicTypes.state = theme->italicTypes ? NSControlStateValueOn : NSControlStateValueOff;
    _italicTypes.frame = NSMakeRect(220, height - 69, 143, 20);
    [body addSubview:_italicTypes];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 54, width - 40, height - 138)];
    scroll.borderType = NSBezelBorder;
    scroll.scrollerStyle = NSScrollerStyleLegacy;
    scroll.hasVerticalScroller = YES;
    auto fields = ColorFields(*theme);
    CGFloat formWidth = scroll.contentSize.width;
    CGFloat formHeight = 24 * (fields.size() + 3) + 14;
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, formWidth, formHeight)];
    _themeWells = [NSMutableArray arrayWithCapacity:fields.size()];
    CGFloat y = formHeight - 28;
    for (size_t i = 0; i < fields.size(); ++i) {
        if (i == 0 || i == 9 || i == 21) {
            NSString *title = i == 0 ? @"Editor" : i == 9 ? @"Syntax" : @"Highlights";
            NSTextField *section = Label(form, title, NSMakeRect(11, y + 2, 150, 18), NSTextAlignmentLeft);
            section.font = [NSFont boldSystemFontOfSize:12];
            y -= 24;
        }
        Label(form, colorTitles[i], NSMakeRect(22, y + 1, formWidth - 105, 18), NSTextAlignmentLeft);
        NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(formWidth - 68, y, 54, 21)];
        auto color = EditableThemeColor(*theme, fields[i]);
        well.color = SRGBColor(color.value_or(theme->ink[size_t(Ink::Text)]));
        well.continuous = YES;
        well.tag = NSInteger(i);
        well.target = self;
        well.action = @selector(changeThemeColor:);
        well.accessibilityLabel = colorTitles[i];
        [_themeWells addObject:well];
        [form addSubview:well];
        y -= 24;
    }
    scroll.documentView = form;
    [body addSubview:scroll];
    [scroll.contentView scrollToPoint:NSMakePoint(0, formHeight - scroll.contentSize.height)];
    [scroll reflectScrolledClipView:scroll.contentView];
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(finishThemeEditor:)];
    done.frame = NSMakeRect(width - 105, 14, 89, 29);
    done.keyEquivalent = @"\r";
    [body addSubview:done];
    NSColorPanel.sharedColorPanel.showsAlpha = NO;
    _themeEditor.initialFirstResponder = _themeName;
    [self.window beginSheet:_themeEditor completionHandler:nil];
}

- (void)renameEditedTheme
{
    if (!IsCustomTheme(_editingTheme))
        return;
    NSString *name = [_themeName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *old = ThemeRowTitle(_editingTheme);
    NSString *title = name.length ? UniqueThemeName(name, _editingTheme) : old;
    if (![title isEqualToString:old]) {
        auto theme = ThemeAt(_editingTheme);
        UpdateCustomTheme(_editingTheme, title, *theme, CopyBrackets(*theme));
    }
    _themeName.stringValue = title;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
    if (notification.object == _themeName)
        [self renameEditedTheme];
    if (notification.object == _autoSaveDelay) {
        AutoSaveSettings settings = AutoSavePreference();
        NSScanner *scanner = [NSScanner scannerWithString:_autoSaveDelay.stringValue];
        long long delay = 0;
        if ([scanner scanLongLong:&delay] && scanner.isAtEnd && delay >= 0)
            settings.delayMilliseconds = delay;
        else
            NSBeep();
        _autoSaveDelay.integerValue = settings.delayMilliseconds;
        SetAutoSavePreference(settings);
    }
    if (notification.object == _outputScrollback) {
        NSNumberFormatter *formatter = ScrollbackFormatter();
        NSString *value = [_outputScrollback.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange parsed = NSMakeRange(0, value.length);
        id number = nil;
        if ([formatter getObjectValue:&number forString:value range:&parsed error:nil] && parsed.length == value.length &&
            [number isKindOfClass:NSNumber.class] && std::isfinite([number doubleValue]))
            SetOutputScrollbackLinesPreference([number doubleValue]);
        _outputScrollback.stringValue = [formatter stringFromNumber:@(OutputScrollbackLinesPreference())];
    }
}

- (void)finishScrollbackEditing:(NSNotification *)notification
{
    (void)notification;
    if (_outputScrollback.currentEditor)
        [self.window makeFirstResponder:nil];
}

- (IBAction)changeThemeStyle:(id)sender
{
    (void)sender;
    auto source = ThemeAt(_editingTheme);
    Theme theme = *source;
    theme.dark = _themeStyle.indexOfSelectedItem == 1;
    theme.italicTypes = _italicTypes.state == NSControlStateValueOn;
    UpdateCustomTheme(_editingTheme, ThemeRowTitle(_editingTheme), theme, CopyBrackets(*source));
}

- (IBAction)changeThemeColor:(NSColorWell *)sender
{
    auto color = RGBValue(sender.color);
    if (!color || !IsCustomTheme(_editingTheme))
        return;
    auto source = ThemeAt(_editingTheme);
    Theme theme = *source;
    auto fields = ColorFields(theme);
    if (sender.tag < 0 || size_t(sender.tag) >= fields.size())
        return;
    Col32 *field = fields[sender.tag];
    if (EditableThemeColor(theme, field) == color)
        return;
    if (field)
        *field = *color;
    else
        theme.caret = color;
    UpdateCustomTheme(_editingTheme, ThemeRowTitle(_editingTheme), theme, CopyBrackets(*source));
}

- (IBAction)finishThemeEditor:(id)sender
{
    (void)sender;
    [_themeEditor makeFirstResponder:nil];
    [self renameEditedTheme];
    for (NSColorWell *well in _themeWells)
        [well deactivate];
    [self.window endSheet:_themeEditor];
    _themeEditor = nil;
    _themeName = nil;
    _themeStyle = nil;
    _italicTypes = nil;
    _themeWells = nil;
    _editingTheme = -1;
}

- (IBAction)toggleSmoothScrolling:(NSButton *)sender
{
    SetEditorPreference(smoothScrollingKey, @(sender.state == NSControlStateValueOn));
}

- (IBAction)changeWindowAppearance:(NSSegmentedControl *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:sender.selectedSegment == 1 forKey:darkWindowAppearanceKey];
    ApplyWindowAppearancePreference();
}

- (IBAction)toggleVimMode:(NSButton *)sender
{
    SetEditorPreference(vimModeKey, @(sender.state == NSControlStateValueOn));
}

- (IBAction)changeRendering:(id)sender
{
    (void)sender;
    RenderSettings settings{.smoothing = smoothingChoices[_smoothing.indexOfSelectedItem],
                            .whitespace = WhitespaceMode(_renderWhitespace.indexOfSelectedItem)};
    for (NSUInteger i = 0; i < std::size(renderingSliders); ++i)
        settings.*renderingSliders[i].factor = _sliders[i].doubleValue;
    SetRenderingPreference(settings);
}

- (IBAction)resetRendering:(id)sender
{
    (void)sender;
    SetRenderingPreference({});
}

- (void)showPane:(NSString *)identifier
{
    [self showWindow:nil];
    [_preferenceTabs selectTabViewItemWithIdentifier:identifier];
    [self.window makeFirstResponder:_preferenceTabs.selectedTabViewItem.initialFirstResponder];
}

@end