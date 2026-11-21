#include "Lexer.hpp"

#include <algorithm>
#include <array>
#include <mutex>
#include <unordered_set>
#include <utility>

using Text = std::u16string_view;
using Words = std::unordered_set<Text>;

static constexpr Text odinProcedures[] = {
    u"abs", u"align_of", u"append", u"append_elem", u"append_elems", u"assert", u"cap", u"clamp", u"clear",
    u"complex", u"compress_values", u"conj", u"delete", u"expand_values", u"free", u"free_all", u"imag", u"jmag",
    u"kmag", u"len", u"make", u"max", u"min", u"new", u"offset_of", u"offset_of_by_string", u"panic", u"pop",
    u"quaternion", u"raw_data", u"real", u"reserve", u"resize", u"size_of", u"soa_unzip", u"soa_zip", u"swizzle",
    u"type_info_of", u"type_of", u"typeid_of", u"unreachable",
};
static_assert(std::ranges::is_sorted(odinProcedures));

static constexpr Text gmlProcedures =
    u"abs angle_difference array_copy array_create array_delete array_filter array_find_index array_get array_insert "
    u"array_length array_map array_pop array_push array_resize array_set array_sort asset_get_index "
    u"audio_is_playing audio_play_sound audio_stop_sound audio_sound_gain ceil choose clamp collision_circle "
    u"collision_line collision_point collision_rectangle cos degtorad distance_to_object draw_circle draw_clear "
    u"draw_get_alpha draw_get_colour draw_line draw_rectangle draw_self draw_set_alpha draw_set_color draw_set_colour "
    u"draw_set_font draw_sprite draw_sprite_ext draw_text draw_text_colour draw_text_ext ds_grid_create ds_grid_destroy "
    u"ds_list_add ds_list_create ds_list_destroy ds_list_find_value ds_map_create ds_map_destroy ds_map_exists "
    u"ds_map_find_value event_inherited event_perform floor frac game_end game_get_speed game_restart game_set_speed "
    u"gamepad_axis_value gamepad_button_check gamepad_button_check_pressed gamepad_is_connected instance_change "
    u"instance_create_depth instance_create_layer instance_destroy instance_exists instance_find instance_nearest "
    u"instance_number irandom irandom_range is_array is_bool is_method is_real is_string is_struct is_undefined "
    u"json_parse json_stringify keyboard_check keyboard_check_direct keyboard_check_pressed keyboard_check_released "
    u"layer_get_id layer_get_depth layer_set_visible lengthdir_x lengthdir_y lerp make_colour_rgb max method min "
    u"motion_add motion_set mouse_check_button mouse_check_button_pressed mouse_check_button_released move_contact_solid "
    u"move_towards_point ord place_free place_meeting point_direction point_distance power radtodeg random random_range "
    u"rectangle_in_rectangle room_goto room_goto_next room_restart round script_execute show_debug_message sign sin "
    u"sprite_get_height sprite_get_number sprite_get_width sprite_get_xoffset sprite_get_yoffset sqrt string "
    u"string_copy string_format string_length string_lower string_upper struct_exists struct_get struct_set "
    u"variable_global_exists variable_instance_exists variable_instance_get variable_instance_set";

static Words SplitWords(Text list)
{
    Words words;
    while (!list.empty()) {
        size_t end = list.find(u' ');
        if (end)
            words.insert(list.substr(0, end));
        if (end == Text::npos)
            break;
        list.remove_prefix(end + 1);
    }
    return words;
}

static const Words &LispProcedures()
{
    static const auto procedures = SplitWords(
        u"+ - * / 1+ 1- = /= < > <= >= abs adjoin append apply aref assoc ash atom boundp butlast caaadr caaar "
        u"caar cadr car cdar cddr cdr ceiling char char-code char= close clrhash coerce compile complement "
        u"concatenate cons consp copy-list copy-seq count delete describe elt eq eql equal equalp error eval "
        u"evenp every expt fill find find-if first floor format funcall gensym get getf gethash get-internal-real-time "
        u"identity incf decf intern intersection last length list list* listp load logand logior make-array "
        u"make-hash-table make-instance make-list make-pathname make-string map mapc mapcar mapcan mapcon maphash "
        u"max member member-if merge min mod multiple-value-list nconc ninth nreverse nth nthcdr numberp oddp open "
        u"package-name parse-integer pathnamep position position-if princ prin1 print random read read-char read-line "
        u"read-from-string reduce rem remhash remove remove-duplicates remove-if remove-if-not replace rest reverse "
        u"round search second set-difference seventh sixth sleep slot-value some sort sqrt stable-sort string-downcase "
        u"string-equal string-upcase string= stringp subseq substitute symbol-name symbolp tenth terpri third truncate "
        u"type-of typep union values values-list vectorp warn write write-char write-line write-string zerop");
    return procedures;
}

struct Vocabulary {
    Words keywords, types, control, constants;
    std::vector<std::u16string> uppercase;
    std::vector<Text> completion;
};

static const Vocabulary &VocabularyFor(Language language)
{
    static std::array<Vocabulary, size_t(Language::Count)> tables;
    static std::array<std::once_flag, tables.size()> prepared;
    size_t index = size_t(language) < tables.size() ? size_t(language) : 0;
    auto &table = tables[index];
    std::call_once(prepared[index], [&] {
        const auto &info = InfoForLanguage(Language(index));
        table.keywords = SplitWords(info.keywords);
        table.types = SplitWords(info.types);
        table.control = SplitWords(info.control);
        table.constants = SplitWords(info.constants);
        if (language == Language::ObjectiveC || language == Language::ObjectiveCpp) {
            const auto &base = VocabularyFor(language == Language::ObjectiveC ? Language::C : Language::Cpp);
            table.keywords.insert(base.keywords.begin(), base.keywords.end());
            table.types.insert(base.types.begin(), base.types.end());
            table.control.insert(base.control.begin(), base.control.end());
            table.constants.insert(base.constants.begin(), base.constants.end());
        }
        for (const Words *group : {&table.keywords, &table.types, &table.control, &table.constants})
            table.completion.insert(table.completion.end(), group->begin(), group->end());
        if (language == Language::Odin)
            table.completion.insert(table.completion.end(), std::begin(odinProcedures), std::end(odinProcedures));
        if (language == Language::GML) {
            Words functions = SplitWords(gmlProcedures);
            table.completion.insert(table.completion.end(), functions.begin(), functions.end());
        }
        if (language == Language::CommonLisp) {
            const auto &procedures = LispProcedures();
            table.completion.insert(table.completion.end(), procedures.begin(), procedures.end());
        }
        if (language == Language::SCSS || language == Language::Less) {
            Words properties = SplitWords(InfoForLanguage(Language::CSS).keywords);
            table.completion.insert(table.completion.end(), properties.begin(), properties.end());
        }
        if (language == Language::SQL || language == Language::CommonLisp) {
            table.uppercase.reserve(table.completion.size());
            for (Text word : table.completion) {
                auto &uppercase = table.uppercase.emplace_back(word);
                for (char16_t &ch : uppercase) {
                    if (ch >= u'a' && ch <= u'z')
                        ch -= u'a' - u'A';
                }
            }
            for (const auto &word : table.uppercase)
                table.completion.push_back(word);
        }
        std::sort(table.completion.begin(), table.completion.end());
        table.completion.erase(std::unique(table.completion.begin(), table.completion.end()), table.completion.end());
    });
    return table;
}

static char16_t At(Text line, size_t index)
{
    return index < line.size() ? line[index] : 0;
}

static bool Digit(char16_t ch)
{
    return ch >= u'0' && ch <= u'9';
}

static bool HexDigit(char16_t ch)
{
    return Digit(ch) || (ch >= u'a' && ch <= u'f') || (ch >= u'A' && ch <= u'F');
}

static bool Space(char16_t ch)
{
    return ch == u' ' || ch == u'\t' || ch == u'\v' || ch == u'\f';
}

static bool NameStart(char16_t ch)
{
    return IsASCIIIdentifierStart(ch) || ch >= 0x80;
}

static bool NamePart(char16_t ch)
{
    return NameStart(ch) || Digit(ch);
}

static size_t SkipSpace(Text line, size_t index)
{
    while (Space(At(line, index)))
        ++index;
    return index;
}

const std::vector<Text> &CompletionWords(Language language)
{
    return VocabularyFor(language).completion;
}

static char16_t Lower(char16_t ch)
{
    return ch >= u'A' && ch <= u'Z' ? ch + u'a' - u'A' : ch;
}

static bool StartsIgnoringCase(Text text, Text prefix)
{
    return text.size() >= prefix.size() &&
        std::equal(prefix.begin(), prefix.end(), text.begin(), [](char16_t a, char16_t b) { return Lower(a) == Lower(b); });
}

static Ink WordInk(Text word, Language language, char16_t next)
{
    const Vocabulary &vocabulary = VocabularyFor(language);
    std::array<char16_t, 64> lower;
    Text lookup = word;
    if (InfoForLanguage(language).ignoreCase && word.size() <= lower.size()) {
        std::transform(word.begin(), word.end(), lower.begin(), Lower);
        lookup = Text(lower.data(), word.size());
    }
    if (vocabulary.control.contains(lookup))
        return Ink::Control;
    if (vocabulary.constants.contains(lookup))
        return Ink::Constant;
    if (vocabulary.keywords.contains(lookup))
        return Ink::Keyword;
    if (vocabulary.types.contains(lookup))
        return Ink::Type;
    if (next == u'(' || (language == Language::Rust && next == u'!'))
        return Ink::Function;
    if (CFamily(language) && word.ends_with(u"_t"))
        return Ink::Type;
    if (InfoForLanguage(language).ignoreCase)
        return Ink::Name;

    if (word.size() > 1 && word.front() >= u'A' && word.front() <= u'Z') {
        for (char16_t ch : word) {
            if (ch >= u'a' && ch <= u'z')
                return language == Language::GML ? Ink::Name : Ink::Type;
        }
        return Ink::Constant;
    }
    return Ink::Name;
}

static size_t SkipTrivia(Text line, size_t index)
{
    index = SkipSpace(line, index);
    while (line.substr(index).starts_with(u"/*")) {
        size_t end = line.find(u"*/", index + 2);
        if (end == Text::npos)
            return line.size();
        index = SkipSpace(line, end + 2);
    }
    return line.substr(index).starts_with(u"//") ? line.size() : index;
}

static bool ScopeAt(Text line, size_t index)
{
    return At(line, index) == u':' && At(line, index + 1) == u':';
}

static bool WordAt(Text line, size_t index, Text word)
{
    return line.substr(index).starts_with(word) && !NamePart(At(line, index + word.size()));
}

static bool OpensAngle(Text line, size_t index)
{
    return At(line, index) == u'<' && At(line, index + 1) != u'<' && At(line, index + 1) != u'=';
}

static size_t AfterCppTemplateArguments(Text line, size_t open)
{
    // Bound the lookahead for ambiguous expressions such as a<b. Known types and template headers don't need it.
    Text probe = line.substr(0, std::min(line.size(), open + 512));
    unsigned angles = 1;
    unsigned groups = 0;
    for (size_t at = SkipTrivia(probe, open + 1); at < probe.size(); at = SkipTrivia(probe, at + 1)) {
        char16_t ch = probe[at];
        if (ch == u'"' || ch == u'\'') {
            do {
                if (probe[at] == u'\\' && at + 1 < probe.size())
                    ++at;
                ++at;
            } while (at < probe.size() && probe[at] != ch);
            if (at == probe.size())
                break;
        } else if (ch == u'(' || ch == u'[' || ch == u'{') {
            ++groups;
        } else if (groups) {
            if (ch == u')' || ch == u']' || ch == u'}')
                --groups;
        } else if (ch == u'<') {
            if (!OpensAngle(probe, at))
                break;
            ++angles;
        } else if (ch == u'>' && At(probe, at - 1) != u'-' && At(probe, at + 1) != u'=') {
            if (--angles == 0)
                return SkipTrivia(line, at + 1);
        } else if (ch == u';' || ch == u')' || ch == u']' || ch == u'}' || ch == u'=' ||
                   (ch == u'&' && At(probe, at + 1) == u'&') || (ch == u'|' && At(probe, at + 1) == u'|')) {
            break;
        }
    }
    return Text::npos;
}

static bool StandardCppType(Text word)
{
    static const Words types = SplitWords(u"any array atomic basic_string basic_string_view bitset complex deque duration "
        u"enable_if expected false_type filesystem_error function future initializer_list integral_constant "
        u"istream iterator_traits jthread list lock_guard map multimap multiset mutex numeric_limits optional ostream "
        u"pair path priority_queue promise queue ratio reference_wrapper regex remove_cv remove_reference "
        u"set shared_lock shared_mutex shared_ptr span stack string string_view stringstream thread time_point "
        u"true_type tuple underlying_type unique_lock unique_ptr unordered_map unordered_multimap unordered_multiset "
        u"unordered_set u8string u16string u32string variant vector weak_ptr wstring");
    return types.contains(word);
}

static bool AtParameterStart(const NameContext &context)
{
    return context.parameterStart && context.angles == 1 && context.argumentGroups == 0;
}

static Ink ContextualWordInk(Text line, Text word, size_t end, Language language,
                             NameContext &context, bool rawIdentifier)
{
    bool rust = language == Language::Rust;
    bool wasQualified = std::exchange(context.qualified, false);
    bool standard = wasQualified && context.standardPath;
    NameRole role = std::exchange(context.nextName, NameRole::None);
    context.nextAngle = AngleRole::None;
    size_t next = SkipTrivia(line, end);
    bool qualifier = ScopeAt(line, next);
    bool turbofish = rust && qualifier && OpensAngle(line, SkipTrivia(line, next + 2));
    context.standardPath = !rust && qualifier && (standard || word == u"std");
    char16_t follow = At(line, next);
    if (rust && follow == u'!' && At(line, next + 1) == u'=')
        follow = u'=';
    Ink ink = rawIdentifier ? (follow == u'(' ? Ink::Function : Ink::Name) : WordInk(word, language, follow);
    bool parameterStart = AtParameterStart(context);

    if (!rawIdentifier && (word == u"true" || word == u"false" || (!rust && word == u"nullptr")))
        return Ink::Keyword;
    if (!rawIdentifier && rust && word == u"Self")
        return Ink::Type;
    if (rust && !rawIdentifier) {
        if (word == u"union" && follow && !NameStart(follow))
            ink = follow == u'(' ? Ink::Function : Ink::Name;
        if (word == u"raw" && (WordAt(line, next, u"const") || WordAt(line, next, u"mut")))
            return Ink::Keyword;
        if (word == u"safe" && (WordAt(line, next, u"fn") || WordAt(line, next, u"static")))
            return Ink::Keyword;
    }
    if (ink == Ink::Keyword || ink == Ink::Control || (!rawIdentifier && word == u"macro_rules" && follow == u'!')) {
        if (rust) {
            if (word == u"fn" || word == u"macro" || (word == u"macro_rules" && follow == u'!')) {
                context.nextName = NameRole::Function;
                context.rustHeader = word == u"fn";
            } else if (word == u"struct" || word == u"enum" || word == u"trait" || word == u"type" || word == u"union") {
                context.nextName = NameRole::RustItem;
                context.typeAlias = word == u"type";
                context.rustHeader = true;
            } else if (word == u"mod") {
                context.nextName = NameRole::Type;
            } else if (word == u"use" && !OpensAngle(line, next)) {
                context.rustImport = true;
            } else if (word == u"impl") {
                context.nextName = NameRole::Type;
                context.nextAngle = AngleRole::Parameters;
                context.rustHeader = true;
            } else if ((word == u"as" && !context.rustImport) || word == u"dyn") {
                context.nextName = NameRole::Type;
            } else if (word == u"const" && parameterStart) {
                context.nextName = NameRole::ValueParameter;
            } else if (word == u"mut" || word == u"const") {
                context.nextName = role;
            } else if (word == u"let" || word == u"where") {
                context.rustHeader = true;
            }
        } else if (word == u"template") {
            context.nextAngle = wasQualified || context.angles ? AngleRole::Arguments : AngleRole::Parameters;
        } else if (word == u"typename" || word == u"class" || word == u"struct" ||
                   word == u"enum" || word == u"union" || word == u"concept" || word == u"namespace") {
            context.nextName = parameterStart && (word == u"typename" || word == u"class") ?
                NameRole::TypeParameter : NameRole::Type;
            if (word == u"namespace")
                context.typeAlias = true;
        } else if (word == u"using") {
            context.typeAlias = true;
        } else if (word == u"auto" && parameterStart) {
            context.nextName = NameRole::ValueParameter;
        } else if ((word == u"const" || word == u"volatile") && parameterStart) {
            context.nextName = role;
        } else if (word == u"static_cast" || word == u"dynamic_cast" || word == u"reinterpret_cast" || word == u"const_cast") {
            context.nextAngle = AngleRole::Arguments;
        }
        if (!rust && (word == u"using" || word == u"operator" || word == u"new" || word == u"delete"))
            return Ink::Control;
        return ink;
    }

    if (role == NameRole::Function || role == NameRole::RustItem) {
        context.nextAngle = AngleRole::Parameters;
        return role == NameRole::Function ? Ink::Function : Ink::Type;
    }
    bool newTypeParameter = !qualifier && ((rust && parameterStart && role == NameRole::None) ||
                                          role == NameRole::TypeParameter);
    if (newTypeParameter || role == NameRole::ValueParameter) {
        ink = newTypeParameter ? Ink::Type : Ink::Name;
        context.parameters.push_back({std::u16string(word), context.braceDepth, ink});
        context.parameterStart = false;
        return ink;
    }

    auto parameter = std::find_if(context.parameters.rbegin(), context.parameters.rend(), [&](const GenericParameter &item) {
        return item.name == word;
    });
    bool knownParameter = parameter != context.parameters.rend();
    if (knownParameter)
        ink = parameter->ink;
    else if (role == NameRole::Type || role == NameRole::TypeParameter || (standard && StandardCppType(word)) ||
             (context.typeAlias && follow == u'=') || (qualifier && !turbofish))
        ink = Ink::Type;

    if (!rust && parameterStart && ink == Ink::Type && !qualifier && NameStart(follow))
        context.nextName = NameRole::ValueParameter;
    if (qualifier && (role == NameRole::Type || role == NameRole::TypeParameter))
        context.nextName = NameRole::Type;

    if (turbofish) {
        if (ink == Ink::Name)
            ink = Ink::Function;
    } else if (OpensAngle(line, next)) {
        if (ink == Ink::Type) {
            context.nextAngle = AngleRole::Arguments;
        } else if (!rust && !knownParameter && (next == end || wasQualified)) {
            size_t tail = AfterCppTemplateArguments(line, next);
            if (tail != Text::npos && (At(line, tail) == u'(' || ScopeAt(line, tail))) {
                ink = At(line, tail) == u'(' ? Ink::Function : Ink::Type;
                context.nextAngle = AngleRole::Arguments;
            }
        }
    } else if (!knownParameter && ink == Ink::Name && context.angles && !context.parameterList &&
               !context.argumentGroups && word.size() == 1 && word[0] >= u'A' && word[0] <= u'Z') {
        ink = Ink::Type;
    }

    // A use tree gives path segments and type names context. Its bare value imports use the foreground.
    if (context.rustImport && ink == Ink::Name)
        return Ink::Text;
    if (!rust && ink == Ink::Type && VocabularyFor(Language::Cpp).types.contains(word) &&
        word != u"size_t" && word != u"ptrdiff_t" && word != u"FILE")
        return Ink::Keyword;
    return ink;
}

static void ClearNameExpectation(NameContext &context)
{
    context.nextName = NameRole::None;
    context.nextAngle = AngleRole::None;
    context.qualified = false;
    context.standardPath = false;
}

static size_t NamePunctuation(Text line, size_t index, bool rust, NameContext &context)
{
    if (ScopeAt(line, index)) {
        context.qualified = true;
        context.nextAngle = rust ? AngleRole::Arguments : AngleRole::None;
        return index + 2;
    }
    char16_t ch = line[index];
    NameRole role = context.nextName;
    AngleRole angle = context.nextAngle;
    ClearNameExpectation(context);

    if (angle != AngleRole::None && OpensAngle(line, index) && !context.argumentGroups) {
        if (context.angles++ == 0) {
            context.parameterList = angle == AngleRole::Parameters;
            context.parameterStart = context.parameterList;
        }
        return index + 1;
    }
    if (context.angles) {
        if (ch == u'(' || ch == u'[' || ch == u'{') {
            ++context.argumentGroups;
            return index + 1;
        }
        if (context.argumentGroups) {
            if (ch == u')' || ch == u']' || ch == u'}')
                --context.argumentGroups;
            if (ch == u'&' || ch == u'*')
                context.nextName = role;
            return index + 1;
        }
        if (ch == u'>' && (!index || line[index - 1] != u'-') && At(line, index + 1) != u'=') {
            if (--context.angles == 0)
                context.parameterList = context.parameterStart = false;
            return index + 1;
        }
        if (ch == u',' && context.angles == 1 && context.parameterList)
            context.parameterStart = true;
        if (ch == u';' || ch == u'}') {
            context.angles = 0;
            context.parameterList = context.parameterStart = false;
        }
    }

    if (rust && ch == u'-' && At(line, index + 1) == u'>') {
        context.nextName = NameRole::Type;
        return index + 2;
    }
    if (context.rustHeader || !context.parameters.empty() || context.groups) {
        if (ch == u'(' || ch == u'[')
            ++context.groups;
        else if (context.groups && (ch == u')' || ch == u']'))
            --context.groups;
    }
    if (rust && ch == u':' && (context.rustHeader || context.parameterList))
        context.nextName = NameRole::Type;
    if (ch == u'&' || ch == u'*' || ch == u'.' || (rust && ch == u'!' && role == NameRole::Function))
        context.nextName = role;
    if (context.groups)
        return index + 1;
    if (ch == u'=' && !context.angles) {
        context.rustHeader = false;
        if (std::exchange(context.typeAlias, false))
            context.nextName = NameRole::Type;
    }
    if (ch == u'{') {
        context.rustHeader = context.typeAlias = false;
        if (!context.parameters.empty())
            ++context.braceDepth;
    } else if (ch == u'}' || ch == u';') {
        if (ch == u'}' && context.braceDepth)
            --context.braceDepth;
        while (!context.parameters.empty() && context.parameters.back().braceDepth >= context.braceDepth)
            context.parameters.pop_back();
        if (context.parameters.empty())
            context.braceDepth = 0;
        context.rustHeader = context.typeAlias = false;
        if (ch == u';')
            context.rustImport = false;
    }
    return index + 1;
}

static size_t NumberEnd(Text line, size_t start)
{
    size_t index = start;
    bool hex = At(line, start) == u'0' &&
               (At(line, start + 1) == u'x' || At(line, start + 1) == u'X');
    if (hex)
        index += 2;

    while (index < line.size()) {
        char16_t ch = line[index];
        char16_t next = At(line, index + 1);
        bool hexDigit = (next >= u'a' && next <= u'f') || (next >= u'A' && next <= u'F');
        if (ch == u'.' && next != u'.' && (Digit(next) || !NameStart(next) || (hex && hexDigit))) {
            ++index;
        } else if ((hex ? ch == u'p' || ch == u'P' : ch == u'e' || ch == u'E') &&
                   (next == u'+' || next == u'-') && Digit(At(line, index + 2))) {
            index += 2;
        } else if (NamePart(ch) || (ch == u'\'' && (Digit(next) || (hex && hexDigit)))) {
            ++index;
        } else {
            break;
        }
    }
    return index;
}

static size_t GMLHexEnd(Text line, size_t start)
{
    if (!HexDigit(At(line, start + 1)))
        return start;
    size_t end = start + 1, digits = 0;
    for (char16_t ch = At(line, end); HexDigit(ch) || ch == u'_'; ch = At(line, ++end))
        digits += HexDigit(ch);
    if (NamePart(At(line, end)) || (line[start] == u'#' && digits != 6))
        return start;
    return end;
}

static size_t OdinNumberEnd(Text line, size_t start)
{
    size_t index = start;
    auto digits = [&](int base) {
        for (char16_t ch = At(line, index); ch == u'_' || HexDigit(ch); ch = At(line, ++index)) {
            int digit = Digit(ch) ? ch - u'0' : Lower(ch) - u'a' + 10;
            if (ch != u'_' && digit >= base)
                break;
        }
    };
    if (At(line, index) == u'0') {
        int base = 0;
        switch (At(line, index + 1)) {
            case u'b': base = 2; break;
            case u'o': base = 8; break;
            case u'd': base = 10; break;
            case u'z': base = 12; break;
            case u'h': case u'x': base = 16; break;
        }
        if (base) {
            index += 2;
            digits(base);
            return index;
        }
    }
    digits(10);
    if (At(line, index) == u'.' && At(line, index + 1) != u'.') {
        ++index;
        digits(10);
    }
    char16_t suffix = At(line, index);
    if (suffix == u'e' || suffix == u'E') {
        ++index;
        if (At(line, index) == u'+' || At(line, index) == u'-')
            ++index;
        digits(10);
        suffix = At(line, index);
    }
    return index + (suffix == u'i' || suffix == u'j' || suffix == u'k');
}

static void SetToken(LexState &state, LexMode mode = LexMode::Code, std::u16string closing = {},
                     bool multiline = false, bool highlightEscapes = true)
{
    state.mode = mode;
    state.depth = 0;
    state.closing = std::move(closing);
    state.multiline = multiline;
    state.highlightEscapes = highlightEscapes;
    state.doubledQuote = false;
    state.stringOpening = 0;
    state.stringInk = Ink::String;
    state.interpolation = Interpolation::None;
}

static bool Shell(Language language)
{
    return language == Language::Bash || language == Language::Zsh || language == Language::Fish;
}

static bool LuaFamily(Language language)
{
    return language == Language::Lua || language == Language::Luau;
}

static size_t ReadName(Text line, size_t index)
{
    while (NamePart(At(line, index)))
        ++index;
    return index;
}

static size_t ReadRubyName(Text line, size_t index)
{
    size_t end = ReadName(line, index);
    char16_t suffix = At(line, end);
    if (suffix == u'?' || (suffix == u'!' && At(line, end + 1) != u'='))
        ++end;
    return end;
}

static bool ClojureNamePart(char16_t ch)
{
    return NamePart(ch) || Text(u".*+!-?$%&=<>#/:'").find(ch) != Text::npos;
}

static bool JavaTypeModifierContext(Text line, size_t start, size_t end)
{
    size_t next = SkipTrivia(line, end);
    // Keep subtraction such as 'non-sealed' in an expression as separate tokens.
    static constexpr Text modifiers[] = {u"abstract", u"public", u"protected", u"private", u"static", u"strictfp"};
    if (next < line.size()) {
        return At(line, next) == u'@' || WordAt(line, next, u"class") || WordAt(line, next, u"interface") ||
               std::ranges::any_of(modifiers, [&](Text word) { return WordAt(line, next, word); });
    }
    for (size_t at = SkipTrivia(line, 0); at < start;) {
        size_t nameEnd = ReadName(line, at);
        auto modifier = line.substr(at, nameEnd - at);
        if (std::ranges::find(modifiers, modifier) == std::end(modifiers))
            return false;
        at = SkipTrivia(line, nameEnd);
    }
    return true;
}

static size_t LongBracket(Text line, size_t start, LexState &state, LexMode mode)
{
    if (At(line, start) != u'[')
        return start;
    size_t at = start + 1;
    while (At(line, at) == u'=')
        ++at;
    if (At(line, at) != u'[')
        return start;
    SetToken(state, mode, u"]", true);
    state.closing.append(at - start - 1, u'=');
    state.closing.push_back(u']');
    state.depth = 1;
    return at + 1;
}

static size_t QuotedEnd(Text line, size_t body, char16_t quote, bool doubled = false)
{
    for (size_t at = body; at < line.size(); ++at) {
        if (line[at] == u'\\' && !doubled) {
            ++at;
        } else if (line[at] == quote) {
            if (doubled && At(line, at + 1) == quote)
                ++at;
            else
                return at + 1;
        }
    }
    return body;
}

static size_t PercentString(Text line, size_t start, Language language, LexState &state)
{
    size_t at = start + 1;
    char16_t style = At(line, at);
    if (language == Language::Elixir || Text(u"qQwWiIrsx").find(style) != Text::npos)
        ++at;
    char16_t open = At(line, at), close = open;
    switch (open) {
        case u'(': close = u')'; break;
        case u'[': close = u']'; break;
        case u'{': close = u'}'; break;
        case u'<': close = u'>'; break;
        case u'|': case u'/': case u'"': case u'\'': break;
        default: return start;
    }
    bool raw = language == Language::Elixir ? style >= u'A' && style <= u'Z' :
        style == u'q' || style == u'w' || style == u'i' || style == u's';
    size_t count = (open == u'"' || open == u'\'') && At(line, at + 1) == open && At(line, at + 2) == open ? 3 : 1;
    SetToken(state, raw ? LexMode::Raw : LexMode::Quoted, std::u16string(count, close), true);
    if (!raw)
        state.interpolation = Interpolation::Hash;
    if (count == 1 && open != close) {
        state.depth = 1;
        state.stringOpening = open;
    }
    return at + count;
}

static size_t BeginQuoted(Text line, size_t start, Language language, LexState &state, bool expectsValue)
{
    size_t quoteAt = start;
    const char16_t ch = At(line, start);
    Text rest = line.substr(start);
    bool raw = false;
    bool doubled = false;
    bool multiline = false;
    size_t minimumQuotes = 1;
    size_t hashes = 0;
    Interpolation interpolation = Interpolation::None;

    if (CFamily(language)) {
        if (rest.starts_with(u"u8"))
            quoteAt += 2;
        else if (ch == u'u' || ch == u'U' || ch == u'L' ||
                 ((language == Language::ObjectiveC || language == Language::ObjectiveCpp) && ch == u'@'))
            ++quoteAt;

        if ((language == Language::Cpp || language == Language::ObjectiveCpp) && line.substr(quoteAt).starts_with(u"R\"")) {
            size_t delimiter = quoteAt + 2;
            size_t end = delimiter;
            while (end - delimiter <= 16 && end < line.size() &&
                   !Space(line[end]) && line[end] != u'(' && line[end] != u')' && line[end] != u'\\')
                ++end;
            if (end - delimiter <= 16 && At(line, end) == u'(') {
                SetToken(state, LexMode::Raw, u")", true);
                state.closing.append(line.substr(delimiter, end - delimiter));
                state.closing.push_back(u'"');
                return end + 1;
            }
            return start;
        }
    } else if (language == Language::Python) {
        while (quoteAt - start < 2 && At(line, quoteAt) && Text(u"rRbBuUfF").find(At(line, quoteAt)) != Text::npos)
            ++quoteAt;
        Text prefix = line.substr(start, quoteAt - start);
        if (prefix.find_first_of(u"fF") != Text::npos)
            interpolation = Interpolation::Braces;
    } else if (language == Language::GML) {
        char16_t next = At(line, start + 1);
        if (ch == u'@' && (next == u'"' || next == u'\'')) {
            raw = multiline = true;
            ++quoteAt;
        } else if (ch == u'$' && next == u'"') {
            interpolation = Interpolation::Braces;
            ++quoteAt;
        } else if (ch != u'"') {
            return start;
        }
    } else if (language == Language::Rust) {
        if (ch == u'b' || ch == u'c')
            ++quoteAt;
        if (At(line, quoteAt) == u'r') {
            size_t hash = ++quoteAt;
            while (At(line, quoteAt) == u'#')
                ++quoteAt;
            if (At(line, quoteAt) == u'"' && quoteAt - hash <= 255) {
                SetToken(state, LexMode::Raw, u"\"", true);
                state.closing.append(quoteAt - hash, u'#');
                return quoteAt + 1;
            }
            return start;
        }
    } else if (language == Language::CSharp) {
        size_t dollars = 0;
        while (At(line, quoteAt) == u'$') {
            ++quoteAt;
            ++dollars;
        }
        if (At(line, quoteAt) == u'@') {
            raw = doubled = multiline = true;
            ++quoteAt;
            if (!dollars && At(line, quoteAt) == u'$') {
                ++quoteAt;
                ++dollars;
            }
        }
        if (dollars)
            interpolation = Interpolation::Braces;
        if (!doubled && line.substr(quoteAt).starts_with(u"\"\"\"")) {
            minimumQuotes = 3;
            while (At(line, quoteAt + minimumQuotes) == u'"')
                ++minimumQuotes;
            if (minimumQuotes >= 6 && minimumQuotes % 2 == 0)
                minimumQuotes /= 2; // An empty raw string can put both delimiters together.
            raw = multiline = true;
            if (dollars > 1)
                interpolation = Interpolation::None;
        }
    } else if (language == Language::Swift) {
        while (At(line, quoteAt) == u'#')
            ++quoteAt;
        hashes = quoteAt - start;
        raw = hashes != 0;
        interpolation = Interpolation::Swift;
    } else if (language == Language::Dart && (ch == u'r' || ch == u'R')) {
        ++quoteAt;
        raw = true;
    } else if (language == Language::Scala && (rest.starts_with(u"s\"") || rest.starts_with(u"f\"") ||
                                                 rest.starts_with(u"raw\""))) {
        raw = ch == u'r';
        quoteAt += raw ? 3 : 1;
        interpolation = Interpolation::Dollar;
    } else if ((language == Language::Bash || language == Language::Zsh) && rest.starts_with(u"$'")) {
        ++quoteAt;
    } else if (LuaFamily(language) && ch == u'[') {
        return LongBracket(line, start, state, LexMode::Raw);
    } else if ((language == Language::Ruby && ch == u'%' && expectsValue) ||
               (language == Language::Elixir && ch == u'~' && NameStart(At(line, start + 1)))) {
        return PercentString(line, start, language, state);
    } else if (language == Language::SQL && ch == u'$') {
        size_t at = start + 1;
        if (!Digit(At(line, at))) {
            while (At(line, at) != u'$' && NamePart(At(line, at)))
                ++at;
        }
        if (At(line, at) == u'$') {
            SetToken(state, LexMode::Raw, std::u16string(line.substr(start, at - start + 1)), true);
            return at + 1;
        }
    } else if (language == Language::PowerShell && (rest.starts_with(u"@\"") || rest.starts_with(u"@'"))) {
        char16_t quote = At(line, start + 1);
        SetToken(state, LexMode::Raw, std::u16string{quote, u'@'}, true);
        if (quote == u'"')
            state.interpolation = Interpolation::Dollar;
        return start + 2;
    }

    char16_t quote = At(line, quoteAt);
    if (quote == u'`') {
        if (JavaScriptFamily(language) || language == Language::Luau || Shell(language)) {
            SetToken(state, LexMode::Quoted, u"`", true);
            state.interpolation = language == Language::Luau ? Interpolation::Braces : Interpolation::Dollar;
            return quoteAt + 1;
        }
        if (language == Language::Go || language == Language::Odin || language == Language::SQL || language == Language::R) {
            SetToken(state, LexMode::Raw, u"`", language != Language::R);
            if (language == Language::SQL || language == Language::R)
                state.stringInk = Ink::Name;
            return quoteAt + 1;
        }
        return start;
    }
    if (quote != u'\'' && quote != u'"')
        return start;
    if ((language == Language::JSON || language == Language::JSONC || language == Language::Swift ||
         language == Language::VisualBasic || language == Language::Clojure) && quote == u'\'')
        return start;
    if (language == Language::Rust && quote == u'\'' && NameStart(At(line, quoteAt + 1))) {
        char16_t first = At(line, quoteAt + 1);
        size_t width = first >= 0xD800 && first <= 0xDBFF ? 2 : 1;
        if (At(line, quoteAt + 1 + width) != u'\'')
            return start; // Let the identifier scanner read the lifetime.
    }

    bool triple = (quote == u'"' && (language == Language::Java || language == Language::Kotlin ||
        language == Language::Swift || language == Language::Scala || language == Language::Julia)) ||
        language == Language::Python || language == Language::Dart || language == Language::TOML ||
        language == Language::Groovy || language == Language::Elixir || language == Language::FSharp;
    if (minimumQuotes == 1 && triple && At(line, quoteAt + 1) == quote && At(line, quoteAt + 2) == quote)
        minimumQuotes = 3;
    if (minimumQuotes > 1)
        multiline = true;
    if ((language == Language::Kotlin || language == Language::Scala || language == Language::FSharp) && minimumQuotes == 3)
        raw = true;

    if (quote == u'"') {
        if (language == Language::Ruby || language == Language::Elixir)
            interpolation = Interpolation::Hash;
        if ((!raw && (language == Language::Dart || language == Language::PHP)) || language == Language::Kotlin ||
            language == Language::Groovy || language == Language::PowerShell || language == Language::CMake || Shell(language))
            interpolation = Interpolation::Dollar;
    } else if (language == Language::Dart && !raw) {
        interpolation = Interpolation::Dollar;
    }

    if (language == Language::SQL || language == Language::VisualBasic ||
        (language == Language::YAML && quote == u'\'')) {
        raw = doubled = true;
        multiline = language != Language::VisualBasic;
    }
    if (quote == u'\'' && ((Shell(language) && quoteAt == start) ||
                           language == Language::TOML || language == Language::PowerShell))
        raw = true;
    if (language == Language::PowerShell && quote == u'\'')
        doubled = true;
    if (Shell(language) || language == Language::Ruby || language == Language::PHP || language == Language::Perl ||
        language == Language::YAML || language == Language::CMake || (language == Language::Rust && quote == u'"'))
        multiline = true;

    bool pythonRaw = language == Language::Python && line.substr(start, quoteAt - start).find_first_of(u"rR") != Text::npos;
    SetToken(state, raw ? LexMode::Raw : LexMode::Quoted, std::u16string(minimumQuotes, quote), multiline, !pythonRaw);
    state.closing.append(hashes, u'#');
    state.doubledQuote = doubled;
    state.interpolation = interpolation;
    if (language == Language::SQL && quote == u'"')
        state.stringInk = Ink::Name;
    return quoteAt + minimumQuotes;
}

static size_t EscapeEnd(Text line, size_t start, Language language)
{
    char16_t kind = At(line, start + 1);
    size_t end = std::min(start + 2, line.size());
    if (kind >= 0xD800 && kind <= 0xDBFF && At(line, end) >= 0xDC00 && At(line, end) <= 0xDFFF)
        return end + 1;
    if (language == Language::CommonLisp)
        return end;

    if (kind == u'u' && (language == Language::Rust || JavaScriptFamily(language)) &&
        At(line, end) == u'{') {
        ++end;
        while (HexDigit(At(line, end)) || (language == Language::Rust && At(line, end) == u'_'))
            ++end;
        return end + (At(line, end) == u'}');
    }
    if (kind == u'N' && language == Language::Python && At(line, end) == u'{') {
        ++end;
        while (NamePart(At(line, end)) || At(line, end) == u' ' || At(line, end) == u'-')
            ++end;
        return end + (At(line, end) == u'}');
    }
    if (kind >= u'0' && kind <= u'7' && language != Language::Rust) {
        while (end - start < 4 && At(line, end) >= u'0' && At(line, end) <= u'7')
            ++end;
        return end;
    }

    bool cFamily = CFamily(language);
    size_t digits = 0;
    if (kind == u'x')
        digits = cFamily ? line.size() - end : 2;
    else if (kind == u'u' && language != Language::Rust)
        digits = 4;
    else if (kind == u'U' && (cFamily || language == Language::Python || language == Language::Odin))
        digits = 8;
    while (digits && HexDigit(At(line, end))) {
        ++end;
        --digits;
    }
    return end;
}

static size_t InterpolationMarker(Text line, size_t index, Language language, const LexState &state)
{
    switch (state.interpolation) {
        case Interpolation::None: return 0;
        case Interpolation::Dollar: return line.substr(index).starts_with(u"${") ? 2 : 0;
        case Interpolation::Hash: return line.substr(index).starts_with(u"#{") ? 2 : 0;
        case Interpolation::Braces:
            return At(line, index) == u'{' &&
                ((language != Language::CSharp && language != Language::Python) || At(line, index + 1) != u'{') ? 1 : 0;
        case Interpolation::Swift: {
            if (At(line, index) != u'\\')
                return 0;
            size_t quote = state.closing.find(u'#');
            size_t hashes = quote == Text::npos ? 0 : state.closing.size() - quote;
            size_t at = index + 1;
            for (size_t i = 0; i < hashes; ++i, ++at) {
                if (At(line, at) != u'#')
                    return 0;
            }
            return At(line, at) == u'(' ? at - index + 1 : 0;
        }
    }
    return 0;
}

static bool InterpolatesVariable(Language language)
{
    return Shell(language) || language == Language::Kotlin || language == Language::Dart ||
           language == Language::PHP || language == Language::Scala || language == Language::Groovy ||
           language == Language::PowerShell;
}

static size_t VariableEnd(Text line, size_t start)
{
    char16_t ch = At(line, start + 1);
    if (NamePart(ch) && ch != u'$')
        return ReadName(line, start + 1);
    if (ch && Text(u"?@!#*$-").find(ch) != Text::npos)
        return start + 2;
    return start;
}

static size_t ContinueString(Text line, size_t start, size_t index, Language language,
                             LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    bool continued = false;
    Ink stringInk = state.stringInk;
    while (index < line.size()) {
        if (line.substr(index).starts_with(state.closing)) {
            if (state.doubledQuote && line.substr(index + state.closing.size()).starts_with(state.closing)) {
                index += 2 * state.closing.size();
                continue;
            }
            index += state.closing.size();
            if (state.stringOpening && --state.depth)
                continue;
            SetToken(state);
            break;
        }
        if (state.interpolation == Interpolation::Braces &&
            (language == Language::CSharp || language == Language::Python) && line.substr(index).starts_with(u"{{")) {
            index += 2;
            continue;
        }
        if (size_t marker = InterpolationMarker(line, index, language, state)) {
            size_t delimiter = index + marker - 1;
            if (delimiter > start)
                tokens.push_back({start, delimiter - start, stringInk, true});
            state.interpolations.push_back({std::move(state.closing), state.mode, state.interpolation, stringInk, 1,
                                            state.depth, state.stringOpening, state.multiline,
                                            state.highlightEscapes, state.doubledQuote});
            SetToken(state);
            return index + marker;
        }
        if (state.interpolation == Interpolation::Dollar && line[index] == u'$' && InterpolatesVariable(language)) {
            size_t end = VariableEnd(line, index);
            if (end != index) {
                if (index > start)
                    tokens.push_back({start, index - start, stringInk, true});
                tokens.push_back({index, end - index, Ink::Escape, true});
                start = index = end;
                continue;
            }
        }
        bool escape = state.mode == LexMode::Quoted &&
            (language == Language::PowerShell ? line[index] == u'`' : line[index] == u'\\');
        if (escape) {
            continued = index + 1 == line.size() && language != Language::Odin && language != Language::GML;
            if (state.highlightEscapes) {
                size_t end = language == Language::PowerShell ? std::min(index + 2, line.size()) :
                    EscapeEnd(line, index, language);
                if (index > start)
                    tokens.push_back({start, index - start, stringInk, true});
                tokens.push_back({index, end - index, Ink::Escape, true});
                start = index = end;
            } else {
                index = std::min(index + 2, line.size());
            }
        } else {
            if (state.stringOpening && line[index] == state.stringOpening)
                ++state.depth;
            ++index;
        }
    }
    if (index > start)
        tokens.push_back({start, index - start, stringInk, true});
    if (finishLine && !state.multiline && !continued)
        SetToken(state);
    return index;
}

static void StringPunctuation(char16_t ch, LexState &state)
{
    if (state.interpolations.empty())
        return;
    auto &frame = state.interpolations.back();
    bool swift = frame.kind == Interpolation::Swift;
    if (ch == (swift ? u'(' : u'{')) {
        ++frame.depth;
    } else if (ch == (swift ? u')' : u'}') && --frame.depth == 0) {
        SetToken(state, frame.mode, std::move(frame.closing), frame.multiline, frame.highlightEscapes);
        state.stringInk = frame.ink;
        state.interpolation = frame.kind;
        state.doubledQuote = frame.doubledQuote;
        state.stringOpening = frame.stringOpening;
        state.depth = frame.stringNesting;
        state.interpolations.pop_back();
    }
}

static size_t ContinueComment(Text line, size_t index, Language language, LexState &state, bool finishLine)
{
    if (state.mode == LexMode::LineComment) {
        if (finishLine && (!CFamily(language) || !line.ends_with(u"\\")))
            SetToken(state);
        return line.size();
    }
    const auto &comments = InfoForLanguage(language).comments;
    Text close = state.closing.empty() ? comments.close : Text(state.closing);
    if (close.empty()) {
        SetToken(state);
        return line.size();
    }
    while (index < line.size()) {
        if (line.substr(index).starts_with(close)) {
            index += close.size();
            if (--state.depth == 0) {
                SetToken(state);
                break;
            }
        } else if (comments.nested && !comments.open.empty() && line.substr(index).starts_with(comments.open)) {
            ++state.depth;
            index += comments.open.size();
        } else {
            ++index;
        }
    }
    return index;
}

static size_t RegexEnd(Text line, size_t start)
{
    bool inClass = false;
    for (size_t index = start + 1; index < line.size(); ++index) {
        switch (line[index]) {
            case u'\\': ++index; break;
            case u'[': inClass = true; break;
            case u']': inClass = false; break;
            case u'/':
                if (!inClass) {
                    ++index;
                    while (NamePart(At(line, index)))
                        ++index;
                    return index;
                }
                break;
            default: break;
        }
    }
    return start;
}

static size_t BeginRustAttribute(Text line, size_t hash, RustAttribute &attribute, std::vector<Token> &tokens)
{
    size_t marker = SkipSpace(line, hash + 1);
    bool inner = At(line, marker) == u'!';
    size_t bracket = inner ? SkipSpace(line, marker + 1) : marker;
    if (At(line, bracket) != u'[')
        return hash;

    tokens.push_back({hash, 1, Ink::Directive});
    if (inner)
        tokens.push_back({marker, 1, Ink::Directive});
    attribute.brackets = 1;
    attribute.part = RustAttributePart::Name;
    return bracket + 1;
}

static bool IsBuiltinRustAttribute(Text word)
{
    // Built-in names are sorted for lookup without allocating a table.
    static constexpr Text names[] = {
        u"allow", u"automatically_derived", u"bench", u"cfg", u"cfg_attr", u"cold", u"collapse_debuginfo",
        u"crate_name", u"crate_type", u"debugger_visualizer", u"deny", u"deprecated", u"derive", u"doc",
        u"expect", u"export_name", u"feature", u"forbid", u"global_allocator", u"ignore", u"inline",
        u"instruction_set", u"link", u"link_name", u"link_ordinal", u"link_section", u"macro_export",
        u"macro_use", u"must_use", u"naked", u"no_builtins", u"no_implicit_prelude", u"no_link", u"no_main",
        u"no_mangle", u"no_std", u"non_exhaustive", u"panic_handler", u"path", u"proc_macro",
        u"proc_macro_attribute", u"proc_macro_derive", u"recursion_limit", u"repr", u"should_panic",
        u"target_feature", u"test", u"track_caller", u"type_length_limit", u"used", u"warn", u"windows_subsystem",
    };
    static_assert(std::ranges::is_sorted(names));
    return std::ranges::binary_search(names, word);
}

static Ink RustAttributeWordInk(Text line, Text word, size_t end, bool raw, RustAttribute &attribute)
{
    auto part = std::exchange(attribute.part, RustAttributePart::Arguments);
    size_t next = SkipTrivia(line, end);
    bool qualified = ScopeAt(line, next);
    if (part == RustAttributePart::Name) {
        if (qualified && word == u"diagnostic") {
            attribute.part = RustAttributePart::DiagnosticName;
            return Ink::Directive;
        }
        if (!qualified && !raw && word == u"unsafe") {
            attribute.part = RustAttributePart::Unsafe;
            return Ink::Keyword;
        }
        if (!qualified && IsBuiltinRustAttribute(word)) {
            if (word == u"cfg_attr")
                attribute.part = RustAttributePart::Conditional;
            return Ink::Directive;
        }
    } else if (part == RustAttributePart::DiagnosticName && !qualified &&
               (word == u"on_unimplemented" || word == u"do_not_recommend")) {
        return Ink::Directive;
    }

    char16_t follow = At(line, next);
    if (follow == u'!' && At(line, next + 1) == u'=')
        follow = u'=';
    if (!raw && (word == u"true" || word == u"false"))
        return Ink::Keyword;
    if (!raw && word == u"Self")
        return Ink::Type;
    Ink ink = raw ? (follow == u'(' ? Ink::Function : Ink::Name) : WordInk(word, Language::Rust, follow);
    return qualified && ink == Ink::Name ? Ink::Type : ink;
}

static void RustAttributePunctuation(char16_t ch, RustAttribute &attribute)
{
    if (ch == u':' && attribute.part == RustAttributePart::DiagnosticName)
        return;
    auto part = std::exchange(attribute.part, RustAttributePart::Arguments);
    switch (ch) {
        case u'(':
            ++attribute.groups;
            if (part == RustAttributePart::Conditional)
                attribute.conditionalGroups.push_back(attribute.groups);
            else if (part == RustAttributePart::Unsafe)
                attribute.part = RustAttributePart::Name;
            break;
        case u'[':
            ++attribute.brackets;
            ++attribute.groups;
            break;
        case u'{':
            ++attribute.groups;
            break;
        case u']':
            if (--attribute.brackets == 0) {
                attribute.conditionalGroups.clear();
                attribute.groups = 0;
                break;
            }
            [[fallthrough]];
        case u')':
        case u'}':
            if (!attribute.conditionalGroups.empty() && attribute.groups == attribute.conditionalGroups.back())
                attribute.conditionalGroups.pop_back();
            if (attribute.groups)
                --attribute.groups;
            break;
        case u',':
            // Only commas at the cfg_attr argument level introduce another attribute.
            if (!attribute.conditionalGroups.empty() && attribute.groups == attribute.conditionalGroups.back())
                attribute.part = RustAttributePart::Name;
            break;
    }
}

static bool MarkupMode(LexMode mode)
{
    return mode == LexMode::MarkupText || mode == LexMode::MarkupTag || mode == LexMode::MarkupString;
}

static size_t MarkupNameEnd(Text line, size_t at)
{
    while (NamePart(At(line, at)) || At(line, at) == u'-' || At(line, at) == u':' || At(line, at) == u'.')
        ++at;
    return at;
}

static size_t EntityEnd(Text line, size_t start)
{
    size_t at = start + 1;
    if (At(line, at) == u'#')
        ++at;
    size_t end = ReadName(line, at);
    return end > at && At(line, end) == u';' ? end + 1 : start;
}

static void MarkupTextTokens(Text line, size_t first, size_t last, Ink ink, std::vector<Token> &tokens)
{
    for (size_t at = first; at < last; ++at) {
        if (line[at] != u'&')
            continue;
        size_t entity = EntityEnd(line.substr(0, last), at);
        if (entity == at)
            continue;
        if (at > first)
            tokens.push_back({first, at - first, ink, true});
        tokens.push_back({at, entity - at, Ink::Escape, true});
        first = entity;
        at = entity - 1;
    }
    if (last > first)
        tokens.push_back({first, last - first, ink, true});
}

static bool JSXLanguage(Language language)
{
    return language == Language::JSX || language == Language::TSX;
}

static void StartMarkupTag(LexState &state, bool endTag)
{
    state.mode = LexMode::MarkupTag;
    state.markup.part = TagPart::Name;
    state.markup.endTag = endTag;
    state.markup.valueIsLanguage = false;
    state.markup.elementLanguage = Language::Plain;
    state.markup.rawElement = RawElement::None;
}

static void EndMarkupTag(LexState &state, Language language, bool empty)
{
    auto &markup = state.markup;
    if (JSXLanguage(language)) {
        if (markup.endTag) {
            if (markup.depth)
                --markup.depth;
        } else if (!empty) {
            ++markup.depth;
        }
        if (!markup.roots.empty() && markup.depth == markup.roots.back()) {
            markup.roots.pop_back();
            state.mode = LexMode::Code;
            return;
        }
    } else if (!empty && !markup.endTag && markup.rawElement != RawElement::None) {
        markup.rawContent = true;
        state.embedded = markup.elementLanguage;
        state.mode = LexMode::Code;
        return;
    }
    state.mode = LexMode::MarkupText;
}

static void MarkupLanguage(Text value, MarkupState &markup)
{
    if (!markup.valueIsLanguage || markup.rawElement == RawElement::None)
        return;
    if (value == u"application/ld+json" || value == u"application/json" || value == u"importmap")
        markup.elementLanguage = Language::JSON;
    else if (value == u"ts" || value == u"typescript")
        markup.elementLanguage = Language::TypeScript;
    else if (value == u"scss")
        markup.elementLanguage = Language::SCSS;
    else if (value == u"less")
        markup.elementLanguage = Language::Less;
    else if (!(value.empty() || value == u"text/javascript" || value == u"application/javascript" ||
               value == u"module" || value == u"js" || value == u"javascript" || value == u"text/css" || value == u"css"))
        markup.elementLanguage = Language::Plain;
}

static size_t PHPTag(Text rest)
{
    if (StartsIgnoringCase(rest, u"<?php") && (rest.size() == 5 || Space(At(rest, 5))))
        return 5;
    return rest.starts_with(u"<?=") ? 3 : 0;
}

static size_t MarkupStep(Text line, size_t index, Language language, LexState &state, std::vector<Token> &tokens)
{
    const size_t start = index;
    Text rest = line.substr(index);
    char16_t ch = line[index];
    auto &markup = state.markup;
    bool jsx = JSXLanguage(language);

    if (state.mode == LexMode::BlockComment || state.mode == LexMode::Raw) {
        bool comment = state.mode == LexMode::BlockComment;
        size_t end = line.find(state.closing, index);
        index = end == Text::npos ? line.size() : end + state.closing.size();
        if (end != Text::npos)
            SetToken(state, LexMode::MarkupText);
        tokens.push_back({start, index - start, comment ? Ink::Comment : Ink::String, true});
        return index;
    }
    if (state.mode == LexMode::MarkupString) {
        size_t end = line.find(state.closing, index);
        index = end == Text::npos ? line.size() : end + 1;
        if (end != Text::npos) {
            MarkupLanguage(line.substr(start, end - start), markup);
            SetToken(state, LexMode::MarkupTag);
            markup.part = TagPart::Attribute;
        }
        MarkupTextTokens(line, start, index, Ink::String, tokens);
        return index;
    }

    if (jsx && ch == u'{') {
        markup.expressions.push_back({state.mode, markup.part, markup.endTag, state.interpolations.size()});
        state.mode = LexMode::Code;
        return index + 1;
    }

    if (state.mode == LexMode::MarkupText) {
        if (!jsx && rest.starts_with(u"<!--")) {
            SetToken(state, LexMode::BlockComment, u"-->", true);
            size_t end = line.find(u"-->", index + 4);
            if (end != Text::npos)
                SetToken(state, LexMode::MarkupText);
            index = end == Text::npos ? line.size() : end + 3;
            tokens.push_back({start, index - start, Ink::Comment, true});
            return index;
        }
        if (!jsx && rest.starts_with(u"<![CDATA[")) {
            SetToken(state, LexMode::Raw, u"]]>", true);
            size_t end = line.find(u"]]>", index + 9);
            if (end != Text::npos)
                SetToken(state, LexMode::MarkupText);
            index = end == Text::npos ? line.size() : end + 3;
            tokens.push_back({start, index - start, Ink::String, true});
            return index;
        }
        if (language == Language::PHP) {
            if (size_t length = PHPTag(rest)) {
                SetToken(state);
                tokens.push_back({index, length, Ink::Directive, true});
                return index + length;
            }
        }
        bool endTag = rest.starts_with(u"</");
        size_t name = index + (endTag ? 2 : 1);
        if (ch == u'<' && (NameStart(At(line, name)) || (jsx && At(line, name) == u'>') ||
                            (!jsx && (At(line, name) == u'!' || At(line, name) == u'?')))) {
            if (At(line, name) == u'!' || At(line, name) == u'?')
                ++name;
            StartMarkupTag(state, endTag);
            tokens.push_back({index, name - index, Ink::Keyword, true});
            return name;
        }
        do {
            ++index;
        } while (index < line.size() && line[index] != u'<' && (!jsx || line[index] != u'{'));
        MarkupTextTokens(line, start, index, Ink::Text, tokens);
        return index;
    }

    if (ch == u'>' || rest.starts_with(u"/>") || rest.starts_with(u"?>")) {
        index += ch == u'>' ? 1 : 2;
        EndMarkupTag(state, language, ch == u'/');
        tokens.push_back({start, index - start, Ink::Keyword, true});
        return index;
    }
    if (Space(ch))
        return SkipSpace(line, index + 1);
    if (markup.part == TagPart::Name) {
        index = MarkupNameEnd(line, index);
        if (index == start)
            return start + 1;
        Text name = line.substr(start, index - start);
        if ((language == Language::HTML || language == Language::PHP) && !markup.endTag) {
            if (name.size() == 6 && StartsIgnoringCase(name, u"script")) {
                markup.elementLanguage = Language::JavaScript;
                markup.rawElement = RawElement::Script;
            } else if (name.size() == 5 && StartsIgnoringCase(name, u"style")) {
                markup.elementLanguage = Language::CSS;
                markup.rawElement = RawElement::Style;
            }
        }
        markup.part = TagPart::Attribute;
        tokens.push_back({start, index - start, Ink::Type});
        return index;
    }
    if (markup.part == TagPart::Value) {
        if (ch == u'"' || ch == u'\'') {
            size_t end = line.find(ch, index + 1);
            index = end == Text::npos ? line.size() : end + 1;
            if (end == Text::npos)
                SetToken(state, LexMode::MarkupString, std::u16string(1, ch), true);
            else {
                MarkupLanguage(line.substr(start + 1, end - start - 1), markup);
                markup.part = TagPart::Attribute;
            }
        } else {
            while (index < line.size() && !Space(line[index]) && !line.substr(index).starts_with(u"/>") &&
                   line[index] != u'>')
                ++index;
            MarkupLanguage(line.substr(start, index - start), markup);
            markup.part = TagPart::Attribute;
        }
        MarkupTextTokens(line, start, index, Ink::String, tokens);
        return index;
    }
    if (ch == u'=') {
        markup.part = TagPart::Value;
        return index + 1;
    }
    index = MarkupNameEnd(line, index);
    if (index == start)
        return start + 1;
    Text attribute = line.substr(start, index - start);
    markup.valueIsLanguage = (attribute.size() == 4 && StartsIgnoringCase(attribute, u"type")) ||
                             (attribute.size() == 4 && StartsIgnoringCase(attribute, u"lang"));
    tokens.push_back({start, index - start, Ink::Name});
    return index;
}

static bool MarkupPunctuation(char16_t ch, LexState &state)
{
    if (state.markup.expressions.empty())
        return false;
    auto &expression = state.markup.expressions.back();
    if (state.interpolations.size() != expression.stringDepth)
        return false;
    if (ch == u'{') {
        ++expression.braces;
    } else if (ch == u'}' && --expression.braces == 0) {
        state.mode = expression.mode;
        state.markup.part = expression.part == TagPart::Value ? TagPart::Attribute : expression.part;
        state.markup.endTag = expression.endTag;
        state.markup.expressions.pop_back();
        return true;
    }
    return false;
}

static bool StartsJSX(Text line, size_t index, bool expectsValue, Language language)
{
    if (!expectsValue || At(line, index) != u'<')
        return false;
    if (At(line, index + 1) == u'>')
        return true;
    if (!NameStart(At(line, index + 1)))
        return false;
    // In TSX, a trailing comma or constraint distinguishes a generic arrow from an opening tag.
    if (language == Language::TSX) {
        size_t afterName = SkipSpace(line, MarkupNameEnd(line, index + 1));
        if (At(line, afterName) == u',' || line.substr(afterName).starts_with(u"extends ") ||
            line.substr(afterName).starts_with(u"extends\t"))
            return false;
    }
    return true;
}

static bool CSSFamily(Language language)
{
    return language == Language::CSS || language == Language::SCSS || language == Language::Less;
}

static bool JSONFamily(Language language)
{
    return language == Language::JSON || language == Language::JSONC;
}

static bool Config(Language language)
{
    return language == Language::TOML || language == Language::INI;
}

static bool LineCommentAt(Text line, size_t index, size_t first, Language language)
{
    char16_t ch = line[index];
    Text rest = line.substr(index);
    if (language == Language::PHP && ch == u'#')
        return At(line, index + 1) != u'[';
    if (language == Language::INI && ch == u'#')
        return index == first || Space(At(line, index - 1));
    if (language == Language::Assembly && (rest.starts_with(u"//") || (ch == u'#' && index == first)))
        return true;
    if (language == Language::Odin && rest.starts_with(u"#!"))
        return true;
    if (language == Language::VisualBasic && index == first && StartsIgnoringCase(rest, u"rem") &&
        (rest.size() == 3 || Space(At(rest, 3))))
        return true;
    Text prefix = InfoForLanguage(language).comments.line;
    if (prefix.empty() || !rest.starts_with(prefix))
        return false;
    if (language == Language::Dockerfile)
        return index == first;
    if ((Shell(language) || language == Language::YAML || language == Language::INI) && index > first)
        return Space(line[index - 1]) || (Shell(language) && Text(u";|&()<>").find(line[index - 1]) != Text::npos);
    return true;
}

static size_t BlockCommentAt(Text line, size_t index, Language language, LexState &state)
{
    const auto &comments = InfoForLanguage(language).comments;
    if (LuaFamily(language) && line.substr(index).starts_with(u"--")) {
        size_t body = LongBracket(line, index + 2, state, LexMode::BlockComment);
        return body == index + 2 ? index : body;
    }
    if (language == Language::CMake && At(line, index) == u'#') {
        size_t body = LongBracket(line, index + 1, state, LexMode::BlockComment);
        return body == index + 1 ? index : body;
    }
    if (!comments.open.empty() && line.substr(index).starts_with(comments.open)) {
        SetToken(state, LexMode::BlockComment, {}, true);
        state.depth = 1;
        return index + comments.open.size();
    }
    return index;
}

static size_t BeginHereDocument(Text line, size_t start, Language language, LexState &state)
{
    Text rest = line.substr(start);
    if ((!Shell(language) && language != Language::Ruby && language != Language::PHP) || !rest.starts_with(u"<<"))
        return start;
    if (language == Language::Fish || (start && line[start - 1] == u'<') ||
        ((language == Language::PHP) != rest.starts_with(u"<<<")))
        return start;
    size_t at = start + (language == Language::PHP ? 3 : 2);
    bool indent = language == Language::PHP || At(line, at) == u'-' ||
                  (language == Language::Ruby && At(line, at) == u'~');
    if (indent && language != Language::PHP)
        ++at;
    if (language == Language::Ruby && Space(At(line, at)))
        return start;

    at = SkipSpace(line, at);
    bool escaped = At(line, at) == u'\\';
    if (escaped)
        ++at;
    char16_t quote = At(line, at);
    if (quote == u'\'' || quote == u'"') {
        size_t end = QuotedEnd(line, at + 1, quote);
        if (end == at + 1 && At(line, end) != quote)
            return start;
        if (end == at + 1)
            ++end;
        if (end == at + 2)
            return start;
        state.hereDocuments.push_back({std::u16string(line.substr(at + 1, end - at - 2)), indent,
                                       !Shell(language) && quote == u'"'});
        return end;
    }
    if (!NameStart(At(line, at)))
        return start;
    size_t end = ReadName(line, at + 1);
    state.hereDocuments.push_back({std::u16string(line.substr(at, end - at)), indent, !escaped});
    return end;
}

static bool HereDocumentLine(Text line, Language language, LexState &state, std::vector<Token> &tokens,
                             bool finishLine)
{
    if (state.hereDocuments.empty() || state.mode != LexMode::Code)
        return false;
    const auto &doc = state.hereDocuments.front();
    size_t at = 0;
    if (doc.indent) {
        while (At(line, at) == u'\t' || (!Shell(language) && At(line, at) == u' '))
            ++at;
    }
    Text body = line.substr(at);
    if (body == doc.end || (language == Language::PHP && body.starts_with(doc.end) &&
        !NamePart(At(body, doc.end.size())))) {
        tokens.push_back({at, doc.end.size(), Ink::Directive, true});
        if (finishLine)
            state.hereDocuments.erase(state.hereDocuments.begin());
        return true;
    }
    size_t start = 0;
    if (doc.expand && language != Language::Ruby) {
        for (size_t i = 0; i < line.size(); ++i) {
            if (line[i] == u'\\' && i + 1 < line.size()) {
                ++i;
            } else if (line[i] == u'$') {
                size_t end = VariableEnd(line, i);
                if (end == i && At(line, i + 1) == u'{') {
                    size_t close = line.find(u'}', i + 2);
                    if (close != Text::npos)
                        end = close + 1;
                }
                if (end != i) {
                    if (i > start)
                        tokens.push_back({start, i - start, Ink::String, true});
                    tokens.push_back({i, end - i, Ink::Escape, true});
                    start = end;
                    i = end - 1;
                }
            }
        }
    }
    if (line.size() > start)
        tokens.push_back({start, line.size() - start, Ink::String, true});
    return true;
}

static void GMLDocComment(Text line, size_t start, std::vector<Token> &tokens)
{
    size_t tag = SkipSpace(line, start + 3);
    if (At(line, tag) == u'@' && NameStart(At(line, tag + 1))) {
        tokens.push_back({start, tag - start, Ink::Comment, true});
        size_t end = ReadName(line, tag + 2);
        tokens.push_back({tag, end - tag, Ink::Directive, true});
        start = end;
    }
    if (start < line.size())
        tokens.push_back({start, line.size() - start, Ink::Comment, true});
}

static size_t GMLDirective(Text line, size_t start, std::vector<Token> &tokens)
{
    size_t end = ReadName(line, start + 1);
    Text name = line.substr(start + 1, end - start - 1);
    if (name == u"region" || name == u"endregion") {
        tokens.push_back({start, end - start, Ink::Directive, true});
        if (end < line.size())
            tokens.push_back({end, line.size() - end, Ink::Comment, true});
        return line.size();
    }
    if (name != u"macro")
        return start;

    tokens.push_back({start, end - start, Ink::Directive, true});
    size_t symbol = SkipSpace(line, end);
    if (!NameStart(At(line, symbol)))
        return end;
    end = ReadName(line, symbol + 1);
    if (At(line, end) == u':') {
        tokens.push_back({symbol, end + 1 - symbol, Ink::Directive, true});
        symbol = SkipSpace(line, end + 1);
        if (!NameStart(At(line, symbol)))
            return end + 1;
        end = ReadName(line, symbol + 1);
    }
    tokens.push_back({symbol, end - symbol, Ink::Constant});
    return end;
}

static size_t ExtraDirective(Text line, size_t index, size_t first, Language language)
{
    char16_t ch = line[index], next = At(line, index + 1);
    if (language == Language::Odin && (ch == u'#' || ch == u'@')) {
        size_t name = SkipSpace(line, index + 1);
        return NameStart(At(line, name)) ? ReadName(line, name + 1) : index + 1;
    }
    if (ch == u'@' && NameStart(next) && (language == Language::Swift || language == Language::Java ||
        language == Language::Kotlin || language == Language::Scala || language == Language::Groovy ||
        language == Language::Zig || CFamily(language) || CSSFamily(language) || language == Language::Dart))
        return MarkupNameEnd(line, index + 2);
    if (ch == u'@' && language == Language::Zig && next == u'"')
        return index + 1;
    if (ch == u'#' && (language == Language::Swift ||
        (index == first && (language == Language::CSharp || language == Language::FSharp || language == Language::VisualBasic)))) {
        size_t name = SkipSpace(line, index + 1);
        return ReadName(line, name);
    }
    if (ch == u'#' && JavaScriptFamily(language) && NameStart(next))
        return ReadName(line, index + 2);
    return index;
}

static size_t CSSNameEnd(Text line, size_t index)
{
    while (NamePart(At(line, index)) || At(line, index) == u'-')
        ++index;
    return index;
}

static size_t CSSToken(Text line, size_t index, Language language, const LexState &state,
                      std::vector<Token> &tokens)
{
    char16_t ch = line[index];
    if ((ch == u'.' || ch == u'#' || (ch == u'$' && language == Language::SCSS)) &&
        (NameStart(At(line, index + 1)) || At(line, index + 1) == u'-' || (ch == u'#' && Digit(At(line, index + 1))))) {
        size_t end = CSSNameEnd(line, index + 1);
        Text word = line.substr(index + 1, end - index - 1);
        bool color = ch == u'#' && (word.size() == 3 || word.size() == 4 || word.size() == 6 || word.size() == 8) &&
                     std::ranges::all_of(word, HexDigit);
        tokens.push_back({index, end - index, color ? Ink::Number : ch == u'$' ? Ink::Name : Ink::Type});
        return end;
    }
    if (StartsIgnoringCase(line.substr(index), u"url(")) {
        size_t end = SkipSpace(line, index + 4);
        if (At(line, end) != u'"' && At(line, end) != u'\'') {
            size_t close = line.find(u')', end);
            if (close != Text::npos) {
                tokens.push_back({index, 3, Ink::Function});
                if (close > end)
                    tokens.push_back({end, close - end, Ink::String, true});
                return close + 1;
            }
        }
    }
    if (NameStart(ch) || (ch == u'-' && (NameStart(At(line, index + 1)) || At(line, index + 1) == u'-'))) {
        size_t end = CSSNameEnd(line, index + 1);
        size_t next = SkipSpace(line, end);
        Ink ink = WordInk(line.substr(index, end - index), language, At(line, next));
        if (state.names.braceDepth && At(line, next) == u':') {
            size_t boundary = line.find_first_of(u"{};", next + 1);
            if (boundary == Text::npos || line[boundary] != u'{')
                ink = Ink::Type;
        } else if (index && At(line, index - 1) == u':') {
            ink = Ink::Control;
        }
        tokens.push_back({index, end - index, ink});
        return end;
    }
    return index;
}

static bool YAMLColon(Text line, size_t at)
{
    char16_t next = At(line, at + 1);
    return At(line, at) == u':' && (!next || Space(next) || Text(u",]}[{").find(next) != Text::npos);
}

static size_t ConfigKeyEnd(Text line, size_t start, Language language)
{
    // Key spans stop at a separator outside quotes and flow collections.
    size_t end = start;
    for (; end < line.size(); ++end) {
        char16_t ch = line[end];
        if (ch == u'"' || ch == u'\'') {
            size_t next = QuotedEnd(line, end + 1, ch, ch == u'\'' && language == Language::YAML);
            if (next == end + 1)
                return start;
            end = next - 1;
            continue;
        }
        if ((language == Language::YAML && YAMLColon(line, end)) ||
            (Config(language) && (ch == u'=' || (language == Language::INI && ch == u':'))))
            break;
        if (ch == u'{' || ch == u'}' || ch == u'[' || ch == u']' || ch == u',' ||
            (ch == u'#' && (end == start || Space(line[end - 1]))) || (ch == u';' && language == Language::INI))
            return start;
    }
    if (end == line.size())
        return start;
    while (end > start && Space(line[end - 1]))
        --end;
    return end;
}

static size_t PreviousNonSpace(Text line, size_t index)
{
    while (index && Space(line[index - 1]))
        --index;
    return index;
}

static size_t DataToken(Text line, size_t index, size_t first, Language language, LexState &state,
                        std::vector<Token> &tokens)
{
    char16_t ch = line[index];
    if (Config(language) && index == first && ch == u'[') {
        bool doubleBracket = At(line, index + 1) == u'[';
        size_t end = line.find(doubleBracket ? u"]]" : u"]", index + 1 + doubleBracket);
        end = end == Text::npos ? line.size() : end + 1 + doubleBracket;
        tokens.push_back({index, end - index, Ink::Directive, true});
        return end;
    }
    if (language == Language::YAML) {
        if (index == first && (line.substr(index) == u"---" || line.substr(index) == u"...")) {
            tokens.push_back({index, 3, Ink::Directive, true});
            return index + 3;
        }
        if (ch == u'&' || ch == u'*' || ch == u'!') {
            size_t end = index + 1;
            while (NamePart(At(line, end)) || At(line, end) == u'-' || At(line, end) == u'!')
                ++end;
            tokens.push_back({index, end - index, Ink::Directive, true});
            return end;
        }
        if (ch == u'|' || ch == u'>') {
            size_t end = index + 1;
            unsigned indentation = 0;
            if (At(line, end) == u'+' || At(line, end) == u'-')
                ++end;
            if (At(line, end) >= u'1' && At(line, end) <= u'9')
                indentation = unsigned(line[end++] - u'0');
            if (end == index + 1 + bool(indentation) && (At(line, end) == u'+' || At(line, end) == u'-'))
                ++end;
            size_t tail = SkipSpace(line, end);
            if (tail == line.size() || At(line, tail) == u'#') {
                tokens.push_back({index, end - index, Ink::Directive, true});
                size_t base = first;
                if (At(line, first) == u'-' && Space(At(line, first + 1))) {
                    size_t key = SkipSpace(line, first + 1);
                    if (key < index && ConfigKeyEnd(line, key, language) != key)
                        base = key;
                }
                state.depth = unsigned(base) + (indentation ? indentation : 1);
                state.mode = LexMode::BlockScalar;
                if (tail < line.size())
                    tokens.push_back({tail, line.size() - tail, Ink::Comment, true});
                return line.size();
            }
        }
    }
    size_t previous = PreviousNonSpace(line, index);
    bool sequenceKey = language == Language::YAML && previous == first + 1 && line[first] == u'-' && index > previous;
    bool flowKey = language == Language::YAML && previous && (line[previous - 1] == u'{' || line[previous - 1] == u',');
    if ((index == first || sequenceKey || flowKey) && (NameStart(ch) || Digit(ch) || ch == u'"' || ch == u'\'')) {
        size_t end = ConfigKeyEnd(line, index, language);
        if (end > index) {
            bool name = std::ranges::all_of(line.substr(index, end - index), NamePart);
            tokens.push_back({index, end - index, Ink::Type, !name});
            return end;
        }
    }
    return index;
}

static Ink OdinWordInk(Text line, Text word, size_t start, size_t end, NameContext &context)
{
    if (std::exchange(context.parameterStart, false))
        return Ink::Directive;

    size_t after = SkipSpace(line, end);
    char16_t follow = At(line, after);
    if (word.starts_with(u"$") && word.size() > 1) {
        if (follow != u':')
            return Ink::Type;
        size_t constraint = SkipSpace(line, after + 1);
        Text type = line.substr(constraint, ReadName(line, constraint) - constraint);
        return type == u"typeid" ? Ink::Type : Ink::Constant;
    }
    Ink ink = WordInk(word, Language::Odin, follow);
    if (follow == u':' && (At(line, after + 1) == u':' || At(line, after + 1) == u'=')) {
        size_t value = SkipTrivia(line, after + 2);
        if (At(line, value) == u'#') {
            size_t name = SkipSpace(line, value + 1);
            Text directive = line.substr(name, ReadName(line, name) - name);
            if (directive == u"type" || directive == u"simd" || directive == u"soa")
                return Ink::Type;
        }
        Text head = line.substr(value, ReadName(line, value) - value);
        if (head == u"proc")
            return Ink::Function;
        if (head == u"struct" || head == u"union" || head == u"enum" || head == u"distinct" ||
            head == u"bit_field" || head == u"bit_set" || head == u"map" || head == u"matrix")
            return Ink::Type;
    }
    if (std::ranges::binary_search(odinProcedures, word))
        return Ink::Function;

    size_t before = PreviousNonSpace(line, start);
    if (before && At(line, before - 1) == u'.' &&
        (before == 1 || Space(At(line, before - 2)) || Text(u"(:,[={").find(At(line, before - 2)) != Text::npos))
        return Ink::Constant;
    if (ink == Ink::Name || ink == Ink::Constant) {
        size_t previous = before;
        while (previous && NamePart(At(line, previous - 1)))
            --previous;
        Text prior = line.substr(previous, before - previous);
        if (prior == u"package" || prior == u"import")
            return Ink::Type;
        if (word.size() == 1 && word.front() >= u'A' && word.front() <= u'Z' && before) {
            char16_t ch = line[before - 1];
            if (ch == u'^' || ch == u']' || (ch == u':' && (before < 2 || line[before - 2] != u':')) ||
                (ch == u'>' && before >= 2 && line[before - 2] == u'-') || follow == u'{')
                return Ink::Type;
        }
    }
    return ink;
}

static Ink ContextualExtraWord(Text line, Text word, size_t start, size_t end, Language language, LexState &state)
{
    if (language == Language::Odin)
        return OdinWordInk(line, word, start, end, state.names);
    size_t after = language == Language::GML ? SkipTrivia(line, end) : SkipSpace(line, end);
    char16_t follow = At(line, after);
    if (language == Language::Clojure && word.starts_with(u":"))
        return Ink::Constant;
    Ink ink = WordInk(word, language, follow);
    if (language == Language::Java && word == u"sealed" && !JavaTypeModifierContext(line, start, end))
        ink = follow == u'(' ? Ink::Function : Ink::Name;
    if (ink == Ink::Keyword) {
        if (word == u"func" || word == u"fun" || word == u"fn" || word == u"def" ||
            (word == u"function" && language != Language::GML) ||
            word == u"defp" || word == u"sub" || word == u"defn" || word == u"defn-" || word == u"defmacro")
            state.names.nextName = NameRole::Function;
        else if (word == u"class" || word == u"struct" || word == u"enum" || word == u"trait" || word == u"record" ||
                 word == u"protocol" || word == u"interface" || word == u"extends" || word == u"implements" ||
                 word == u"typealias" || word == u"typedef" || word == u"type" || word == u"actor" ||
                 (word == u"new" && language != Language::GML))
            state.names.nextName = NameRole::Type;
        else
            state.names.nextName = NameRole::None;
        return ink;
    }
    auto expected = std::exchange(state.names.nextName, NameRole::None);
    if (expected == NameRole::Type)
        return Ink::Type;
    if (expected == NameRole::Function)
        return Ink::Function;
    bool typedLanguage = language == Language::TypeScript || language == Language::TSX || language == Language::Swift ||
                         language == Language::Kotlin || language == Language::Luau;
    if (typedLanguage && word.size() == 1 && word.front() >= u'A' && word.front() <= u'Z') {
        size_t before = PreviousNonSpace(line, start);
        char16_t earlier = before ? line[before - 1] : 0;
        if (earlier == u'<' || earlier == u':' || follow == u'>' || follow == u':' || follow == u',')
            return Ink::Type;
    }
    if (language == Language::Assembly) {
        Text digits = word;
        if (word.starts_with(u"%"))
            digits.remove_prefix(1);
        if (digits.size() >= 2 && Text(u"xwrvsdq").find(Lower(digits.front())) != Text::npos &&
            std::ranges::all_of(digits.substr(1), Digit))
            return Ink::Type;
        if (word == u"sp" || word == u"lr" || word == u"fp" || word == u"pc")
            return Ink::Type;
    }
    return ink;
}

template<Language Mode>
static void TokenizeCodeInMode(Text line, Language requested, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    const Language language = Mode == Language::Count ? requested : Mode;
    const bool cFamily = CFamily(language);
    const bool rust = language == Language::Rust;
    const bool odin = language == Language::Odin;
    const bool gml = language == Language::GML;
    const bool cpp = language == Language::Cpp || language == Language::ObjectiveCpp;
    const bool js = JavaScriptFamily(language);
    const bool jsx = JSXLanguage(language);
    const bool cssLanguage = CSSFamily(language);
    const bool config = Config(language);
    const bool json = JSONFamily(language);
    const bool yaml = language == Language::YAML;
    const bool clojure = language == Language::Clojure;
    const bool make = language == Language::Makefile;
    const bool regex = js || language == Language::Ruby || language == Language::Perl;
    const auto &comments = InfoForLanguage(language).comments;
    const char16_t blockCommentStart = comments.open.empty() ? 0 : comments.open.front();
    const char16_t lineCommentStart = comments.line.empty() ? 0 : comments.line.front();
    const bool otherLineComments = language == Language::PHP || language == Language::INI ||
                                   language == Language::Assembly || language == Language::VisualBasic || odin;
    const size_t first = SkipSpace(line, 0);
    bool expectsValue = !regex || state.expectsValue;

    if (HereDocumentLine(line, language, state, tokens, finishLine)) {
        if (!finishLine)
            state.mode = LexMode::Raw;
        return;
    }
    if (state.mode == LexMode::BlockScalar) {
        if (first >= state.depth || first == line.size()) {
            if (!line.empty())
                tokens.push_back({0, line.size(), Ink::String, true});
            return;
        }
        SetToken(state);
    }
    if (line.empty()) {
        if (finishLine && (state.mode == LexMode::LineComment ||
            ((state.mode == LexMode::Quoted || state.mode == LexMode::Raw) && !state.multiline)))
            SetToken(state);
        return;
    }
    if ((language == Language::Ruby && first == 0 && line.starts_with(u"=begin") &&
         (line.size() == 6 || Space(line[6]))) ||
        (language == Language::Perl && first == 0 && (line.starts_with(u"=pod") || line.starts_with(u"=head") ||
         line.starts_with(u"=begin") || line.starts_with(u"=item") || line.starts_with(u"=over")))) {
        SetToken(state, LexMode::BlockComment, language == Language::Ruby ? u"=end" : u"=cut", true);
        state.depth = 1;
        tokens.push_back({0, line.size(), Ink::Comment, true});
        return;
    }
    if (state.mode == LexMode::BlockComment && (state.closing == u"=end" || state.closing == u"=cut")) {
        tokens.push_back({0, line.size(), Ink::Comment, true});
        if (line.starts_with(state.closing) && !NamePart(At(line, state.closing.size())))
            SetToken(state);
        return;
    }

    enum class IdentifierContext { Ordinary, Contextual, Attribute };
    auto identifiers = (rust || cpp) ? IdentifierContext::Contextual : IdentifierContext::Ordinary;
    if (rust && state.attribute.brackets)
        identifiers = IdentifierContext::Attribute;

    for (size_t index = 0; index < line.size();) {
        size_t start = index;
        Ink ink = Ink::Text;
        bool identifier = false;
        bool nonCode = false;
        char16_t ch = line[index];
        Text rest = line.substr(index);

        if ((jsx || language == Language::PHP) && MarkupMode(state.mode)) {
            index = MarkupStep(line, index, language, state, tokens);
            expectsValue = state.mode == LexMode::Code;
            continue;
        }
        if (state.mode == LexMode::Quoted || state.mode == LexMode::Raw) {
            size_t depth = state.interpolations.size();
            index = ContinueString(line, index, index, language, state, tokens, finishLine);
            expectsValue = state.interpolations.size() > depth;
            continue;
        }
        if (state.mode == LexMode::BlockComment || state.mode == LexMode::LineComment) {
            if (state.closing == u"-->" && language == Language::PHP) {
                index = MarkupStep(line, index, language, state, tokens);
                continue;
            }
            index = ContinueComment(line, index, language, state, finishLine);
            tokens.push_back({start, index - start, Ink::Comment, true});
            continue;
        }
        if (Space(ch)) {
            index = SkipSpace(line, index + 1);
            continue;
        }
        if (ch == blockCommentStart || (language == Language::CMake && ch == u'#')) {
            size_t body = BlockCommentAt(line, index, language, state);
            if (body != index) {
                index = ContinueComment(line, body, language, state, finishLine);
                tokens.push_back({start, index - start, Ink::Comment, true});
                continue;
            }
        }
        if ((ch == lineCommentStart || otherLineComments) && LineCommentAt(line, index, first, language)) {
            if (!finishLine || (cFamily && line.ends_with(u"\\")))
                state.mode = LexMode::LineComment;
            if (gml && rest.starts_with(u"///")) {
                GMLDocComment(line, start, tokens);
            } else {
                bool directive = language == Language::Go && (rest.starts_with(u"//go:") || rest.starts_with(u"//line "));
                tokens.push_back({start, line.size() - start, directive ? Ink::Directive : Ink::Comment, true});
            }
            break;
        }
        if (language == Language::PHP) {
            if (size_t length = PHPTag(rest)) {
                tokens.push_back({start, length, Ink::Directive, true});
                index += length;
                continue;
            } else if (rest.starts_with(u"?>")) {
                tokens.push_back({start, 2, Ink::Directive, true});
                index += 2;
                state.mode = LexMode::MarkupText;
                continue;
            }
        }
        if (jsx && StartsJSX(line, index, expectsValue, language)) {
            state.markup.roots.push_back(state.markup.depth);
            state.mode = LexMode::MarkupText;
            index = MarkupStep(line, index, language, state, tokens);
            continue;
        }
        if (cssLanguage) {
            if (size_t after = CSSToken(line, index, language, state, tokens); after != index) {
                index = after;
                continue;
            }
            if (ch == u'{')
                ++state.names.braceDepth;
            else if (ch == u'}' && state.names.braceDepth)
                --state.names.braceDepth;
        }
        if (config || yaml) {
            if (size_t after = DataToken(line, index, first, language, state, tokens); after != index) {
                index = after;
                continue;
            }
        }
        if (ch == u'<' && (!Shell(language) || expectsValue || !state.names.groups)) {
            if (size_t after = BeginHereDocument(line, index, language, state); after != index) {
                tokens.push_back({start, after - start, Ink::Directive, true});
                index = after;
                continue;
            }
        }
        if (cFamily && index == first && ch == u'#') {
            size_t directive = SkipSpace(line, index + 1);
            index = ReadName(line, directive);
            ink = Ink::Directive;
            Text name = line.substr(directive, index - directive);
            size_t header = SkipSpace(line, index);
            if ((name == u"include" || name == u"include_next" || name == u"import") && At(line, header) == u'<') {
                size_t end = line.find(u'>', header + 1);
                tokens.push_back({start, index - start, ink});
                start = header;
                index = end == Text::npos ? line.size() : end + 1;
                ink = Ink::String;
                nonCode = true;
                if (end == Text::npos && !finishLine)
                    SetToken(state, LexMode::Raw, u">");
            }
        } else if (size_t body = ch == u'#' && rust && identifiers == IdentifierContext::Contextual ?
                   BeginRustAttribute(line, index, state.attribute, tokens) : index; body != index) {
            identifiers = IdentifierContext::Attribute;
            index = body;
        } else if (odin && rest.starts_with(u"#+")) {
            index = ReadName(line, index + 2);
            tokens.push_back({start, index - start, Ink::Directive, true});
            size_t arguments = index;
            while (index < line.size() && !line.substr(index).starts_with(u"//") && !line.substr(index).starts_with(u"/*"))
                ++index;
            if (index > arguments)
                tokens.push_back({arguments, index - arguments, Ink::Text, true});
            continue;
        } else if (odin && ch == u'@' && !state.names.groups && At(line, SkipSpace(line, index + 1)) == u'(') {
            state.names.groups = 1;
            state.names.parameterStart = true;
            tokens.push_back({start, 1, Ink::Directive});
            index = SkipSpace(line, index + 1) + 1;
            continue;
        } else if (odin && rest.starts_with(u"---")) {
            index += 3;
            ink = Ink::Constant;
        } else if (size_t after = gml && ch == u'#' && index == first ? GMLDirective(line, index, tokens) : index;
                   after != index) {
            index = after;
            continue;
        } else if (gml && ch == u'$' && index && line[index - 1] == u'[') {
            ++index; // The [$ accessor is distinct from a template string.
            continue;
        } else if (size_t body = BeginQuoted(line, index, language, state, expectsValue); body != index) {
            if (identifiers == IdentifierContext::Contextual)
                ClearNameExpectation(state.names);
            else if (identifiers == IdentifierContext::Attribute)
                state.attribute.part = RustAttributePart::Arguments;
            if (json) {
                size_t end = QuotedEnd(line, body, u'"');
                if (end > body && At(line, SkipSpace(line, end)) == u':')
                    state.stringInk = Ink::Type;
            }
            size_t depth = state.interpolations.size();
            index = ContinueString(line, start, body, language, state, tokens, finishLine);
            expectsValue = state.interpolations.size() > depth;
            continue;
        } else if (size_t after = ExtraDirective(line, index, first, language); after != index) {
            ink = Ink::Directive;
            index = after;
        } else if (language == Language::Zig && rest.starts_with(u"\\\\")) {
            tokens.push_back({start, line.size() - start, Ink::String, true});
            break;
        } else if ((language == Language::CMake) && ch == u'[' &&
                   LongBracket(line, index, state, LexMode::Raw) != index) {
            size_t body = index + state.closing.size();
            index = ContinueString(line, start, body, language, state, tokens, finishLine);
            continue;
        } else if (ch == u'`' && (language == Language::Swift || language == Language::Kotlin || language == Language::Scala)) {
            size_t end = line.find(u'`', index + 1);
            index = end == Text::npos ? line.size() : end + 1;
            ink = Ink::Name;
            nonCode = true;
        } else if (ch == u':' && language == Language::Ruby && NameStart(At(line, index + 1)) &&
                   (!index || line[index - 1] != u':')) {
            index = ReadRubyName(line, index + 2);
            ink = Ink::Constant;
        } else if (ch == u'$' && (InterpolatesVariable(language) || language == Language::Perl ||
                   language == Language::Makefile || language == Language::CMake || language == Language::Dockerfile) &&
                   (At(line, index + 1) == u'{' || (At(line, index + 1) == u'(' && language == Language::Makefile))) {
            char16_t stop = At(line, index + 1) == u'{' ? u'}' : u')';
            size_t end = line.find(stop, index + 2);
            if (end != Text::npos && line.substr(index + 2, end - index - 2).find_first_of(u"$({") == Text::npos) {
                tokens.push_back({start, end - start + 1, Ink::Name, true});
                index = end + 1;
                expectsValue = false;
            } else {
                ++index;
            }
            continue;
        } else if (ch == u'$' && (InterpolatesVariable(language) || language == Language::Perl ||
                   language == Language::Makefile || language == Language::Dockerfile) && VariableEnd(line, index) != index) {
            index = VariableEnd(line, index);
            ink = WordInk(line.substr(start, index - start), language, 0);
            expectsValue = false;
        } else if (size_t end = gml && (ch == u'$' || ch == u'#') ? GMLHexEnd(line, index) : index; end != index) {
            index = end;
            ink = Ink::Number;
        } else if (Digit(ch) || (ch == u'.' && Digit(At(line, index + 1)) && (!index || line[index - 1] != u'.'))) {
            index = odin ? OdinNumberEnd(line, index) : NumberEnd(line, index);
            ink = Ink::Number;
            if (identifiers == IdentifierContext::Contextual)
                ClearNameExpectation(state.names);
            else if (identifiers == IdentifierContext::Attribute)
                state.attribute.part = RustAttributePart::Arguments;
            expectsValue = false;
        } else if (NameStart(ch) ||
                   (ch == u'.' && (language == Language::R || (make && NameStart(At(line, index + 1))))) ||
                   (clojure && ch == u':' && ClojureNamePart(At(line, index + 1))) ||
                   (rust && ch == u'\'' && NameStart(At(line, index + 1))) ||
                   (language == Language::Assembly && ch == u'%' && NameStart(At(line, index + 1)))) {
            bool lifetime = ch == u'\'';
            bool raw = rust && rest.starts_with(u"r#") && NameStart(At(line, index + 2));
            if (lifetime)
                ++index;
            if (raw)
                index += 2;
            size_t wordStart = index;
            index = language == Language::Ruby ? ReadRubyName(line, index + 1) : ReadName(line, index + 1);
            if (clojure) {
                while (ClojureNamePart(At(line, index)))
                    ++index;
            } else if (language == Language::R || make) {
                while (At(line, index) == u'.')
                    index = ReadName(line, index + 1);
            } else if (language == Language::Haskell || language == Language::FSharp) {
                while (At(line, index) == u'\'')
                    index = ReadName(line, index + 1);
            } else if (language == Language::Java) {
                constexpr Text modifier = u"non-sealed";
                size_t end = wordStart + modifier.size();
                if (WordAt(line, wordStart, modifier) && JavaTypeModifierContext(line, wordStart, end))
                    index = end;
            }
            Text word = line.substr(wordStart, index - wordStart);
            if (lifetime) {
                ink = Ink::Type;
                if (identifiers == IdentifierContext::Attribute)
                    state.attribute.part = RustAttributePart::Arguments;
                else if (AtParameterStart(state.names))
                    state.names.parameterStart = false;
            } else if (identifiers == IdentifierContext::Contextual) {
                ink = ContextualWordInk(line, word, index, language, state.names, raw);
                identifier = true;
            } else if (identifiers == IdentifierContext::Attribute) {
                ink = RustAttributeWordInk(line, word, index, raw, state.attribute);
            } else if (json) {
                ink = VocabularyFor(language).constants.contains(word) ? Ink::Constant : Ink::Text;
            } else {
                ink = ContextualExtraWord(line, word, start, index, language, state);
                if (make && !(word.starts_with(u".") && ink == Ink::Constant) &&
                    At(line, SkipSpace(line, index)) == u':' && At(line, SkipSpace(line, index) + 1) != u'=')
                    ink = Ink::Function;
            }
            expectsValue = word == u"return" || word == u"throw" || word == u"case" || word == u"yield" || word == u"in";
        } else if (regex && ch == u'/' && expectsValue) {
            size_t end = RegexEnd(line, index);
            index = end == index && !js ? index + 1 : end == index ? line.size() : end;
            if (end != start || js)
                ink = Ink::String;
            if (end == start && !finishLine && js)
                SetToken(state, LexMode::Raw, u"/");
            expectsValue = false;
        } else {
            bool returnToMarkup = jsx && MarkupPunctuation(ch, state);
            if (!returnToMarkup)
                StringPunctuation(ch, state);
            expectsValue = Text(u"=(:,[!&|?;{}").find(ch) != Text::npos || (ch == u'>' && index && line[index - 1] == u'=');
            if (identifiers == IdentifierContext::Contextual) {
                index = NamePunctuation(line, index, rust, state.names);
                continue;
            }
            if (identifiers == IdentifierContext::Attribute) {
                RustAttributePunctuation(ch, state.attribute);
                if (state.attribute.brackets == 0)
                    identifiers = IdentifierContext::Contextual;
            }
            if (odin && state.names.groups) {
                if (ch == u'(' || ch == u'[' || ch == u'{')
                    ++state.names.groups;
                else if (ch == u')' || ch == u']' || ch == u'}')
                    --state.names.groups;
                state.names.parameterStart = state.names.groups == 1 && ch == u',';
            }
            if (ch == u';' || ch == u'=' || ch == u'{')
                state.names.nextName = NameRole::None;
            ++index;
        }

        if (ink != Ink::Text || identifier)
            tokens.push_back({start, index - start, ink, nonCode});
    }
    if (regex)
        state.expectsValue = expectsValue;
}

static size_t LispDigits(Text text, size_t at, unsigned radix)
{
    while (at < text.size()) {
        char16_t ch = Lower(text[at]);
        unsigned value = Digit(ch) ? unsigned(ch - u'0') : ch >= u'a' && ch <= u'z' ? unsigned(ch - u'a') + 10 : 36;
        if (value >= radix)
            break;
        ++at;
    }
    return at;
}

static bool LispNumber(Text word, unsigned radix = 0)
{
    if (word.starts_with(u"+") || word.starts_with(u"-"))
        word.remove_prefix(1);
    unsigned base = radix ? radix : 10;
    size_t at = LispDigits(word, 0, base);
    bool digits = at != 0;
    if (digits && At(word, at) == u'/') {
        size_t denominator = at + 1;
        return denominator < word.size() && LispDigits(word, denominator, base) == word.size();
    }
    if (radix)
        return digits && at == word.size();
    if (At(word, at) == u'.') {
        size_t fraction = ++at;
        at = LispDigits(word, at, 10);
        digits |= at != fraction;
    }
    if (digits && Text(u"esfdl").find(Lower(At(word, at))) != Text::npos) {
        ++at;
        if (At(word, at) == u'+' || At(word, at) == u'-')
            ++at;
        size_t exponent = at;
        at = LispDigits(word, at, 10);
        digits = at != exponent;
    }
    return digits && at == word.size();
}

static size_t LispSymbolEnd(Text line, size_t at, LexState &state, bool &escaped)
{
    bool bars = state.mode == LexMode::Raw && !state.closing.empty();
    bool continued = false;
    while (at < line.size()) {
        char16_t ch = line[at];
        if (ch == u'\\') {
            continued = at + 1 == line.size();
            escaped = true;
            at = EscapeEnd(line, at, Language::CommonLisp);
        } else if (ch == u'|') {
            bars = !bars;
            escaped = true;
            ++at;
        } else if (bars || IsLispSymbolPart(ch)) {
            ++at;
        } else {
            break;
        }
    }
    if (bars || continued)
        SetToken(state, LexMode::Raw, bars ? u"|" : u"", true);
    else if (state.mode == LexMode::Raw)
        SetToken(state);
    return at;
}

static Ink LispWordInk(Text word, LexState &state)
{
    auto expected = std::exchange(state.names.nextName, NameRole::None);
    bool head = std::exchange(state.lispListHead, false);
    if (expected == NameRole::Function)
        return Ink::Function;
    if (expected == NameRole::Type)
        return Ink::Type;
    if (word == u".")
        return Ink::Text;
    if (LispNumber(word))
        return Ink::Number;
    if (word.starts_with(u":"))
        return Ink::Constant;

    Text name = word.substr(word.rfind(u':') + 1);
    Ink ink = WordInk(name, Language::CommonLisp, 0);
    if (head && ink == Ink::Keyword) {
        for (Text form : {Text(u"defun"), Text(u"defmacro"), Text(u"defgeneric"), Text(u"defmethod"),
                          Text(u"define-compiler-macro")}) {
            if (name.size() == form.size() && StartsIgnoringCase(name, form))
                state.names.nextName = NameRole::Function;
        }
        for (Text form : {Text(u"defclass"), Text(u"defstruct"), Text(u"deftype"), Text(u"define-condition")}) {
            if (name.size() == form.size() && StartsIgnoringCase(name, form))
                state.names.nextName = NameRole::Type;
        }
    }
    if (ink != Ink::Name || name.size() > 64)
        return ink;
    std::array<char16_t, 64> lower;
    std::transform(name.begin(), name.end(), lower.begin(), Lower);
    return LispProcedures().contains(Text(lower.data(), name.size())) ? Ink::Function : Ink::Name;
}

static size_t LispReaderMacro(Text line, size_t start, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    size_t dispatch = start + 1;
    unsigned radix = 0;
    while (Digit(At(line, dispatch))) {
        radix = std::min(37U, radix * 10 + unsigned(line[dispatch] - u'0'));
        ++dispatch;
    }
    char16_t kind = Lower(At(line, dispatch));
    size_t end = dispatch + 1;
    if (end > line.size() || Text(u"\\'(+-.=*#abcoprsx").find(kind) == Text::npos)
        return start;

    state.lispListHead = false;
    state.names.nextName = kind == u'\'' ? NameRole::Function : NameRole::None;
    if (kind == u'\\') {
        char16_t first = At(line, end);
        if (end < line.size())
            ++end;
        else if (!finishLine)
            SetToken(state, LexMode::Raw);
        if (IsLispSymbolPart(first)) {
            while (IsLispSymbolPart(At(line, end)))
                ++end;
        }
        tokens.push_back({start, end - start, Ink::String, true});
    } else if (kind == u'(') {
        // The vector's parenthesis still participates in bracket matching.
        tokens.push_back({start, dispatch - start, Ink::Directive});
    } else {
        if (kind == u'b') radix = 2;
        if (kind == u'o') radix = 8;
        if (kind == u'x') radix = 16;
        Ink ink = Ink::Directive;
        if ((kind == u'b' || kind == u'o' || kind == u'x' || kind == u'r') && radix >= 2 && radix <= 36) {
            size_t payload = end;
            while (IsLispSymbolPart(At(line, end)))
                ++end;
            if (LispNumber(line.substr(payload, end - payload), radix))
                ink = Ink::Number;
        } else if (kind == u'*') {
            while (At(line, end) == u'0' || At(line, end) == u'1')
                ++end;
            ink = Ink::Number;
        }
        tokens.push_back({start, end - start, ink});
    }
    return end;
}

static void TokenizeLisp(Text line, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    const auto language = Language::CommonLisp;
    for (size_t at = 0; at < line.size();) {
        size_t start = at;
        char16_t ch = line[at];
        if (state.mode == LexMode::Quoted) {
            at = ContinueString(line, start, at, language, state, tokens, finishLine);
        } else if (state.mode == LexMode::Raw) {
            bool escaped = true;
            at = LispSymbolEnd(line, at, state, escaped);
            if (at > start)
                tokens.push_back({start, at - start, Ink::Name, true});
        } else if (state.mode == LexMode::BlockComment || state.mode == LexMode::LineComment) {
            at = ContinueComment(line, at, language, state, finishLine);
            tokens.push_back({start, at - start, Ink::Comment, true});
        } else if (at == 0 && line.starts_with(u"#!")) {
            if (!finishLine)
                SetToken(state, LexMode::LineComment);
            tokens.push_back({0, line.size(), Ink::Comment, true});
            return;
        } else if (ch == u';') {
            if (!finishLine)
                SetToken(state, LexMode::LineComment);
            tokens.push_back({start, line.size() - start, Ink::Comment, true});
            return;
        } else if (ch == u'#' && At(line, at + 1) == u'|') {
            size_t body = BlockCommentAt(line, at, language, state);
            at = ContinueComment(line, body, language, state, finishLine);
            tokens.push_back({start, at - start, Ink::Comment, true});
        } else if (ch == u'"') {
            state.lispListHead = false;
            state.names.nextName = NameRole::None;
            SetToken(state, LexMode::Quoted, u"\"", true);
            at = ContinueString(line, start, at + 1, language, state, tokens, finishLine);
        } else if (ch == u'(' || ch == u')') {
            state.lispListHead = ch == u'(';
            state.names.nextName = NameRole::None;
            ++at;
        } else if (ch == u'\'' || ch == u'`' || ch == u',') {
            state.lispListHead = false;
            state.names.nextName = NameRole::None;
            at += ch == u',' && (At(line, at + 1) == u'@' || At(line, at + 1) == u'.') ? 2 : 1;
            tokens.push_back({start, at - start, Ink::Directive});
        } else if (size_t end = ch == u'#' ? LispReaderMacro(line, at, state, tokens, finishLine) : at; end != at) {
            at = end;
        } else if (IsLispSymbolPart(ch) || ch == u'|' || ch == u'\\') {
            bool escaped = false;
            at = LispSymbolEnd(line, at, state, escaped);
            Text word = line.substr(start, at - start);
            if (escaped) {
                state.lispListHead = false;
                state.names.nextName = NameRole::None;
                tokens.push_back({start, at - start, Ink::Name, true});
            } else {
                bool literalBrackets = word.find_first_of(u"[]{}") != Text::npos;
                tokens.push_back({start, at - start, LispWordInk(word, state), literalBrackets});
            }
        } else {
            ++at;
        }
    }
    if (line.empty() && finishLine && state.mode == LexMode::Raw && state.closing.empty())
        SetToken(state);
}

static void TokenizeCode(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    // Fold the language checks out of the inner loop for the original code modes.
    switch (language) {
        case Language::C: return TokenizeCodeInMode<Language::C>(line, language, state, tokens, finishLine);
        case Language::Cpp: return TokenizeCodeInMode<Language::Cpp>(line, language, state, tokens, finishLine);
        case Language::Python: return TokenizeCodeInMode<Language::Python>(line, language, state, tokens, finishLine);
        case Language::Rust: return TokenizeCodeInMode<Language::Rust>(line, language, state, tokens, finishLine);
        case Language::JavaScript: return TokenizeCodeInMode<Language::JavaScript>(line, language, state, tokens, finishLine);
        case Language::CommonLisp: return TokenizeLisp(line, state, tokens, finishLine);
        default: return TokenizeCodeInMode<Language::Count>(line, language, state, tokens, finishLine);
    }
}

static size_t RawElementEnd(Text line, size_t start, RawElement element)
{
    Text endTag = element == RawElement::Style ? u"</style" : u"</script";
    for (size_t at = line.find(u'<', start); at != Text::npos; at = line.find(u'<', at + 1)) {
        if (StartsIgnoringCase(line.substr(at), endTag)) {
            char16_t next = At(line, at + endTag.size());
            if (next == u'>' || next == u'/' || !next || Space(next))
                return at;
        }
    }
    return line.size();
}

static void TokenizeMarkup(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    if (state.mode == LexMode::Code && !state.markup.rawContent && language != Language::PHP)
        state.mode = LexMode::MarkupText;
    for (size_t at = 0; at < line.size();) {
        if (state.markup.rawContent) {
            size_t end = RawElementEnd(line, at, state.markup.rawElement);
            if (state.embedded == Language::Plain) {
                if (end > at)
                    tokens.push_back({at, end - at, Ink::Text, true});
            } else {
                size_t before = tokens.size();
                TokenizeCode(line.substr(at, end - at), state.embedded, state, tokens, end == line.size() && finishLine);
                for (size_t i = before; i < tokens.size(); ++i)
                    tokens[i].start += at;
            }
            if (end == line.size())
                return;
            at = end;
            state.embedded = Language::Plain;
            state.markup = {};
            state.names = {};
            state.interpolations.clear();
            state.expectsValue = true;
            SetToken(state, LexMode::MarkupText);
            continue;
        }
        if (language == Language::PHP && !MarkupMode(state.mode) &&
            !(state.mode == LexMode::BlockComment && state.closing == u"-->")) {
            size_t before = tokens.size();
            TokenizeCode(line.substr(at), language, state, tokens, finishLine);
            for (size_t i = before; i < tokens.size(); ++i)
                tokens[i].start += at;
            return;
        }
        at = MarkupStep(line, at, language, state, tokens);
    }
}

static void TokenizeMarkdown(Text line, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    size_t first = SkipSpace(line, 0);
    char16_t mark = At(line, first);
    size_t run = first;
    if (mark == u'`' || mark == u'~') {
        while (At(line, run) == mark)
            ++run;
    }
    if (state.fence) {
        if (mark == state.fence && run - first >= state.fenceLength && SkipSpace(line, run) == line.size()) {
            tokens.push_back({first, run - first, Ink::Directive, true});
            state = {};
        } else if (state.fenceLanguage == Language::HTML || state.fenceLanguage == Language::XML) {
            TokenizeMarkup(line, state.fenceLanguage, state, tokens, finishLine);
        } else if (state.fenceLanguage != Language::Plain) {
            TokenizeCode(line, state.fenceLanguage, state, tokens, finishLine);
        } else if (!line.empty()) {
            tokens.push_back({0, line.size(), Ink::String, true});
        }
        return;
    }
    if (state.mode == LexMode::Code && first <= 3 && run - first >= 3 &&
        (mark == u'~' || line.find(u'`', run) == Text::npos)) {
        size_t info = SkipSpace(line, run);
        size_t end = info;
        while (end < line.size() && !Space(line[end]))
            ++end;
        state.fence = mark;
        state.fenceLength = unsigned(run - first);
        Text word = line.substr(info, end - info);
        state.fenceLanguage = LanguageForFence(word);
        if (state.fenceLanguage == Language::Markdown)
            state.fenceLanguage = Language::Plain;
        tokens.push_back({first, run - first, Ink::Directive, true});
        if (end > info)
            tokens.push_back({info, end - info, Ink::Type, true});
        return;
    }
    size_t at = first;
    if (state.mode == LexMode::BlockComment) {
        size_t end = line.find(u"-->");
        at = end == Text::npos ? line.size() : end + 3;
        if (at)
            tokens.push_back({0, at, Ink::Comment, true});
        if (end == Text::npos)
            return;
        SetToken(state);
    } else if (mark == u'#') {
        run = first + 1;
        while (At(line, run) == u'#')
            ++run;
        if (run - first <= 6 && (!At(line, run) || Space(line[run]))) {
            tokens.push_back({first, line.size() - first, Ink::Keyword, true});
            return;
        }
    } else if ((mark == u'>' || mark == u'-' || mark == u'+' || mark == u'*') && Space(At(line, first + 1))) {
        tokens.push_back({first, 1, Ink::Directive, true});
        at = first + 1;
    } else if (Digit(mark)) {
        size_t end = first + 1;
        while (Digit(At(line, end)))
            ++end;
        if ((At(line, end) == u'.' || At(line, end) == u')') && Space(At(line, end + 1))) {
            tokens.push_back({first, end + 1 - first, Ink::Directive, true});
            at = end + 1;
        }
    }
    while (at < line.size()) {
        char16_t ch = line[at];
        if (line.substr(at).starts_with(u"<!--")) {
            size_t end = line.find(u"-->", at + 4);
            if (end == Text::npos) {
                SetToken(state, LexMode::BlockComment, u"-->", true);
                tokens.push_back({at, line.size() - at, Ink::Comment, true});
                return;
            }
            tokens.push_back({at, end + 3 - at, Ink::Comment, true});
            at = end + 3;
        } else if (ch == u'\\' && at + 1 < line.size()) {
            tokens.push_back({at, 2, Ink::Escape, true});
            at += 2;
        } else if (ch == u'`' || ch == u'*' || ch == u'_' || ch == u'~') {
            size_t end = at + 1;
            while (At(line, end) == ch)
                ++end;
            Text delimiter = line.substr(at, end - at);
            size_t close = end;
            if (ch == u'`') {
                // Code spans must use a closing run of the same length.
                while ((close = line.find(u'`', close)) != Text::npos) {
                    size_t after = close + 1;
                    while (At(line, after) == u'`')
                        ++after;
                    if (after - close == delimiter.size())
                        break;
                    close = after;
                }
            } else {
                close = line.find(delimiter, end);
                if ((ch == u'~' && delimiter.size() != 2) || Space(At(line, end)) ||
                    (ch == u'_' && at && NamePart(line[at - 1])))
                    close = Text::npos;
            }
            if (close != Text::npos && close > end) {
                size_t after = close + delimiter.size();
                tokens.push_back({at, after - at, ch == u'`' ? Ink::String : Ink::Type, true});
                at = after;
            } else {
                at = end;
            }
        } else if (ch == u'[' || (ch == u'!' && At(line, at + 1) == u'[')) {
            size_t caption = line.find(u']', at + 1);
            size_t end = Text::npos;
            if (caption != Text::npos && At(line, caption + 1) == u'(') {
                unsigned nesting = 1;
                for (size_t i = caption + 2; i < line.size(); ++i) {
                    if (line[i] == u'\\')
                        ++i;
                    else if (line[i] == u'(')
                        ++nesting;
                    else if (line[i] == u')' && --nesting == 0) {
                        end = i;
                        break;
                    }
                }
            }
            if (end != Text::npos) {
                tokens.push_back({at, caption + 1 - at, Ink::Function, true});
                tokens.push_back({caption + 1, end - caption, Ink::String, true});
                at = end + 1;
            } else {
                ++at;
            }
        } else {
            ++at;
        }
    }
}

void TokenizeLine(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finishLine)
{
    tokens.clear();
    if (language == Language::Plain || language == Language::Count)
        return;
    if (language == Language::Markdown) {
        TokenizeMarkdown(line, state, tokens, finishLine);
    } else if (language == Language::HTML || language == Language::XML) {
        TokenizeMarkup(line, language, state, tokens, finishLine);
    } else if (language == Language::PHP) {
        Text rest = line.substr(SkipSpace(line, 0));
        if (state.mode == LexMode::Code && !state.markup.rawContent && !PHPTag(rest) &&
            rest.starts_with(u"<") && (NameStart(At(rest, 1)) || rest.starts_with(u"<!")))
            state.mode = LexMode::MarkupText;
        TokenizeMarkup(line, language, state, tokens, finishLine);
    } else if (language == Language::Makefile && line.starts_with(u"\t")) {
        TokenizeCode(line, Language::Bash, state, tokens, finishLine);
    } else {
        TokenizeCode(line, language, state, tokens, finishLine);
    }
}