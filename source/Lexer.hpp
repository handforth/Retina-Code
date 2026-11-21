#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

// Values are saved in the editor session. Append new modes above Count.
enum class Language {
    Plain, C, Cpp, Python, Rust, JavaScript, TypeScript, JSX, TSX, ObjectiveC, ObjectiveCpp,
    CSharp, Java, Kotlin, Swift, Go, Zig, Dart, Ruby, PHP, Perl, Lua, Luau, Bash, Zsh, Fish,
    PowerShell, R, Julia, Scala, Groovy, Haskell, FSharp, Elixir, Clojure, VisualBasic, SQL,
    HTML, XML, CSS, SCSS, Less, JSON, JSONC, YAML, TOML, INI, Markdown, Makefile, CMake,
    Dockerfile, Assembly, Odin, GML, CommonLisp, Count,
};

struct CommentSyntax {
    std::u16string_view line, open, close;
    bool nested = false;
};

struct LanguageInfo {
    const char *name;
    std::string_view extensions;
    CommentSyntax comments;
    std::u16string_view keywords = {}, control = {}, types = {}, constants = {};
    bool ignoreCase = false;
};

const LanguageInfo &InfoForLanguage(Language language);
Language DetectLanguage(std::string_view path, std::string_view beginning = {});
Language LanguageForFence(std::u16string_view name);

constexpr bool CFamily(Language language)
{
    return language == Language::C || language == Language::Cpp ||
           language == Language::ObjectiveC || language == Language::ObjectiveCpp;
}

constexpr bool JavaScriptFamily(Language language)
{
    return language == Language::JavaScript || language == Language::TypeScript ||
           language == Language::JSX || language == Language::TSX;
}

enum class Ink {
    Text, Keyword, Control, Type, Function, Name, String, Number, Comment, Directive, Constant,
    Escape, Count,
};

struct Token {
    size_t start;
    size_t length;
    Ink ink;
    bool nonCode = false;
};

enum class LexMode {
    Code, BlockComment, Quoted, Raw, LineComment, MarkupText, MarkupTag, MarkupString, BlockScalar,
};

enum class NameRole { None, Function, Type, RustItem, TypeParameter, ValueParameter };
enum class AngleRole { None, Arguments, Parameters };

struct GenericParameter {
    std::u16string name;
    unsigned braceDepth;
    Ink ink;

    bool operator==(const GenericParameter &) const = default;
};

struct NameContext {
    std::vector<GenericParameter> parameters;
    unsigned braceDepth = 0;
    unsigned angles = 0;
    unsigned argumentGroups = 0;
    unsigned groups = 0;
    NameRole nextName = NameRole::None;
    AngleRole nextAngle = AngleRole::None;
    bool parameterList = false;
    bool parameterStart = false;
    bool rustHeader = false;
    bool rustImport = false;
    bool typeAlias = false;
    bool qualified = false;
    bool standardPath = false;

    bool operator==(const NameContext &) const = default;
};

enum class RustAttributePart : unsigned char { Arguments, Name, DiagnosticName, Conditional, Unsafe };

struct RustAttribute {
    std::vector<unsigned> conditionalGroups;
    unsigned brackets = 0;
    unsigned groups = 0;
    RustAttributePart part = RustAttributePart::Arguments;

    bool operator==(const RustAttribute &) const = default;
};

enum class Interpolation { None, Dollar, Hash, Braces, Swift };

struct InterpolatedString {
    std::u16string closing;
    LexMode mode;
    Interpolation kind;
    Ink ink;
    unsigned depth = 1;
    unsigned stringNesting = 0;
    char16_t stringOpening = 0;
    bool multiline = false;
    bool highlightEscapes = true;
    bool doubledQuote = false;

    bool operator==(const InterpolatedString &) const = default;
};

enum class TagPart { Name, Attribute, Value };
enum class RawElement { None, Script, Style };

struct MarkupExpression {
    LexMode mode;
    TagPart part;
    bool endTag;
    size_t stringDepth;
    unsigned braces = 1;

    bool operator==(const MarkupExpression &) const = default;
};

struct MarkupState {
    std::vector<unsigned> roots;
    std::vector<MarkupExpression> expressions;
    unsigned depth = 0;
    TagPart part = TagPart::Name;
    bool endTag = false;
    bool valueIsLanguage = false;
    Language elementLanguage = Language::Plain;
    RawElement rawElement = RawElement::None;
    bool rawContent = false;

    bool operator==(const MarkupState &) const = default;
};

struct HereDocument {
    std::u16string end;
    bool indent = false;
    bool expand = false;

    bool operator==(const HereDocument &) const = default;
};

struct LexState {
    LexMode mode = LexMode::Code;
    unsigned depth = 0;
    std::u16string closing;
    bool multiline = false;
    bool highlightEscapes = true;
    bool doubledQuote = false;
    Ink stringInk = Ink::String;
    char16_t stringOpening = 0;
    Interpolation interpolation = Interpolation::None;
    std::vector<InterpolatedString> interpolations;
    std::vector<HereDocument> hereDocuments;
    MarkupState markup;
    Language embedded = Language::Plain;
    Language fenceLanguage = Language::Plain;
    char16_t fence = 0;
    unsigned fenceLength = 0;
    bool expectsValue = true;
    bool lispListHead = false;
    NameContext names;
    RustAttribute attribute;

    bool operator==(const LexState &) const = default;
};

inline Language LanguageInContext(Language document, const LexState &state)
{
    if (state.embedded != Language::Plain)
        return state.embedded;
    if (state.fence)
        return state.fenceLanguage;
    return document;
}

constexpr bool IsASCIIIdentifierStart(char16_t character)
{
    return (character >= u'A' && character <= u'Z') ||
           (character >= u'a' && character <= u'z') || character == u'_' || character == u'$';
}

constexpr bool IsASCIIIdentifierPart(char16_t character)
{
    return IsASCIIIdentifierStart(character) || (character >= u'0' && character <= u'9');
}

constexpr bool IsLispSymbolPart(char16_t character)
{
    switch (character) {
        case u'(': case u')': case u'"': case u'\'': case u'`': case u',': case u';': case u'|': case u'\\':
            return false;
        default:
            return character > u' ' && character != 0x7f;
    }
}

const std::vector<std::u16string_view> &CompletionWords(Language language);
void TokenizeLine(std::u16string_view line, Language language, LexState &state,
                  std::vector<Token> &tokens, bool finishLine = true);