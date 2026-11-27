#pragma once

// The syntax lexer shared by both frontends. It colors one line at a time: tokenize_line() reads a line and the
// state left behind by the line before it, writes the line's colored spans, and leaves the state for the next line.
//
// The state is one plain fixed-size struct with no pointers, so editors can copy it, compare it byte for byte,
// and keep one per line without ever touching the heap.

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string_view>
#include <type_traits>
#include <vector>

// Values are saved in editor sessions. Append new languages just above Count.
enum class Language : uint8_t {
    Plain, C, Cpp, Python, Rust, JavaScript, TypeScript, JSX, TSX, ObjectiveC, ObjectiveCpp,
    CSharp, Java, Kotlin, Swift, Go, Zig, Dart, Ruby, PHP, Perl, Lua, Luau, Bash, Zsh, Fish,
    PowerShell, R, Julia, Scala, Groovy, Haskell, FSharp, Elixir, Clojure, VisualBasic, SQL,
    HTML, XML, CSS, SCSS, Less, JSON, JSONC, YAML, TOML, INI, Markdown, Makefile, CMake,
    Dockerfile, Assembly, Odin, GML, CommonLisp, Count,
};

// Table entries leave out the trailing fields they don't need, so every field has a default.
struct CommentSyntax {
    std::u16string_view line = {}, open = {}, close = {};
    bool nested = false;    // block comments nest, as in Rust and Haskell
};

struct LanguageInfo {
    const char *name = nullptr;
    std::string_view extensions = {};    // lowercase, separated by spaces
    CommentSyntax comments = {};
    std::u16string_view keywords = {}, control = {}, types = {}, constants = {};    // words separated by spaces
    bool ignore_case = false;            // keywords match in any letter case
};

// The color class of a token. Themes keep one color per value.
enum class Ink : uint8_t {
    Text, Keyword, Control, Type, Function, Name, String, Number, Comment, Directive, Constant, Escape, Count,
};

// One colored span of a line. A span longer than 65535 units is split into several tokens.
struct Token {
    uint32_t start;    // offset from the start of the line, in UTF-16 units
    uint16_t length;
    Ink ink;
    bool non_code;     // part of a string, comment, or markup text, where brackets don't pair with code
};

//
// Lexer state carried from one line to the next.
//

enum class LexMode : uint8_t {
    Code, BlockComment, Quoted, Raw, LineComment, MarkupText, MarkupTag, MarkupString, BlockScalar,
};

// How the open string marks an embedded expression: ${x}, #{x}, {x}, or Swift's \(x).
enum class Interpolation : uint8_t { None, Dollar, Hash, Braces, Swift };

// What the next name in C++, Rust, and similar code declares.
enum class NameRole : uint8_t { None, Function, Type, RustItem, TypeParameter, ValueParameter };

// What the next < opens: template arguments or a list of generic parameters.
enum class AngleRole : uint8_t { None, Arguments, Parameters };

enum class RustAttributePart : uint8_t { Arguments, Name, DiagnosticName, Conditional, Unsafe };
enum class TagPart : uint8_t { Name, Attribute, Value };
enum class RawElement : uint8_t { None, Script, Style };

// Fixed limits. Input nested deeper than these keeps its colors up to the limit, and the extra level is not
// treated as a new string, here-document, or JSX element.
constexpr int LEX_CLOSING_TEXT_LIMIT = 20;
constexpr int LEX_INTERPOLATION_LIMIT = 4;
constexpr int LEX_HEREDOC_LIMIT = 4;
constexpr int LEX_HEREDOC_TEXT_LIMIT = 32;
constexpr int LEX_JSX_NESTING_LIMIT = 8;
constexpr int LEX_GENERIC_LIMIT = 16;
constexpr int LEX_CFG_GROUP_LIMIT = 4;

// The text that ends the open string or comment, such as " or """ or -->. A delimiter longer than the text
// buffer keeps its longest run of one repeated character as a count instead: CMake's ]=====] or Rust's "####.
struct LexClosing {
    char16_t text[LEX_CLOSING_TEXT_LIMIT] = {};
    char16_t run_unit = 0;    // the repeated character, when run_length isn't zero
    uint16_t run_length = 0;
    uint8_t length = 0;       // units used in text
    uint8_t run_at = 0;       // where the run goes in text
};

// A string waiting for its embedded expression to end, as in "a ${b} c".
struct LexInterpolation {
    LexClosing closing = {};
    char16_t string_opening = 0;
    uint16_t braces = 0;            // open { or ( inside the expression
    uint16_t string_nesting = 0;
    LexMode mode = LexMode::Code;
    Interpolation kind = Interpolation::None;
    Ink ink = Ink::Text;
    bool multiline = false;
    bool highlight_escapes = false;
    bool doubled_quote = false;
};

// A here-document waiting for its terminator line. The terminator text lives in LexState::heredoc_text.
struct LexHeredoc {
    uint8_t length = 0;
    bool indent = false;    // the terminator may be indented
    bool expand = false;    // $variables expand in the body
};

// A generic or template parameter in scope. Names match by length and a 32-bit hash.
struct LexGeneric {
    uint32_t name_hash = 0;
    uint16_t brace_depth = 0;
    uint8_t name_length = 0;
    Ink ink = Ink::Text;
};

// Context for coloring names by what they declare in C++, Rust, and similar languages.
struct LexNames {
    LexGeneric generics[LEX_GENERIC_LIMIT] = {};
    uint16_t brace_depth = 0;
    uint16_t angles = 0;             // open < of a generic list
    uint16_t argument_groups = 0;    // open brackets inside a generic list
    uint16_t groups = 0;             // open ( or [ in a declaration
    uint8_t generic_count = 0;
    NameRole next_name = NameRole::None;
    AngleRole next_angle = AngleRole::None;
    bool parameter_list = false;     // the open generic list declares parameters
    bool parameter_start = false;    // the next word starts a generic parameter
    bool rust_header = false;        // inside a Rust item header such as fn ...( or impl ... {
    bool rust_import = false;        // inside a Rust use declaration
    bool type_alias = false;         // after using, type, or namespace, before =
    bool qualified = false;          // the previous name was followed by ::
    bool standard_path = false;      // the qualifier so far starts with std::
    uint8_t unused[2] = {};
};

// An embedded { expression } inside JSX.
struct LexJSXExpression {
    uint16_t braces = 0;
    uint8_t interpolation_count = 0;    // string interpolations open when the expression started
    LexMode mode = LexMode::Code;
    TagPart part = TagPart::Name;
    bool end_tag = false;
};

struct LexMarkup {
    LexJSXExpression expressions[LEX_JSX_NESTING_LIMIT] = {};
    uint16_t roots[LEX_JSX_NESTING_LIMIT] = {};    // element depth where each JSX tree inside code began
    uint16_t depth = 0;                              // open JSX elements
    uint8_t root_count = 0;
    uint8_t expression_count = 0;
    TagPart part = TagPart::Name;
    bool end_tag = false;
    bool value_is_language = false;    // the attribute being read is type= or lang=
    Language element_language = Language::Plain;
    RawElement raw_element = RawElement::None;
    bool raw_content = false;          // inside the body of <script> or <style>
};

struct LexRustAttribute {
    uint16_t conditional_groups[LEX_CFG_GROUP_LIMIT] = {};    // group depths of open cfg_attr(...) arguments
    uint16_t brackets = 0;
    uint16_t groups = 0;
    uint8_t conditional_count = 0;
    RustAttributePart part = RustAttributePart::Arguments;
};

struct LexState {
    LexNames names = {};
    uint32_t depth = 0;                 // comment or bracket nesting, or the indentation of a YAML block
    LexClosing closing = {};
    LexInterpolation interpolations[LEX_INTERPOLATION_LIMIT] = {};
    LexMarkup markup = {};
    LexRustAttribute attribute = {};
    char16_t heredoc_text[LEX_HEREDOC_TEXT_LIMIT] = {};
    char16_t string_opening = 0;        // the opening bracket of a %q(...) string, which nests
    char16_t fence = 0;                 // ` or ~ inside a Markdown code fence
    uint16_t fence_length = 0;
    LexHeredoc heredocs[LEX_HEREDOC_LIMIT] = {};
    LexMode mode = LexMode::Code;
    Interpolation interpolation = Interpolation::None;    // how the open string interpolates
    Ink string_ink = Ink::String;
    bool multiline = false;             // the open string continues onto the next line
    bool highlight_escapes = true;
    bool doubled_quote = false;         // a doubled quote stays inside the string, as in SQL's 'it''s'
    bool expects_value = true;          // a / here starts a regular expression
    bool lisp_list_head = false;        // the next Lisp symbol is the first one in its list
    Language embedded = Language::Plain;          // the language inside <script> or <style>
    Language fence_language = Language::Plain;
    uint8_t interpolation_count = 0;
    uint8_t heredoc_count = 0;
    uint8_t heredoc_text_used = 0;
    uint8_t unused[3] = {};
};

// Equal states must be equal byte for byte, so the structs above have no hidden padding.
static_assert(std::has_unique_object_representations_v<LexState>);

inline bool lex_states_equal(const LexState &a, const LexState &b)
{
    return memcmp(&a, &b, sizeof(LexState)) == 0;
}

// True when the closing delimiter is exactly this text.
inline bool lex_closing_is(const LexClosing &closing, std::u16string_view text)
{
    return closing.run_length == 0 && text == std::u16string_view(closing.text, closing.length);
}

// The language at the end of a line: a <script> or <style> body, a Markdown code fence, or the document's own.
inline Language language_in_context(Language document, const LexState &state)
{
    if (state.embedded != Language::Plain)
        return state.embedded;

    if (state.fence)
        return state.fence_language;

    return document;
}

constexpr bool is_c_family(Language language)
{
    return language == Language::C || language == Language::Cpp ||
           language == Language::ObjectiveC || language == Language::ObjectiveCpp;
}

constexpr bool is_javascript_family(Language language)
{
    return language == Language::JavaScript || language == Language::TypeScript ||
           language == Language::JSX || language == Language::TSX;
}

constexpr bool is_ascii_identifier_start(char16_t character)
{
    return (character >= u'A' && character <= u'Z') || (character >= u'a' && character <= u'z') ||
           character == u'_' || character == u'$';
}

constexpr bool is_ascii_identifier_char(char16_t character)
{
    return is_ascii_identifier_start(character) || (character >= u'0' && character <= u'9');
}

constexpr bool is_lisp_symbol_char(char16_t character)
{
    switch (character) {
        case u'(': case u')': case u'"': case u'\'': case u'`': case u',': case u';': case u'|': case u'\\':
            return false;
        default:
            return character > u' ' && character != 0x7f;
    }
}

const LanguageInfo &language_info(Language language);

// Picks a language from a path with forward slashes and, for files without a known extension, the first bytes.
Language detect_language(std::string_view path, std::string_view beginning = {});

// The language named by a Markdown code fence, such as ```rust.
Language language_for_fence(std::u16string_view name);

// Keywords and built-in names for completion, sorted.
const std::vector<std::u16string_view> &completion_words(Language language);

// Colors one line. finish_line is false when the text stops partway through a line, as when typing needs the
// context at the caret: a string or comment then stays open instead of ending with the line.
void tokenize_line(std::u16string_view line, Language language, LexState &state, std::vector<Token> &tokens,
                   bool finish_line = true);
