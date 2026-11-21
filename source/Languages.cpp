#include "Lexer.hpp"

#include <array>

using Text = std::u16string_view;
using Path = std::string_view;

static constexpr CommentSyntax slash{u"//", u"/*", u"*/"};
static constexpr CommentSyntax nestedSlash{u"//", u"/*", u"*/", true};
static constexpr CommentSyntax hash{u"#", {}, {}};
static constexpr CommentSyntax markup{{}, u"<!--", u"-->"};
static constexpr CommentSyntax css{{}, u"/*", u"*/"};
static constexpr Text branch = u"break case catch continue default do else finally for if return switch throw try while";
static constexpr Text jsControl = u"break case catch continue default do else finally for if return switch throw try while yield";
static constexpr Text jsWords = u"as async await class const debugger delete enum export extends from function get "
    u"import in instanceof let new of set static super this typeof var void with";
static constexpr Text jsTypes = u"Array BigInt Boolean Date Error Function Intl Map Math Number Object Promise "
    u"RegExp Set String Symbol WeakMap WeakSet";
static constexpr Text jsValues = u"false true null undefined NaN Infinity";
static constexpr Text tsWords = u"abstract as asserts async await class const constructor debugger declare delete "
    u"export extends from function get global implements import in infer instanceof interface is keyof let module "
    u"namespace new of out override private protected public readonly require satisfies set static super this type "
    u"typeof unique using var with";
static constexpr Text tsTypes = u"any bigint boolean never number object string symbol unknown void Array BigInt "
    u"Boolean Date Error Function Intl Map Math Number Object Promise RegExp Set String Symbol WeakMap WeakSet "
    u"ReadonlyArray Record Partial Required Readonly Pick Omit Exclude Extract NonNullable ReturnType Parameters";
static constexpr Text objcWords = u"autoreleasepool available class compatibility_alias defs dynamic encode end "
    u"implementation interface optional package private property protected protocol public required selector "
    u"synchronized synthesize typedef struct enum union const static extern inline volatile sizeof self super";
static constexpr Text objcTypes = u"id Class SEL BOOL NSInteger NSUInteger CGFloat instancetype NSObject NSString "
    u"NSArray NSDictionary NSNumber NSData NSSet void bool char short int long float double signed unsigned size_t";
static constexpr Text shellWords = u"alias bg bind builtin cd command declare disown echo eval exec export fc fg "
    u"getopts hash history jobs local printf read readonly set shift source test times trap type typeset ulimit "
    u"umask unalias unset wait";
static constexpr Text shellControl = u"break case continue do done elif else esac exit fi for function if in return "
    u"select then time until while";
static constexpr Text luaWords = u"and function in local not or";
static constexpr Text luaControl = u"break do else elseif end for goto if repeat return then until while";
static constexpr Text luaTypes = u"boolean coroutine io math number os package string table thread utf8";
static constexpr Text boolean = u"false true";
static constexpr Text nullValues = u"false null true";
static constexpr Text htmlWords = u"a abbr address area article aside audio b base blockquote body br button canvas "
    u"caption cite code col colgroup data datalist dd details dialog div dl dt em embed fieldset figure figcaption "
    u"footer form h1 h2 h3 h4 h5 h6 head header hr html i iframe img input label legend li link main mark menu "
    u"meta meter nav noscript object ol optgroup option output p picture pre progress q samp script section select "
    u"small source span strong style sub summary sup table tbody td template textarea tfoot th thead time title "
    u"tr track ul var video wbr";
static constexpr Text htmlAttributes = u"accept action alt autocomplete checked class content controls data-* disabled "
    u"download for height hidden href id lang loading method name open pattern placeholder readonly rel required "
    u"role selected src srcset style tabindex target title type value width";
static constexpr Text cssWords = u"align-content align-items align-self animation appearance aspect-ratio "
    u"background background-color border border-radius bottom box-shadow box-sizing color column-gap content cursor "
    u"display filter flex flex-basis flex-direction flex-grow flex-shrink flex-wrap font font-family font-size "
    u"font-weight gap grid grid-area grid-template-columns grid-template-rows height inset justify-content left "
    u"letter-spacing line-height list-style margin margin-bottom margin-left margin-right margin-top max-height "
    u"max-width min-height min-width object-fit opacity overflow overflow-x overflow-y padding padding-bottom "
    u"padding-left padding-right padding-top position right row-gap text-align text-decoration text-overflow "
    u"top transform transition vertical-align visibility white-space width z-index";

static constexpr LanguageInfo languages[] = {
    {"Plain Text", "txt text log", {}},
    {"C", "c", slash,
     u"alignas alignof auto const constexpr enum extern inline register restrict sizeof static static_assert "
     u"struct thread_local typedef typeof typeof_unqual union volatile _Alignas _Alignof _Atomic _Complex _Generic "
     u"_Imaginary _Noreturn _Static_assert _Thread_local",
     u"break case continue default do else for goto if return switch while",
     u"void bool char short int long float double signed unsigned _BitInt _Bool _Decimal32 _Decimal64 _Decimal128 "
     u"size_t ptrdiff_t FILE wchar_t",
     u"false true NULL nullptr"},
    {"C++", "h hh hpp hxx cc cpp cxx c++ cp inl ipp tpp ixx cppm",
     slash, u"alignas alignof and and_eq asm auto bitand bitor class compl concept const consteval constexpr "
     u"constinit const_cast decltype delete dynamic_cast enum explicit export extern friend import inline module "
     u"mutable namespace new noexcept operator override not not_eq or or_eq private protected public reinterpret_cast "
     u"requires sizeof static static_assert static_cast struct template thread_local typedef typeid typename union "
     u"using virtual volatile xor xor_eq final",
     u"break case catch continue co_return co_await co_yield default do else for goto if return switch throw try while",
     u"void bool char char8_t char16_t char32_t wchar_t short int long float double signed unsigned size_t ptrdiff_t FILE",
     u"false true NULL nullptr"},
    {"Python", "py pyw pyi pyx", hash,
     u"and as assert async await class def del from global import in is lambda nonlocal not or",
     u"elif except finally for if else break continue match case pass raise return try while with yield",
     u"bool bytes bytearray complex dict float frozenset int list memoryview object range set str tuple type",
     u"False None True"},
    {"Rust", "rs", nestedSlash,
     u"_ abstract as async become box const crate dyn enum extern final fn gen impl let macro mod move mut override "
     u"priv pub ref self Self static struct super trait type typeof union unsafe unsized use virtual where",
     u"await break continue do else for if in loop match return try while yield",
     u"bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize Option Result String Vec Box", boolean},
    {"JavaScript", "js mjs cjs", slash, jsWords, jsControl, jsTypes, jsValues},
    {"TypeScript", "ts mts cts", slash, tsWords, jsControl, tsTypes, jsValues},
    {"JavaScript JSX", "jsx", slash, jsWords, jsControl, jsTypes, jsValues},
    {"TypeScript TSX", "tsx", slash, tsWords, jsControl, tsTypes, jsValues},
    {"Objective-C", "m", slash, objcWords, branch, objcTypes, u"YES NO nil Nil NULL true false"},
    {"Objective-C++", "mm", slash, objcWords, branch, objcTypes, u"YES NO nil Nil NULL true false nullptr"},
    {"C#", "cs csx", slash,
     u"abstract add alias as async await base checked const delegate enum event explicit extern file fixed get global "
     u"implicit in init interface internal is let lock namespace new nameof operator out override params partial "
     u"private protected public readonly record ref remove required scoped sealed set sizeof stackalloc static struct "
     u"this typeof unchecked unsafe using value var virtual volatile where with class",
     u"break case catch continue default do else finally for foreach goto if return switch throw try while yield",
     u"bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort "
     u"void Task ValueTask IEnumerable IReadOnlyList List Dictionary Span ReadOnlySpan", nullValues},
    {"Java", "java", slash,
     u"_ abstract assert class const enum exports extends final implements import instanceof interface module native new non-sealed "
     u"open opens package permits private protected provides public record requires sealed static strictfp super "
     u"synchronized this throws to transient transitive uses var volatile with",
     u"break case catch continue default do else finally for goto if return switch throw try while yield",
     u"boolean byte char double float int long short void Object String Integer Long Boolean List Map Set Optional",
     nullValues},
    {"Kotlin", "kt kts", nestedSlash,
     u"actual annotation as by class companion const constructor crossinline data delegate dynamic enum expect external "
     u"fun get import in infix init inline inner interface internal is lateinit noinline object open operator out "
     u"override package private protected public reified sealed set suspend tailrec this super typealias typeof val var value where",
     u"break catch continue do else finally for if return throw try when while",
     u"Any Array Boolean Byte Char Double Float Int Long Nothing Short String Unit List Map Set Sequence", nullValues},
    {"Swift", "swift", nestedSlash,
     u"actor any as associatedtype async await borrowing class consuming convenience deinit distributed dynamic enum "
     u"extension fileprivate final func get import indirect init inout internal is isolated lazy let macro mutating "
     u"nonisolated open operator override package precedencegroup private protocol public repeat requires self set "
     u"some static struct subscript super typealias unowned var weak where",
     u"break case catch continue default defer do else fallthrough for guard if in rethrows return switch throw throws try while yield",
     u"Any AnyObject Array Bool Character Data Dictionary Double Float Int Int8 Int16 Int32 Int64 Never Optional "
     u"Result Set String UInt UInt8 UInt16 UInt32 UInt64 Void", u"false nil true"},
    {"Go", "go", slash,
     u"chan const func import interface map package range select struct type var",
     u"break case continue default defer else fallthrough for go goto if return switch",
     u"any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string "
     u"uint uint8 uint16 uint32 uint64 uintptr", u"false iota nil true"},
    {"Zig", "zig zon", {u"//", {}, {}},
     u"addrspace align allowzero anyframe anytype asm callconv comptime const enum error export extern fn inline "
     u"linksection noalias noinline nosuspend opaque packed pub resume struct suspend test threadlocal union var volatile",
     u"and break catch continue defer else errdefer for if or orelse return switch try unreachable while",
     u"anyerror bool comptime_float comptime_int f16 f32 f64 f80 f128 isize noreturn type usize void",
     u"false null true undefined"},
    {"Dart", "dart", nestedSlash,
     u"abstract as assert async await base class const covariant deferred dynamic enum export extends extension "
     u"external factory final Function get hide implements import interface is late library mixin native new of on "
     u"operator part required sealed set show static super sync this typedef var with",
     u"break case catch continue default do else finally for if in rethrow return switch throw try while yield",
     u"bool double int num void Never Object String Symbol Future Iterable List Map Set Stream", nullValues},
    {"Ruby", "rb rake gemspec ru", hash,
     u"alias and begin class def defined? end ensure module not or private protected public self super undef BEGIN END",
     u"break case else elsif for if in next redo rescue retry return then unless until when while yield",
     u"Array Enumerator Exception File Float Hash Integer IO Module Numeric Object Proc Range Regexp String Symbol",
     u"false nil true __FILE__ __LINE__ __ENCODING__"},
    {"PHP", "php php3 php4 php5 php7 php8 phtml phps", slash,
     u"abstract and array as callable class clone const declare echo empty enum eval extends final fn function global "
     u"implements include include_once instanceof insteadof interface isset list namespace new or print private "
     u"protected public readonly require require_once static trait unset use var xor",
     u"break case catch continue default die do else elseif enddeclare endfor endforeach endif endswitch endwhile "
     u"exit finally for foreach goto if match return throw try while yield",
     u"bool float int iterable mixed never object parent self string void", nullValues, true},
    {"Perl", "pl pm t psgi", hash,
     u"and bless chomp chop cmp defined delete do eq eval exists format ge glob gt import isa le local lt my ne no not "
     u"or our package print printf require scalar say state sub tie undef unpack use wantarray xor",
     u"continue die else elsif for foreach given goto if last next redo return unless until when while",
     u"ARRAY CODE HASH IO REF SCALAR", u"__DATA__ __END__ __FILE__ __LINE__ __PACKAGE__"},
    {"Lua", "lua", {u"--", u"--[[", u"]]"}, luaWords, luaControl, luaTypes, u"false nil true"},
    {"Luau", "luau", {u"--", u"--[[", u"]]"},
     u"and declare export function in local not or type typeof", u"break continue do else elseif end for if repeat return then until while",
     u"any boolean buffer never number string table thread unknown vector", u"false nil true"},
    {"Bash", "sh bash", hash, shellWords, shellControl, {}, u"true false"},
    {"Zsh", "zsh", hash, shellWords, shellControl, {}, u"true false"},
    {"Fish", "fish", hash, u"abbr alias builtin cd command contains emit eval exec function math printf read set set_color source status string test type wait",
     u"and begin break case continue else end exit for if in not or return switch while", {}, u"true false"},
    {"PowerShell", "ps1 psm1 psd1", {u"#", u"<#", u"#>"},
     u"begin class data dynamicparam end enum exit filter function in param process using var workflow",
     u"break catch continue do else elseif finally for foreach if return switch throw trap try until while",
     u"array bool byte char datetime decimal double hashtable int long object scriptblock string type void",
     u"$false $null $true", true},
    {"R", "r rprofile", hash, u"function in library require source",
     u"break else for if next repeat return while", u"character complex data.frame double factor integer list logical matrix numeric vector",
     u"FALSE Inf NA NA_character_ NA_complex_ NA_integer_ NA_real_ NaN NULL TRUE"},
    {"Julia", "jl", {u"#", u"#=", u"=#", true},
     u"abstract baremodule begin const end export function global import isa let local macro module mutable primitive "
     u"public quote struct type using where", u"break catch continue do else elseif finally for if in return try while",
     u"Any Array Bool Char Complex Dict Float16 Float32 Float64 Int Int8 Int16 Int32 Int64 Matrix Missing Nothing "
     u"Number Pair Real Set String Tuple UInt UInt8 UInt16 UInt32 UInt64 Vector", u"false missing nothing true Inf NaN"},
    {"Scala", "scala sc", nestedSlash,
     u"abstract as case class def derives end enum export extends final given implicit import inline lazy match new "
     u"object opaque open override package private protected sealed super this trait transparent type using val var with",
     u"catch do else finally for if return then throw try while yield",
     u"Any AnyRef AnyVal Array Boolean Byte Char Double Either Float Int List Long Map Nothing Null Option Seq Set Short String Unit Vector",
     u"false null true None"},
    {"Groovy", "groovy gradle gvy gy gsh", slash,
     u"abstract as assert class def enum extends final implements import in instanceof interface new package private "
     u"protected public static super synchronized this throws trait transient var volatile",
     branch, u"boolean byte char double float int long Object short String void", nullValues},
    {"Haskell", "hs", {u"--", u"{-", u"-}", true},
     u"class data default deriving family forall foreign hiding import infix infixl infixr instance module newtype "
     u"qualified type where", u"case do else if in let of then",
     u"Bool Char Double Either Float IO Int Integer Maybe Ordering String Word", u"False True Nothing"},
    {"F#", "fs fsi fsx", {u"//", u"(*", u"*)", true},
     u"abstract and as assert base class default delegate downcast enum exception extern fun function inherit inline "
     u"interface internal lazy let member module mutable namespace new of open override private public rec static struct "
     u"type upcast use val when", u"begin do done elif else end exception finally for if in match return then to try while with yield",
     u"array bigint bool byte char decimal float float32 int int64 list obj option result seq string unit", nullValues},
    {"Elixir", "ex exs", hash,
     u"alias and def defdelegate defexception defguard defimpl defmacro defmodule defp defprotocol defstruct "
     u"import in not or quote require unquote use when", u"after case catch cond do else end fn for if raise receive rescue try unless with",
     u"Agent Atom Enum File GenServer IO Kernel List Map Module Process Range Regex String Task Tuple",
     u"false nil true"},
    {"Clojure", "clj cljs cljc edn", {u";", {}, {}},
     u"binding declare def defmacro defmulti defn defn- defprotocol defrecord deftype fn import let letfn loop "
     u"ns refer require set! var", u"case catch cond do doseq dotimes else finally for if if-let recur throw try when when-let",
     u"boolean char double int long object string vector", u"false nil true"},
    {"Visual Basic", "vb bas vbs", {u"'", {}, {}},
     u"addhandler addressof alias and andalso as async await byref byval class const declare default delegate dim enum event "
     u"friend function get handles implements imports inherits interface is isnot iterator like mod module mustinherit mustoverride "
     u"namespace new not notinheritable notoverridable of operator option optional or orelse overloads overridable overrides "
     u"paramarray partial private property protected public readonly removehandler set shadows shared static structure sub xor",
     u"case catch continue do each else elseif end exit finally for goto if in loop next on resume return select stop "
     u"then throw to try until when while with yield",
     u"boolean byte char date decimal double integer long object sbyte short single string uinteger ulong ushort",
     u"false nothing true", true},
    {"SQL", "sql ddl dml", {u"--", u"/*", u"*/", true},
     u"add all alter analyze as asc begin by cascade check collate column commit constraint create cross database "
     u"declare default delete desc distinct drop except exists explain foreign from full grant group having index "
     u"inner insert intersect into join key lateral left limit merge offset on order outer over partition primary "
     u"references returning revoke right rollback row rows schema select set table truncate union unique update "
     u"using values view where window with recursive materialized temporary trigger procedure function temporary",
     u"and between case else end escape in is like not or then when",
     u"bigint binary blob boolean bytea char date decimal double float int integer interval json jsonb numeric "
     u"real smallint text time timestamp uuid varbinary varchar",
     nullValues, true},
    {"HTML", "htm html shtml", markup, htmlWords, {}, htmlAttributes},
    {"XML", "xml xhtml svg xsl xslt xsd xaml plist storyboard xib csproj fsproj vbproj pom props targets iml resx rss atom", markup},
    {"CSS", "css", css, cssWords, u"important inherit initial revert unset", {}, u"auto none transparent currentColor"},
    {"SCSS", "scss", slash, u"function include mixin extend use forward important inherit initial revert unset",
     u"at-root each else for if return while", {}, u"auto none transparent false null true"},
    {"Less", "less", slash, u"import plugin important inherit initial revert unset", u"and not when", {}, u"auto none transparent"},
    {"JSON", "json geojson webmanifest ipynb har", slash, {}, {}, {}, nullValues},
    {"JSON with Comments", "jsonc code-workspace", slash, {}, {}, {}, nullValues},
    {"YAML", "yml yaml", hash, {}, {}, {}, u"false null true False Null True FALSE NULL TRUE"},
    {"TOML", "toml", hash, {}, {}, {}, u"false true inf nan"},
    {"INI", "ini cfg conf properties env gitconfig editorconfig", {u";", {}, {}}, {}, {}, {},
     u"false no null off on true yes", true},
    {"Markdown", "md markdown mdown mkd mkdn mdtext", markup},
    {"Makefile", "mk mak", hash,
     u"define endef export include override private sinclude undefine unexport vpath",
     u"else endif ifdef ifeq ifndef ifneq", {},
     u".DEFAULT .DEFAULT_GOAL .DELETE_ON_ERROR .IGNORE .INTERMEDIATE .NOTPARALLEL .ONESHELL .PHONY .POSIX .PRECIOUS .SECONDARY .SILENT .SUFFIXES"},
    {"CMake", "cmake", hash,
     u"add_compile_definitions add_compile_options add_custom_command add_custom_target add_executable add_library "
     u"add_subdirectory cmake_minimum_required configure_file enable_language find_package include install list "
     u"message option project set string target_compile_definitions target_compile_features target_compile_options "
     u"target_include_directories target_link_libraries target_sources unset",
     u"block break continue else elseif endblock endforeach endfunction endif endmacro endwhile foreach function if macro return while",
     {}, u"false no off on true yes", true},
    {"Dockerfile", "dockerfile containerfile", hash,
     u"add arg cmd copy entrypoint env expose from healthcheck label maintainer onbuild run shell stopsignal user volume workdir",
     u"as", {}, u"none", true},
    {"Assembly", "s asm nasm", {u";", {}, {}},
     u"add and b bl br call cmp db dd dq dw equ extern global jmp je jne lea ldr mov movk movz nop or pop "
     u"push ret section str sub syscall test xor", {}, {}, {}, true},
    {"Odin", "odin", nestedSlash,
     u"asm auto_cast bit_field bit_set cast context distinct dynamic enum foreign import map matrix package proc "
     u"struct transmute union using where",
     u"break case continue defer do else fallthrough for if in not_in or_break or_continue or_else or_return return switch when",
     u"any bool b8 b16 b32 b64 byte complex32 complex64 complex128 cstring f16 f32 f64 f16be f32be f64be f16le f32le f64le "
     u"i8 i16 i32 i64 i128 i16be i32be i64be i128be i16le i32le i64le i128le int "
     u"quaternion64 quaternion128 quaternion256 rawptr rune string typeid "
     u"u8 u16 u32 u64 u128 u16be u32be u64be u128be u16le u32le u64le u128le uint uintptr",
     u"false nil true ODIN_ARCH ODIN_ARCH_STRING ODIN_BUILD_MODE ODIN_BUILD_PROJECT_NAME ODIN_COMPILE_TIMESTAMP "
     u"ODIN_DEBUG ODIN_ENDIAN ODIN_ERROR_POS_STYLE ODIN_OS ODIN_OS_STRING ODIN_ROOT ODIN_TEST ODIN_VENDOR ODIN_VERSION "
     u"ODIN_VERSION_HASH"},
    {"GML", "gml", slash,
     u"and begin constructor delete div end enum function globalvar mod new not or static var xor",
     u"break case catch continue default do else exit finally for if repeat return switch then throw try until while with",
     u"alarm argument argument_count argument0 argument1 argument2 argument3 argument4 argument5 "
     u"argument6 argument7 argument8 argument9 argument10 argument11 argument12 argument13 argument14 argument15 async_load "
     u"bbox_bottom bbox_left bbox_right bbox_top current_day current_hour current_minute current_month current_second "
     u"current_time current_year delta_time depth direction fps fps_real friction gravity gravity_direction health hspeed "
     u"id image_alpha image_angle image_blend image_index image_number image_speed image_xscale image_yscale instance_count "
     u"instance_id keyboard_key keyboard_lastchar keyboard_lastkey keyboard_string layer lives mask_index mouse_button mouse_x "
     u"mouse_y object_index os_browser os_device os_type os_version path_index path_position path_speed persistent room "
     u"room_first room_height room_last room_persistent room_speed room_width score solid speed sprite_height sprite_index "
     u"sprite_width sprite_xoffset sprite_yoffset visible vspeed x xprevious xstart y yprevious ystart",
     u"all bm_add bm_max bm_normal bm_subtract c_aqua c_black c_blue c_dkgray c_fuchsia c_gray c_green c_lime c_ltgray "
     u"c_maroon c_navy c_olive c_orange c_purple c_red c_silver c_teal c_white c_yellow ev_alarm ev_collision ev_create "
     u"ev_destroy ev_draw ev_keypress ev_keyrelease ev_keyboard ev_step ev_step_begin ev_step_end fa_bottom fa_center "
     u"fa_left fa_middle fa_right fa_top false global gp_axislh gp_axislv gp_axisrh gp_axisrv gp_face1 gp_face2 "
     u"gp_face3 gp_face4 gp_padd gp_padl gp_padr gp_padu infinity mb_any mb_left mb_middle mb_none mb_right noone "
     u"os_android os_ios os_linux os_macosx os_windows other pi pr_linelist pr_linestrip pr_pointlist pr_trianglefan "
     u"pr_trianglelist pr_trianglestrip self true undefined "
     u"vk_alt vk_anykey vk_backspace vk_control vk_delete vk_down vk_end vk_enter vk_escape vk_f1 vk_f2 vk_f3 vk_f4 vk_f5 "
     u"vk_f6 vk_f7 vk_f8 vk_f9 vk_f10 vk_f11 vk_f12 vk_home vk_insert vk_left vk_nokey vk_pagedown vk_pageup vk_right "
     u"vk_shift vk_space vk_tab vk_up"},
    {"Common Lisp", "lisp lsp asd", {u";", u"#|", u"|#", true},
     u"&allow-other-keys &aux &body &environment &key &optional &rest &whole and assert check-type declare "
     u"declaim define-compiler-macro define-condition define-method-combination define-modify-macro "
     u"define-setf-expander define-symbol-macro defclass defconstant defgeneric defmacro defmethod defpackage "
     u"defparameter defsetf defstruct defsystem deftype defun defvar destructuring-bind eval-when flet function "
     u"ignore-errors in-package labels lambda let let* load-time-value locally macrolet multiple-value-bind "
     u"multiple-value-call multiple-value-prog1 multiple-value-setq not or pop proclaim prog prog* prog1 prog2 progn "
     u"progv push pushnew quote rotatef setf setq shiftf symbol-macrolet the trace untrace "
     u"with-accessors with-compilation-unit with-input-from-string with-open-file with-open-stream "
     u"with-output-to-string with-package-iterator with-simple-restart with-slots with-standard-io-syntax",
     u"block case catch ccase cond ctypecase do do* do-all-symbols do-external-symbols do-symbols dolist dotimes "
     u"ecase etypecase go handler-bind handler-case if loop return return-from restart-bind restart-case "
     u"tagbody throw typecase unless unwind-protect when",
     u"array atom bignum bit bit-vector boolean character complex condition cons double-float error fixnum float "
     u"function hash-table integer keyword list long-float null number package pathname random-state ratio rational "
     u"readtable real sequence short-float signed-byte simple-array simple-bit-vector simple-string simple-vector "
     u"single-float standard-object stream string symbol unsigned-byte vector",
     u"nil t pi *debug-io* *error-output* *features* *package* *print-base* *read-base* *readtable* "
     u"*standard-input* *standard-output* *trace-output* most-positive-fixnum most-negative-fixnum", true},
};
static_assert(std::size(languages) == size_t(Language::Count));

const LanguageInfo &InfoForLanguage(Language language)
{
    size_t index = size_t(language);
    return languages[index < std::size(languages) ? index : 0];
}

static bool Listed(Path word, Path list)
{
    while (!list.empty()) {
        size_t end = list.find(' ');
        if (list.substr(0, end) == word)
            return true;
        if (end == Path::npos)
            break;
        list.remove_prefix(end + 1);
    }
    return false;
}

static Language LanguageForExtension(Path ext)
{
    if (ext.empty())
        return Language::Plain;
    for (size_t index = 1; index < std::size(languages); ++index) {
        if (Listed(ext, languages[index].extensions))
            return Language(index);
    }
    return Language::Plain;
}

static bool PathComponent(Path path, Path name)
{
    size_t at = path.find(name);
    while (at != Path::npos) {
        size_t end = at + name.size();
        if ((at == 0 || path[at - 1] == '/') && (end == path.size() || path[end] == '/'))
            return true;
        at = path.find(name, end);
    }
    return false;
}

static void Lowercase(std::string &text)
{
    for (char &ch : text) {
        if (ch >= 'A' && ch <= 'Z')
            ch += 'a' - 'A';
    }
}

static Language Interpreter(Path name)
{
    if (name.starts_with("python") || name == "pypy" || name == "pypy3")
        return Language::Python;
    if (name == "node" || name == "nodejs" || name == "bun" || name == "deno")
        return Language::JavaScript;
    if (name == "tsx" || name == "ts-node")
        return Language::TypeScript;
    if (name.starts_with("lua") && name != "luau")
        return Language::Lua;
    if (name == "Rscript")
        return Language::R;
    if (name == "sh" || name == "dash" || name == "ksh")
        return Language::Bash;
    if (name == "pwsh")
        return Language::PowerShell;
    if (name == "runghc" || name == "runhaskell")
        return Language::Haskell;
    if (name == "swift" || name == "ruby" || name == "perl" || name == "php" ||
        name == "bash" || name == "zsh" || name == "fish" || name == "luau") {
        if (name == "swift") return Language::Swift;
        if (name == "ruby") return Language::Ruby;
        if (name == "perl") return Language::Perl;
        if (name == "php") return Language::PHP;
        return LanguageForExtension(name);
    }
    if (name == "julia") return Language::Julia;
    if (name == "elixir") return Language::Elixir;
    if (name == "groovy") return Language::Groovy;
    if (name == "sbcl" || name == "clisp" || name == "ecl") return Language::CommonLisp;
    return Language::Plain;
}

static Language ShebangLanguage(Path text)
{
    if (!text.starts_with("#!"))
        return Language::Plain;
    text.remove_prefix(2);
    text = text.substr(0, text.find_first_of("\r\n"));
    bool env = false;
    bool skipArgument = false;
    while (!text.empty()) {
        size_t first = text.find_first_not_of(" \t");
        if (first == Path::npos)
            break;
        text.remove_prefix(first);
        size_t last = text.find_first_of(" \t");
        Path word = text.substr(0, last);
        if (last == Path::npos)
            text = {};
        else
            text.remove_prefix(last + 1);
        if (env) {
            if (skipArgument) {
                skipArgument = false;
                continue;
            }
            skipArgument = word == "-u" || word == "-C" || word == "--unset" || word == "--chdir";
            if (word.front() == '-' || word.find('=') != Path::npos)
                continue;
        }
        Path name = word.substr(word.rfind('/') + 1);
        if (!env && name == "env") {
            env = true;
            continue;
        }
        return Interpreter(name);
    }
    return Language::Plain;
}

Language DetectLanguage(Path path, Path beginning)
{
    Path original = path.substr(path.rfind('/') + 1);
    size_t originalDot = original.rfind('.');
    Path originalExt = originalDot == Path::npos ? Path{} : original.substr(originalDot + 1);
    if (originalExt == "C")
        return Language::Cpp;
    if (originalExt == "M")
        return Language::ObjectiveCpp;
    std::string lower(path);
    Lowercase(lower);
    Path name = Path(lower).substr(lower.rfind('/') + 1);
    Path extension = originalDot == Path::npos ? Path{} : name.substr(originalDot + 1);

    if (Listed(name, "makefile gnumakefile bsdmakefile"))
        return Language::Makefile;
    if (name == "cmakelists.txt")
        return Language::CMake;
    if (name == "dockerfile" || name == "containerfile" || name.starts_with("dockerfile.") ||
        name.starts_with("containerfile."))
        return Language::Dockerfile;
    if (Listed(name, "gemfile rakefile podfile brewfile guardfile fastfile vagrantfile"))
        return Language::Ruby;
    if (Listed(name, ".bashrc .bash_profile .bash_login .bash_logout .profile configure"))
        return Language::Bash;
    if (Listed(name, ".zshrc .zlogin .zshenv .zprofile .zlogout"))
        return Language::Zsh;
    if (name == ".rprofile")
        return Language::R;
    if (Listed(name, "readme changelog contributing"))
        return Language::Markdown;
    if (Listed(name, ".editorconfig .gitconfig .gitmodules .gitignore .gitattributes .dockerignore .npmrc .pypirc .env") ||
        name.starts_with(".env."))
        return Language::INI;
    if (name == "tsconfig.json" || name == "jsconfig.json" ||
        (extension == "json" && PathComponent(lower, ".vscode") &&
         Listed(name, "settings.json tasks.json launch.json extensions.json")))
        return Language::JSONC;
    if (name == "go.mod" || name == "go.work")
        return Language::Go;
    if (name == "build.zig.zon")
        return Language::Zig;

    Language byExtension = LanguageForExtension(extension);
    if (byExtension != Language::GML && (byExtension != Language::Plain || Listed(extension, languages[0].extensions)))
        return byExtension;
    if (Language shebang = ShebangLanguage(beginning); shebang != Language::Plain)
        return shebang;
    size_t first = beginning.find_first_not_of(" \t\r\n");
    if (first != Path::npos) {
        beginning.remove_prefix(first);
        if (beginning.starts_with("<?xml ") || beginning.starts_with("<?xml\t") ||
            (byExtension == Language::GML && beginning.starts_with("<gml:")))
            return Language::XML;
        if (beginning.starts_with("<?php") || beginning.starts_with("<?="))
            return Language::PHP;
    }
    return byExtension;
}

Language LanguageForFence(Text name)
{
    std::string narrow;
    for (char16_t ch : name) {
        if (ch > 127)
            return Language::Plain;
        narrow.push_back(char(ch));
    }
    Lowercase(narrow);
    if (narrow == "csharp" || narrow == "c#") return Language::CSharp;
    if (narrow == "objective-c" || narrow == "objc") return Language::ObjectiveC;
    if (narrow == "objective-cpp" || narrow == "objective-c++" || narrow == "objcpp") return Language::ObjectiveCpp;
    if (narrow == "javascript") return Language::JavaScript;
    if (narrow == "typescript") return Language::TypeScript;
    if (narrow == "python" || narrow == "python3") return Language::Python;
    if (narrow == "rust") return Language::Rust;
    if (narrow == "shell" || narrow == "shellscript" || narrow == "console") return Language::Bash;
    if (narrow == "kotlin") return Language::Kotlin;
    if (narrow == "haskell") return Language::Haskell;
    if (narrow == "fsharp" || narrow == "f#") return Language::FSharp;
    if (narrow == "powershell" || narrow == "pwsh") return Language::PowerShell;
    if (narrow == "ruby") return Language::Ruby;
    if (narrow == "perl") return Language::Perl;
    if (narrow == "julia") return Language::Julia;
    if (narrow == "elixir") return Language::Elixir;
    if (narrow == "clojure") return Language::Clojure;
    if (narrow == "common-lisp" || narrow == "commonlisp" || narrow == "cl") return Language::CommonLisp;
    if (narrow == "gamemaker") return Language::GML;
    if (narrow == "make" || narrow == "makefile") return Language::Makefile;
    return LanguageForExtension(narrow);
}