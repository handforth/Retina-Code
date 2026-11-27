// The syntax lexer. See Lexer.hpp for how lines and state fit together.
//
// tokenize_line() picks a tokenizer for the language: Markdown, markup (HTML, XML, PHP), Common Lisp, or the
// general code tokenizer that handles every other language. Each one walks the line left to right, adds a token
// for every colored span, and updates the state that carries into the next line.

#include "Lexer.hpp"

#include <atomic>
#include <cstdlib>
#include <mutex>

// Lines and words are UTF-16 views into the editor's text.
typedef std::u16string_view Text;

static const size_t NOT_FOUND = Text::npos;

//
// Characters.
//

static char16_t char_at(Text line, size_t index)
{
    return index < line.size() ? line[index] : 0;
}

// One byte of flags per ASCII character, so each character test is one table lookup.
constexpr uint8_t CHAR_SPACE = 1 << 0;         // space, tab, vertical tab, and form feed
constexpr uint8_t CHAR_DIGIT = 1 << 1;
constexpr uint8_t CHAR_HEX_LETTER = 1 << 2;    // a-f and A-F
constexpr uint8_t CHAR_NAME_START = 1 << 3;    // letters, _ and $
constexpr uint8_t CHAR_VALUE_FOLLOWS = 1 << 4;  // punctuation after which a value starts, so / begins a regex

struct CharClassTable {
    uint8_t flags[128];
};

static constexpr CharClassTable make_char_class_table()
{
    CharClassTable table = {};
    for (int ch = 0; ch < 128; ++ch) {
        uint8_t flags = 0;
        if (ch == ' ' || ch == '\t' || ch == '\v' || ch == '\f')
            flags |= CHAR_SPACE;
        if (ch >= '0' && ch <= '9')
            flags |= CHAR_DIGIT;
        if ((ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))
            flags |= CHAR_HEX_LETTER;
        if (is_ascii_identifier_start(char16_t(ch)))
            flags |= CHAR_NAME_START;

        for (const char *punctuation = "=(:,[!&|?;{}"; *punctuation; ++punctuation) {
            if (ch == *punctuation)
                flags |= CHAR_VALUE_FOLLOWS;
        }

        table.flags[ch] = flags;
    }

    return table;
}

static constexpr CharClassTable CHAR_CLASSES = make_char_class_table();

static bool has_char_class(char16_t ch, uint8_t flags)
{
    return ch < 128 && (CHAR_CLASSES.flags[ch] & flags);
}

static bool is_digit(char16_t ch)
{
    return has_char_class(ch, CHAR_DIGIT);
}

static bool is_hex_digit(char16_t ch)
{
    return has_char_class(ch, CHAR_DIGIT | CHAR_HEX_LETTER);
}

// Space inside a line. The editors never pass line breaks to the lexer.
static bool is_space(char16_t ch)
{
    return has_char_class(ch, CHAR_SPACE);
}

// Any character outside ASCII can be part of a name.
static bool is_name_start(char16_t ch)
{
    return ch >= 0x80 || has_char_class(ch, CHAR_NAME_START);
}

static bool is_name_char(char16_t ch)
{
    return ch >= 0x80 || has_char_class(ch, CHAR_NAME_START | CHAR_DIGIT);
}

static char16_t lowercase(char16_t ch)
{
    return ch >= u'A' && ch <= u'Z' ? char16_t(ch + (u'a' - u'A')) : ch;
}

static bool starts_with_ignoring_case(Text text, Text prefix)
{
    if (text.size() < prefix.size())
        return false;

    for (size_t at = 0; at < prefix.size(); ++at) {
        if (lowercase(text[at]) != lowercase(prefix[at]))
            return false;
    }

    return true;
}

static bool same_units(const char16_t *a, const char16_t *b, size_t count)
{
    for (size_t at = 0; at < count; ++at) {
        if (a[at] != b[at])
            return false;
    }

    return true;
}

static bool same_text(Text a, Text b)
{
    return a.size() == b.size() && same_units(a.data(), b.data(), a.size());
}

static bool starts_at(Text line, size_t index, Text text)
{
    return index <= line.size() && line.size() - index >= text.size() && same_units(line.data() + index, text.data(), text.size());
}

static bool is_any_of(char16_t ch, Text set)
{
    for (char16_t member : set) {
        if (ch == member)
            return true;
    }

    return false;
}

static size_t skip_spaces(Text line, size_t index)
{
    while (is_space(char_at(line, index)))
        ++index;

    return index;
}

static size_t previous_non_space(Text line, size_t index)
{
    while (index && is_space(line[index - 1]))
        --index;

    return index;
}

static size_t name_end(Text line, size_t index)
{
    while (is_name_char(char_at(line, index)))
        ++index;

    return index;
}

// Ruby method names can end in ? or ! (but not != ).
static size_t ruby_name_end(Text line, size_t index)
{
    size_t end = name_end(line, index);
    char16_t suffix = char_at(line, end);
    if (suffix == u'?' || (suffix == u'!' && char_at(line, end + 1) != u'='))
        ++end;

    return end;
}

// Skips spaces and /* ... */ comments. A // comment runs to the end of the line.
static size_t skip_spaces_and_comments(Text line, size_t index)
{
    index = skip_spaces(line, index);
    while (starts_at(line, index, u"/*")) {
        size_t end = line.find(u"*/", index + 2);
        if (end == NOT_FOUND)
            return line.size();

        index = skip_spaces(line, end + 2);
    }

    return starts_at(line, index, u"//") ? line.size() : index;
}

// A whole word at index: the text followed by a character that can't continue a name.
static bool is_word_at(Text line, size_t index, Text word)
{
    return starts_at(line, index, word) && !is_name_char(char_at(line, index + word.size()));
}

static bool is_scope_operator_at(Text line, size_t index)
{
    return char_at(line, index) == u':' && char_at(line, index + 1) == u':';
}

// A < that can open a generic list, and not << or <=.
static bool opens_angle_bracket(Text line, size_t index)
{
    return char_at(line, index) == u'<' && char_at(line, index + 1) != u'<' && char_at(line, index + 1) != u'=';
}

static bool is_in_sorted_list(Text word, const Text *list, size_t count)
{
    size_t low = 0, high = count;
    while (low < high) {
        size_t middle = (low + high) / 2;
        if (list[middle] == word)
            return true;

        if (list[middle] < word)
            low = middle + 1;
        else
            high = middle;
    }

    return false;
}

// FNV-1a over UTF-16 units.
static uint32_t hash_word(Text word)
{
    uint32_t hash = 2166136261u;
    for (char16_t ch : word) {
        hash ^= ch;
        hash *= 16777619u;
    }

    return hash;
}

//
// Tokens.
//

static void add_token(std::vector<Token> &tokens, size_t start, size_t length, Ink ink, bool non_code = false)
{
    // Spans longer than a token can hold continue in the next token.
    while (length > 0xFFFF) {
        tokens.push_back({uint32_t(start), uint16_t(0xFFFF), ink, non_code});
        start += 0xFFFF;
        length -= 0xFFFF;
    }

    tokens.push_back({uint32_t(start), uint16_t(length), ink, non_code});
}

//
// Language groups.
//

static bool is_shell(Language language)
{
    return language == Language::Bash || language == Language::Zsh || language == Language::Fish;
}

static bool is_lua_family(Language language)
{
    return language == Language::Lua || language == Language::Luau;
}

static bool is_jsx(Language language)
{
    return language == Language::JSX || language == Language::TSX;
}

static bool is_css_family(Language language)
{
    return language == Language::CSS || language == Language::SCSS || language == Language::Less;
}

static bool is_json_family(Language language)
{
    return language == Language::JSON || language == Language::JSONC;
}

static bool is_ini_or_toml(Language language)
{
    return language == Language::TOML || language == Language::INI;
}

// Languages where "$name" inside a string inserts a variable without braces.
static bool interpolates_bare_variables(Language language)
{
    return is_shell(language) || language == Language::Kotlin || language == Language::Dart ||
           language == Language::PHP || language == Language::Scala || language == Language::Groovy ||
           language == Language::PowerShell;
}

//
// Keyword tables.
//

constexpr uint8_t WORD_CONTROL = 1 << 0;
constexpr uint8_t WORD_CONSTANT = 1 << 1;
constexpr uint8_t WORD_KEYWORD = 1 << 2;
constexpr uint8_t WORD_TYPE = 1 << 3;
constexpr uint8_t WORD_LISP_PROCEDURE = 1 << 4;
constexpr uint8_t WORD_CPP_LIBRARY_TYPE = 1 << 5;    // a std:: type, colored only after std::

// Built-in procedures. The Odin list is sorted for binary search.
static constexpr Text ODIN_PROCEDURES[] = {
    u"abs", u"align_of", u"append", u"append_elem", u"append_elems", u"assert", u"cap", u"clamp", u"clear",
    u"complex", u"compress_values", u"conj", u"delete", u"expand_values", u"free", u"free_all", u"imag", u"jmag",
    u"kmag", u"len", u"make", u"max", u"min", u"new", u"offset_of", u"offset_of_by_string", u"panic", u"pop",
    u"quaternion", u"raw_data", u"real", u"reserve", u"resize", u"size_of", u"soa_unzip", u"soa_zip", u"swizzle",
    u"type_info_of", u"type_of", u"typeid_of", u"unreachable",
};
static constexpr size_t ODIN_PROCEDURE_COUNT = sizeof ODIN_PROCEDURES / sizeof ODIN_PROCEDURES[0];

static constexpr Text GML_PROCEDURES =
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

static constexpr Text LISP_PROCEDURES =
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
    u"type-of typep union values values-list vectorp warn write write-char write-line write-string zerop";

static constexpr Text CPP_LIBRARY_TYPES =
    u"any array atomic basic_string basic_string_view bitset complex deque duration "
    u"enable_if expected false_type filesystem_error function future initializer_list integral_constant "
    u"istream iterator_traits jthread list lock_guard map multimap multiset mutex numeric_limits optional ostream "
    u"pair path priority_queue promise queue ratio reference_wrapper regex remove_cv remove_reference "
    u"set shared_lock shared_mutex shared_ptr span stack string string_view stringstream thread time_point "
    u"true_type tuple underlying_type unique_lock unique_ptr unordered_map unordered_multimap unordered_multiset "
    u"unordered_set u8string u16string u32string variant vector weak_ptr wstring";

struct KeywordSlot {
    const char16_t *text;    // points into the static word lists
    uint32_t hash;
    uint16_t length;
    uint8_t flags;           // zero for an empty slot
    uint8_t unused;
};

struct Vocabulary {
    std::vector<KeywordSlot> slots;           // open-addressing hash table with a power-of-two size
    std::vector<Text> completion_words;       // sorted, without duplicates
    std::vector<char16_t> uppercase_text;     // SQL and Lisp also complete each word in uppercase
};

// The slot holding the word, or the empty slot where it would go.
static size_t keyword_slot_index(const std::vector<KeywordSlot> &slots, Text word, uint32_t hash)
{
    size_t mask = slots.size() - 1;
    size_t index = hash & mask;
    for (;;) {
        const KeywordSlot &slot = slots[index];
        if (!slot.flags)
            return index;

        if (slot.hash == hash && slot.length == word.size() && same_units(slot.text, word.data(), word.size()))
            return index;

        index = (index + 1) & mask;
    }
}

// Adds every word of a list separated by spaces. Words with flags also go into the keyword table.
static void add_words(Vocabulary &vocabulary, std::vector<KeywordSlot> &words, Text list, uint8_t flags)
{
    while (!list.empty()) {
        size_t end = list.find(u' ');
        if (end) {
            Text word = list.substr(0, end);
            if (flags)
                words.push_back({word.data(), hash_word(word), uint16_t(word.size()), flags, 0});
            if (flags != WORD_CPP_LIBRARY_TYPE)
                vocabulary.completion_words.push_back(word);
        }

        if (end == NOT_FOUND)
            break;
        list.remove_prefix(end + 1);
    }
}

static void add_language_words(Vocabulary &vocabulary, std::vector<KeywordSlot> &words, Language language)
{
    const LanguageInfo &info = language_info(language);
    add_words(vocabulary, words, info.keywords, WORD_KEYWORD);
    add_words(vocabulary, words, info.types, WORD_TYPE);
    add_words(vocabulary, words, info.control, WORD_CONTROL);
    add_words(vocabulary, words, info.constants, WORD_CONSTANT);
}

static int compare_texts(const void *a, const void *b)
{
    const Text &left = *(const Text *)a;
    const Text &right = *(const Text *)b;
    return left < right ? -1 : left == right ? 0 : 1;
}

static void sort_and_remove_duplicates(std::vector<Text> &words)
{
    if (words.empty())
        return;

    qsort(words.data(), words.size(), sizeof(Text), compare_texts);

    size_t kept = 1;
    for (size_t at = 1; at < words.size(); ++at) {
        if (words[at] != words[kept - 1])
            words[kept++] = words[at];
    }
    words.resize(kept);
}

static void build_vocabulary(Vocabulary &vocabulary, Language language)
{
    std::vector<KeywordSlot> words;
    add_language_words(vocabulary, words, language);

    // Some languages borrow another language's words.
    switch (language) {
        case Language::ObjectiveC: add_language_words(vocabulary, words, Language::C); break;
        case Language::ObjectiveCpp: add_language_words(vocabulary, words, Language::Cpp); break;
        case Language::Cpp: add_words(vocabulary, words, CPP_LIBRARY_TYPES, WORD_CPP_LIBRARY_TYPE); break;
        case Language::GML: add_words(vocabulary, words, GML_PROCEDURES, 0); break;
        case Language::CommonLisp: add_words(vocabulary, words, LISP_PROCEDURES, WORD_LISP_PROCEDURE); break;
        case Language::SCSS: case Language::Less: add_words(vocabulary, words, language_info(Language::CSS).keywords, 0); break;
        case Language::Odin:
            for (size_t at = 0; at < ODIN_PROCEDURE_COUNT; ++at)
                vocabulary.completion_words.push_back(ODIN_PROCEDURES[at]);
            break;
        default: break;
    }

    // A word in two lists gets both sets of flags.
    if (!words.empty()) {
        size_t slot_count = 1;
        while (slot_count < words.size() + words.size() / 4 + 1)
            slot_count *= 2;
        vocabulary.slots.resize(slot_count);

        for (KeywordSlot word : words) {
            KeywordSlot &slot = vocabulary.slots[keyword_slot_index(vocabulary.slots, Text(word.text, word.length), word.hash)];
            word.flags |= slot.flags;
            slot = word;
        }
    }

    std::vector<Text> &completion = vocabulary.completion_words;
    sort_and_remove_duplicates(completion);

    // SQL and Lisp code is often written in uppercase, so completion offers both spellings.
    if (language == Language::SQL || language == Language::CommonLisp) {
        size_t units = 0;
        for (Text word : completion)
            units += word.size();
        vocabulary.uppercase_text.resize(units);

        char16_t *out = vocabulary.uppercase_text.data();
        size_t count = completion.size();
        completion.reserve(count * 2);
        for (size_t index = 0; index < count; ++index) {
            Text word = completion[index];
            for (size_t at = 0; at < word.size(); ++at) {
                char16_t ch = word[at];
                out[at] = ch >= u'a' && ch <= u'z' ? char16_t(ch - (u'a' - u'A')) : ch;
            }

            completion.push_back(Text(out, word.size()));
            out += word.size();
        }

        sort_and_remove_duplicates(completion);
    }

    // The tables never grow after this.
    completion.shrink_to_fit();
}

static Vocabulary VOCABULARIES[size_t(Language::Count)];
static std::atomic<bool> VOCABULARY_BUILT[size_t(Language::Count)];
static std::mutex VOCABULARY_BUILD_LOCK;

// A language's tables are built the first time it's lexed, so a session only pays for the languages it opens.
// The AppKit runner also lexes on background threads, so the first build takes a lock, and the flag tells every
// later lookup on any thread that the tables are complete.
static const Vocabulary &vocabulary_for(Language language)
{
    size_t index = size_t(language);
    if (index >= size_t(Language::Count))
        index = 0;

    if (!VOCABULARY_BUILT[index].load(std::memory_order_acquire)) {
        VOCABULARY_BUILD_LOCK.lock();
        if (!VOCABULARY_BUILT[index].load(std::memory_order_relaxed)) {
            build_vocabulary(VOCABULARIES[index], Language(index));
            VOCABULARY_BUILT[index].store(true, std::memory_order_release);
        }
        VOCABULARY_BUILD_LOCK.unlock();
    }

    return VOCABULARIES[index];
}

const std::vector<Text> &completion_words(Language language)
{
    return vocabulary_for(language).completion_words;
}

static uint8_t word_flags(Language language, Text word)
{
    const std::vector<KeywordSlot> &slots = vocabulary_for(language).slots;
    if (slots.empty())
        return 0;

    return slots[keyword_slot_index(slots, word, hash_word(word))].flags;
}

// The color of a word from the keyword tables and its shape. next is the first character after the word.
// Case-insensitive languages keep their keywords in lowercase. A word longer than 64 units is looked up as it is.
static uint8_t word_flags_ignoring_case(Language language, Text word)
{
    if (word.size() > 64)
        return word_flags(language, word);

    char16_t lowered[64];
    for (size_t at = 0; at < word.size(); ++at)
        lowered[at] = lowercase(word[at]);

    return word_flags(language, Text(lowered, word.size()));
}

static Ink word_ink(Text word, Language language, char16_t next)
{
    const LanguageInfo &info = language_info(language);
    uint8_t flags = info.ignore_case ? word_flags_ignoring_case(language, word) : word_flags(language, word);
    if (flags & WORD_CONTROL)
        return Ink::Control;
    if (flags & WORD_CONSTANT)
        return Ink::Constant;
    if (flags & WORD_KEYWORD)
        return Ink::Keyword;
    if (flags & WORD_TYPE)
        return Ink::Type;

    if ((flags & WORD_LISP_PROCEDURE) || next == u'(' || (language == Language::Rust && next == u'!'))
        return Ink::Function;

    if (is_c_family(language) && word.ends_with(u"_t"))
        return Ink::Type;

    if (info.ignore_case)
        return Ink::Name;

    // Capitalized words are types, and words in all capitals are constants. GameMaker capitalizes plain names.
    if (word.size() > 1 && word.front() >= u'A' && word.front() <= u'Z') {
        for (char16_t ch : word) {
            if (ch >= u'a' && ch <= u'z')
                return language == Language::GML ? Ink::Name : Ink::Type;
        }

        return Ink::Constant;
    }

    return Ink::Name;
}

//
// Closing delimiters. See LexClosing in Lexer.hpp.
//

// Delimiters made of a head, a run of one repeated character, and a tail, such as ]===] or """###.
static bool closing_fits(size_t head_length, size_t run_length, size_t tail_length)
{
    if (head_length + run_length + tail_length <= LEX_CLOSING_TEXT_LIMIT)
        return true;

    return head_length + tail_length <= LEX_CLOSING_TEXT_LIMIT && run_length <= 0xFFFF;
}

// A delimiter that fits the text buffer is always stored as plain text, so equal delimiters compare equal.
static void set_closing(LexClosing &closing, Text head, char16_t run_unit, size_t run_length, Text tail)
{
    closing = {};

    size_t total = head.size() + run_length + tail.size();
    if (total <= LEX_CLOSING_TEXT_LIMIT) {
        size_t at = 0;
        for (char16_t ch : head)
            closing.text[at++] = ch;
        for (size_t count = 0; count < run_length; ++count)
            closing.text[at++] = run_unit;
        for (char16_t ch : tail)
            closing.text[at++] = ch;
        closing.length = uint8_t(at);
        return;
    }

    for (size_t at = 0; at < head.size(); ++at)
        closing.text[at] = head[at];
    for (size_t at = 0; at < tail.size(); ++at)
        closing.text[head.size() + at] = tail[at];

    closing.length = uint8_t(head.size() + tail.size());
    closing.run_at = uint8_t(head.size());
    closing.run_unit = run_unit;
    closing.run_length = uint16_t(run_length);
}

static void set_closing(LexClosing &closing, Text text)
{
    set_closing(closing, text, 0, 0, {});
}

static size_t closing_size(const LexClosing &closing)
{
    return closing.length + closing.run_length;
}

static bool closing_is_empty(const LexClosing &closing)
{
    return closing_size(closing) == 0;
}

static char16_t closing_first_unit(const LexClosing &closing)
{
    return closing.run_length && closing.run_at == 0 ? closing.run_unit : closing.text[0];
}

static bool closing_at(Text line, size_t index, const LexClosing &closing)
{
    if (!closing.run_length)
        return starts_at(line, index, Text(closing.text, closing.length));

    Text head(closing.text, closing.run_at);
    Text tail(closing.text + closing.run_at, closing.length - closing.run_at);
    if (!starts_at(line, index, head))
        return false;

    index += head.size();
    for (size_t count = 0; count < closing.run_length; ++count) {
        if (char_at(line, index++) != closing.run_unit)
            return false;
    }

    return starts_at(line, index, tail);
}

static size_t find_closing(Text line, size_t index, const LexClosing &closing)
{
    if (!closing.run_length)
        return line.find(Text(closing.text, closing.length), index);

    for (; index < line.size(); ++index) {
        if (closing_at(line, index, closing))
            return index;
    }

    return NOT_FOUND;
}

// The # count of a Swift raw string's delimiter, such as 2 for "##.
static size_t swift_hash_count(const LexClosing &closing)
{
    if (closing.run_length)
        return closing.run_length;

    Text text(closing.text, closing.length);
    size_t first = text.find(u'#');
    return first == NOT_FOUND ? 0 : text.size() - first;
}

//
// Modes and stacks of the state.
//

// Switches mode and forgets everything about the string or comment that was open.
static void set_mode(LexState &state, LexMode mode, bool multiline = false, bool highlight_escapes = true)
{
    state.mode = mode;
    state.depth = 0;
    state.closing = {};
    state.multiline = multiline;
    state.highlight_escapes = highlight_escapes;
    state.doubled_quote = false;
    state.string_opening = 0;
    state.string_ink = Ink::String;
    state.interpolation = Interpolation::None;
}

static void set_mode_and_closing(LexState &state, LexMode mode, Text closing, bool multiline = false,
                                 bool highlight_escapes = true)
{
    set_mode(state, mode, multiline, highlight_escapes);
    set_closing(state.closing, closing);
}

// Suspends the open string while an embedded expression such as ${x} is lexed as code.
static bool push_interpolation(LexState &state)
{
    if (state.interpolation_count == LEX_INTERPOLATION_LIMIT)
        return false;

    LexInterpolation &frame = state.interpolations[state.interpolation_count++];
    frame.closing = state.closing;
    frame.string_opening = state.string_opening;
    frame.braces = 1;
    frame.string_nesting = uint16_t(state.depth);
    frame.mode = state.mode;
    frame.kind = state.interpolation;
    frame.ink = state.string_ink;
    frame.multiline = state.multiline;
    frame.highlight_escapes = state.highlight_escapes;
    frame.doubled_quote = state.doubled_quote;

    set_mode(state, LexMode::Code);
    return true;
}

// Returns to the suspended string when its embedded expression ends.
static void pop_interpolation(LexState &state)
{
    LexInterpolation &frame = state.interpolations[--state.interpolation_count];
    set_mode(state, frame.mode, frame.multiline, frame.highlight_escapes);
    state.closing = frame.closing;
    state.string_ink = frame.ink;
    state.interpolation = frame.kind;
    state.doubled_quote = frame.doubled_quote;
    state.string_opening = frame.string_opening;
    state.depth = frame.string_nesting;

    frame = {};
}

static void clear_interpolations(LexState &state)
{
    for (LexInterpolation &frame : state.interpolations)
        frame = {};
    state.interpolation_count = 0;
}

static bool push_heredoc(LexState &state, Text terminator, bool indent, bool expand)
{
    if (state.heredoc_count == LEX_HEREDOC_LIMIT || terminator.size() > size_t(LEX_HEREDOC_TEXT_LIMIT - state.heredoc_text_used))
        return false;

    for (size_t at = 0; at < terminator.size(); ++at)
        state.heredoc_text[state.heredoc_text_used + at] = terminator[at];

    state.heredocs[state.heredoc_count++] = {uint8_t(terminator.size()), indent, expand};
    state.heredoc_text_used = uint8_t(state.heredoc_text_used + terminator.size());
    return true;
}

static Text first_heredoc_terminator(const LexState &state)
{
    return Text(state.heredoc_text, state.heredocs[0].length);
}

// Here-documents end in the order they started, so the first one goes and the rest move up.
static void pop_first_heredoc(LexState &state)
{
    size_t removed = state.heredocs[0].length;
    for (size_t at = removed; at < state.heredoc_text_used; ++at)
        state.heredoc_text[at - removed] = state.heredoc_text[at];
    for (size_t at = state.heredoc_text_used - removed; at < state.heredoc_text_used; ++at)
        state.heredoc_text[at] = 0;

    for (size_t at = 1; at < state.heredoc_count; ++at)
        state.heredocs[at - 1] = state.heredocs[at];
    state.heredocs[state.heredoc_count - 1] = {};

    state.heredoc_count -= 1;
    state.heredoc_text_used = uint8_t(state.heredoc_text_used - removed);
}

static void push_generic(LexNames &names, Text name, Ink ink)
{
    if (names.generic_count == LEX_GENERIC_LIMIT || name.size() > 0xFF)
        return;

    names.generics[names.generic_count++] = {hash_word(name), names.brace_depth, uint8_t(name.size()), ink};
}

static const LexGeneric *find_generic(const LexNames &names, Text name)
{
    uint32_t hash = hash_word(name);
    for (size_t index = names.generic_count; index > 0; --index) {
        const LexGeneric &generic = names.generics[index - 1];
        if (generic.name_length == name.size() && generic.name_hash == hash)
            return &generic;
    }

    return nullptr;
}

//
// C++, Rust, and similar code: names colored by what they declare.
//

// Where the template arguments of name<...> end, for telling a<b> from a < b. Returns NOT_FOUND when the
// brackets don't close like a template's.
static size_t cpp_template_arguments_end(Text line, size_t open)
{
    // The lookahead stops after 512 units. Known types and template headers never need it.
    Text probe = line.substr(0, open + 512 < line.size() ? open + 512 : line.size());
    unsigned angles = 1;
    unsigned groups = 0;

    for (size_t at = skip_spaces_and_comments(probe, open + 1); at < probe.size(); at = skip_spaces_and_comments(probe, at + 1)) {
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
            if (!opens_angle_bracket(probe, at))
                break;
            ++angles;
        } else if (ch == u'>' && char_at(probe, at - 1) != u'-' && char_at(probe, at + 1) != u'=') {
            if (--angles == 0)
                return skip_spaces_and_comments(line, at + 1);
        } else if (ch == u';' || ch == u')' || ch == u']' || ch == u'}' || ch == u'=' ||
                   (ch == u'&' && char_at(probe, at + 1) == u'&') || (ch == u'|' && char_at(probe, at + 1) == u'|')) {
            break;
        }
    }

    return NOT_FOUND;
}

static bool at_generic_parameter_start(const LexNames &names)
{
    return names.parameter_start && names.angles == 1 && names.argument_groups == 0;
}

static void clear_name_expectation(LexNames &names)
{
    names.next_name = NameRole::None;
    names.next_angle = AngleRole::None;
    names.qualified = false;
    names.standard_path = false;
}

// After a keyword in Rust: what the keyword tells about the names that follow.
static void expect_after_rust_keyword(Text line, Text word, size_t next, char16_t follow, NameRole role,
                                      bool parameter_start, LexNames &names)
{
    if (same_text(word, u"fn") || same_text(word, u"macro") || (same_text(word, u"macro_rules") && follow == u'!')) {
        names.next_name = NameRole::Function;
        names.rust_header = same_text(word, u"fn");
    } else if (same_text(word, u"struct") || same_text(word, u"enum") || same_text(word, u"trait") || same_text(word, u"type") || same_text(word, u"union")) {
        names.next_name = NameRole::RustItem;
        names.type_alias = same_text(word, u"type");
        names.rust_header = true;
    } else if (same_text(word, u"mod")) {
        names.next_name = NameRole::Type;
    } else if (same_text(word, u"use") && !opens_angle_bracket(line, next)) {
        names.rust_import = true;
    } else if (same_text(word, u"impl")) {
        names.next_name = NameRole::Type;
        names.next_angle = AngleRole::Parameters;
        names.rust_header = true;
    } else if ((same_text(word, u"as") && !names.rust_import) || same_text(word, u"dyn")) {
        names.next_name = NameRole::Type;
    } else if (same_text(word, u"const") && parameter_start) {
        names.next_name = NameRole::ValueParameter;
    } else if (same_text(word, u"mut") || same_text(word, u"const")) {
        // These don't change what the next name is.
        names.next_name = role;
    } else if (same_text(word, u"let") || same_text(word, u"where")) {
        names.rust_header = true;
    }
}

// After a keyword in C++: what the keyword tells about the names that follow.
static void expect_after_cpp_keyword(Text word, bool was_qualified, NameRole role, bool parameter_start, LexNames &names)
{
    if (same_text(word, u"template")) {
        names.next_angle = was_qualified || names.angles ? AngleRole::Arguments : AngleRole::Parameters;
    } else if (same_text(word, u"typename") || same_text(word, u"class") || same_text(word, u"struct") ||
               same_text(word, u"enum") || same_text(word, u"union") || same_text(word, u"concept") || same_text(word, u"namespace")) {
        bool type_parameter = parameter_start && (same_text(word, u"typename") || same_text(word, u"class"));
        names.next_name = type_parameter ? NameRole::TypeParameter : NameRole::Type;
        if (same_text(word, u"namespace"))
            names.type_alias = true;
    } else if (same_text(word, u"using")) {
        names.type_alias = true;
    } else if (same_text(word, u"auto") && parameter_start) {
        names.next_name = NameRole::ValueParameter;
    } else if ((same_text(word, u"const") || same_text(word, u"volatile")) && parameter_start) {
        names.next_name = role;
    } else if (same_text(word, u"static_cast") || same_text(word, u"dynamic_cast") || same_text(word, u"reinterpret_cast") || same_text(word, u"const_cast")) {
        names.next_angle = AngleRole::Arguments;
    }
}

// The color of a word in C++ or Rust. end is where the word ends. raw marks a Rust raw identifier, r#name.
static Ink contextual_word_ink(Text line, Text word, size_t end, Language language, LexNames &names, bool raw)
{
    bool rust = language == Language::Rust;

    // Take what the previous tokens expected; this word answers it.
    bool was_qualified = names.qualified;
    bool standard = was_qualified && names.standard_path;
    NameRole role = names.next_name;
    names.qualified = false;
    names.next_name = NameRole::None;
    names.next_angle = AngleRole::None;

    size_t next = skip_spaces_and_comments(line, end);
    bool qualifier = is_scope_operator_at(line, next);
    bool turbofish = rust && qualifier && opens_angle_bracket(line, skip_spaces_and_comments(line, next + 2));
    names.standard_path = !rust && qualifier && (standard || same_text(word, u"std"));

    // In Rust, name != value isn't a macro call.
    char16_t follow = char_at(line, next);
    if (rust && follow == u'!' && char_at(line, next + 1) == u'=')
        follow = u'=';

    Ink ink = raw ? (follow == u'(' ? Ink::Function : Ink::Name) : word_ink(word, language, follow);
    bool parameter_start = at_generic_parameter_start(names);

    if (!raw && (same_text(word, u"true") || same_text(word, u"false") || (!rust && same_text(word, u"nullptr"))))
        return Ink::Keyword;
    if (!raw && rust && same_text(word, u"Self"))
        return Ink::Type;

    // Rust words that are keywords only in some places.
    if (rust && !raw) {
        if (same_text(word, u"union") && follow && !is_name_start(follow))
            ink = follow == u'(' ? Ink::Function : Ink::Name;
        if (same_text(word, u"raw") && (is_word_at(line, next, u"const") || is_word_at(line, next, u"mut")))
            return Ink::Keyword;
        if (same_text(word, u"safe") && (is_word_at(line, next, u"fn") || is_word_at(line, next, u"static")))
            return Ink::Keyword;
    }

    if (ink == Ink::Keyword || ink == Ink::Control || (!raw && same_text(word, u"macro_rules") && follow == u'!')) {
        if (rust)
            expect_after_rust_keyword(line, word, next, follow, role, parameter_start, names);
        else
            expect_after_cpp_keyword(word, was_qualified, role, parameter_start, names);

        if (!rust && (same_text(word, u"using") || same_text(word, u"operator") || same_text(word, u"new") || same_text(word, u"delete")))
            return Ink::Control;

        return ink;
    }

    // The name that a declaration keyword announced.
    if (role == NameRole::Function || role == NameRole::RustItem) {
        names.next_angle = AngleRole::Parameters;
        return role == NameRole::Function ? Ink::Function : Ink::Type;
    }

    // A new generic parameter: remember it so its uses get the same color.
    bool new_type_parameter = !qualifier && ((rust && parameter_start && role == NameRole::None) ||
                                             role == NameRole::TypeParameter);
    if (new_type_parameter || role == NameRole::ValueParameter) {
        ink = new_type_parameter ? Ink::Type : Ink::Name;
        push_generic(names, word, ink);
        names.parameter_start = false;
        return ink;
    }

    const LexGeneric *parameter = find_generic(names, word);
    if (parameter) {
        ink = parameter->ink;
    } else if (role == NameRole::Type || role == NameRole::TypeParameter ||
               (standard && (word_flags(Language::Cpp, word) & WORD_CPP_LIBRARY_TYPE)) ||
               (names.type_alias && follow == u'=') || (qualifier && !turbofish)) {
        ink = Ink::Type;
    }

    if (!rust && parameter_start && ink == Ink::Type && !qualifier && is_name_start(follow))
        names.next_name = NameRole::ValueParameter;
    if (qualifier && (role == NameRole::Type || role == NameRole::TypeParameter))
        names.next_name = NameRole::Type;

    if (turbofish) {
        if (ink == Ink::Name)
            ink = Ink::Function;
    } else if (opens_angle_bracket(line, next)) {
        if (ink == Ink::Type) {
            names.next_angle = AngleRole::Arguments;
        } else if (!rust && !parameter && (next == end || was_qualified)) {
            // name<...>( is a function template call, and name<...>:: is a class template.
            size_t tail = cpp_template_arguments_end(line, next);
            if (tail != NOT_FOUND && (char_at(line, tail) == u'(' || is_scope_operator_at(line, tail))) {
                ink = char_at(line, tail) == u'(' ? Ink::Function : Ink::Type;
                names.next_angle = AngleRole::Arguments;
            }
        }
    } else if (!parameter && ink == Ink::Name && names.angles && !names.parameter_list && !names.argument_groups &&
               word.size() == 1 && word[0] >= u'A' && word[0] <= u'Z') {
        // A single capital letter among template arguments is a type.
        ink = Ink::Type;
    }

    // A use tree colors path segments and type names. Its plain value imports keep the foreground color.
    if (names.rust_import && ink == Ink::Name)
        return Ink::Text;

    // C++ built-in types like int and bool look like keywords, except the library's size_t, ptrdiff_t, and FILE.
    if (!rust && ink == Ink::Type && (word_flags(Language::Cpp, word) & WORD_TYPE) &&
        !same_text(word, u"size_t") && !same_text(word, u"ptrdiff_t") && !same_text(word, u"FILE"))
        return Ink::Keyword;

    return ink;
}

// Punctuation in C++ or Rust: tracks generic lists, groups, and scopes for coloring the names around them.
static size_t name_context_punctuation(Text line, size_t index, bool rust, LexNames &names)
{
    if (is_scope_operator_at(line, index)) {
        names.qualified = true;
        names.next_angle = rust ? AngleRole::Arguments : AngleRole::None;
        return index + 2;
    }

    char16_t ch = line[index];
    NameRole role = names.next_name;
    AngleRole angle = names.next_angle;
    clear_name_expectation(names);

    if (angle != AngleRole::None && opens_angle_bracket(line, index) && !names.argument_groups) {
        if (names.angles++ == 0) {
            names.parameter_list = angle == AngleRole::Parameters;
            names.parameter_start = names.parameter_list;
        }
        return index + 1;
    }

    // Inside a generic list.
    if (names.angles) {
        if (ch == u'(' || ch == u'[' || ch == u'{') {
            ++names.argument_groups;
            return index + 1;
        }

        if (names.argument_groups) {
            if (ch == u')' || ch == u']' || ch == u'}')
                --names.argument_groups;
            if (ch == u'&' || ch == u'*')
                names.next_name = role;
            return index + 1;
        }

        if (ch == u'>' && (!index || line[index - 1] != u'-') && char_at(line, index + 1) != u'=') {
            if (--names.angles == 0)
                names.parameter_list = names.parameter_start = false;
            return index + 1;
        }

        if (ch == u',' && names.angles == 1 && names.parameter_list)
            names.parameter_start = true;

        if (ch == u';' || ch == u'}') {
            names.angles = 0;
            names.parameter_list = names.parameter_start = false;
        }
    }

    // A Rust return type: fn f() -> Type.
    if (rust && ch == u'-' && char_at(line, index + 1) == u'>') {
        names.next_name = NameRole::Type;
        return index + 2;
    }

    if (names.rust_header || names.generic_count || names.groups) {
        if (ch == u'(' || ch == u'[')
            ++names.groups;
        else if (names.groups && (ch == u')' || ch == u']'))
            --names.groups;
    }

    if (rust && ch == u':' && (names.rust_header || names.parameter_list))
        names.next_name = NameRole::Type;

    // Pointers, references, and member access keep what the next name is.
    if (ch == u'&' || ch == u'*' || ch == u'.' || (rust && ch == u'!' && role == NameRole::Function))
        names.next_name = role;

    if (names.groups)
        return index + 1;

    if (ch == u'=' && !names.angles) {
        names.rust_header = false;
        if (names.type_alias)
            names.next_name = NameRole::Type;
        names.type_alias = false;
    }

    if (ch == u'{') {
        names.rust_header = names.type_alias = false;
        if (names.generic_count)
            ++names.brace_depth;
    } else if (ch == u'}' || ch == u';') {
        // Generic parameters go out of scope with the braces they were declared for.
        if (ch == u'}' && names.brace_depth)
            --names.brace_depth;

        while (names.generic_count && names.generics[names.generic_count - 1].brace_depth >= names.brace_depth)
            names.generics[--names.generic_count] = {};

        if (!names.generic_count)
            names.brace_depth = 0;

        names.rust_header = names.type_alias = false;
        if (ch == u';')
            names.rust_import = false;
    }

    return index + 1;
}

//
// Numbers.
//

static size_t number_end(Text line, size_t start)
{
    size_t index = start;
    bool hex = char_at(line, start) == u'0' && (char_at(line, start + 1) == u'x' || char_at(line, start + 1) == u'X');
    if (hex)
        index += 2;

    while (index < line.size()) {
        char16_t ch = line[index];
        char16_t next = char_at(line, index + 1);
        bool hex_letter = (next >= u'a' && next <= u'f') || (next >= u'A' && next <= u'F');

        if (ch == u'.' && next != u'.' && (is_digit(next) || !is_name_start(next) || (hex && hex_letter))) {
            ++index;
        } else if ((hex ? ch == u'p' || ch == u'P' : ch == u'e' || ch == u'E') &&
                   (next == u'+' || next == u'-') && is_digit(char_at(line, index + 2))) {
            index += 2;
        } else if (is_name_char(ch) || (ch == u'\'' && (is_digit(next) || (hex && hex_letter)))) {
            // Digit separators: 1'000'000 in C++.
            ++index;
        } else {
            break;
        }
    }

    return index;
}

// GameMaker colors: $FF00FF and #FF00FF.
static size_t gml_hex_number_end(Text line, size_t start)
{
    if (!is_hex_digit(char_at(line, start + 1)))
        return start;

    size_t end = start + 1, digits = 0;
    for (char16_t ch = char_at(line, end); is_hex_digit(ch) || ch == u'_'; ch = char_at(line, ++end))
        digits += is_hex_digit(ch);

    if (is_name_char(char_at(line, end)) || (line[start] == u'#' && digits != 6))
        return start;

    return end;
}

static size_t odin_digits_end(Text line, size_t index, int base)
{
    for (char16_t ch = char_at(line, index); ch == u'_' || is_hex_digit(ch); ch = char_at(line, ++index)) {
        int digit = is_digit(ch) ? ch - u'0' : lowercase(ch) - u'a' + 10;
        if (ch != u'_' && digit >= base)
            break;
    }

    return index;
}

static size_t odin_number_end(Text line, size_t start)
{
    size_t index = start;

    // 0b, 0o, 0d, 0z (dozenal), 0h, and 0x prefixes.
    if (char_at(line, index) == u'0') {
        int base = 0;
        switch (char_at(line, index + 1)) {
            case u'b': base = 2; break;
            case u'o': base = 8; break;
            case u'd': base = 10; break;
            case u'z': base = 12; break;
            case u'h': case u'x': base = 16; break;
        }

        if (base)
            return odin_digits_end(line, index + 2, base);
    }

    index = odin_digits_end(line, index, 10);
    if (char_at(line, index) == u'.' && char_at(line, index + 1) != u'.')
        index = odin_digits_end(line, index + 1, 10);

    char16_t suffix = char_at(line, index);
    if (suffix == u'e' || suffix == u'E') {
        ++index;
        if (char_at(line, index) == u'+' || char_at(line, index) == u'-')
            ++index;
        index = odin_digits_end(line, index, 10);
        suffix = char_at(line, index);
    }

    // Imaginary and quaternion suffixes.
    return index + (suffix == u'i' || suffix == u'j' || suffix == u'k');
}

//
// Strings.
//

// Lua's [==[ long strings and comments, and CMake's bracket arguments. start is at the first [.
static size_t begin_long_bracket(Text line, size_t start, LexState &state, LexMode mode)
{
    if (char_at(line, start) != u'[')
        return start;

    size_t at = start + 1;
    while (char_at(line, at) == u'=')
        ++at;

    if (char_at(line, at) != u'[')
        return start;

    set_mode(state, mode, true);
    set_closing(state.closing, u"]", u'=', at - start - 1, u"]");
    state.depth = 1;
    return at + 1;
}

// The end of a string that closes on this line, or body when it doesn't.
static size_t quoted_string_end(Text line, size_t body, char16_t quote, bool doubled = false)
{
    for (size_t at = body; at < line.size(); ++at) {
        if (line[at] == u'\\' && !doubled) {
            ++at;
        } else if (line[at] == quote) {
            if (doubled && char_at(line, at + 1) == quote)
                ++at;
            else
                return at + 1;
        }
    }

    return body;
}

// Ruby's %q(...) and friends, and Elixir's ~s(...) sigils.
static size_t begin_percent_string(Text line, size_t start, Language language, LexState &state)
{
    size_t at = start + 1;
    char16_t style = char_at(line, at);
    if (language == Language::Elixir || is_any_of(style, u"qQwWiIrsx"))
        ++at;

    char16_t open = char_at(line, at), close = open;
    switch (open) {
        case u'(': close = u')'; break;
        case u'[': close = u']'; break;
        case u'{': close = u'}'; break;
        case u'<': close = u'>'; break;
        case u'|': case u'/': case u'"': case u'\'': break;
        default: return start;
    }

    // Lowercase forms don't interpolate in Ruby. Uppercase sigils don't in Elixir.
    bool raw = language == Language::Elixir ? style >= u'A' && style <= u'Z' :
               style == u'q' || style == u'w' || style == u'i' || style == u's';

    bool triple = (open == u'"' || open == u'\'') && char_at(line, at + 1) == open && char_at(line, at + 2) == open;
    size_t count = triple ? 3 : 1;

    set_mode(state, raw ? LexMode::Raw : LexMode::Quoted, true);
    set_closing(state.closing, {}, close, count, {});
    if (!raw)
        state.interpolation = Interpolation::Hash;

    // Brackets nest inside the string: %q(a (b) c).
    if (count == 1 && open != close) {
        state.depth = 1;
        state.string_opening = open;
    }

    return at + count;
}

// Characters besides quotes that can start a string: prefixes like u8"..." and r#"..."#, and openers like [[ and %q(.
static bool is_string_prefix(char16_t ch, Language language)
{
    if (is_c_family(language))
        return ch == u'u' || ch == u'U' || ch == u'L' || ch == u'R' || ch == u'@';

    switch (language) {
        case Language::Python: return is_any_of(ch, u"rRbBuUfF");
        case Language::GML: return ch == u'@' || ch == u'$';
        case Language::Rust: return ch == u'b' || ch == u'c' || ch == u'r';
        case Language::CSharp: return ch == u'$' || ch == u'@';
        case Language::Swift: return ch == u'#';
        case Language::Dart: return ch == u'r' || ch == u'R';
        case Language::Scala: return ch == u's' || ch == u'f' || ch == u'r';
        case Language::Bash: case Language::Zsh: return ch == u'$';
        case Language::Lua: case Language::Luau: return ch == u'[';
        case Language::Ruby: return ch == u'%';
        case Language::Elixir: return ch == u'~';
        case Language::SQL: return ch == u'$';
        case Language::PowerShell: return ch == u'@';
        default: return false;
    }
}

// Starts a string at start if one begins there, and returns where its body starts. Returns start otherwise.
static size_t begin_string(Text line, size_t start, Language language, LexState &state, bool expects_value)
{
    const char16_t ch = char_at(line, start);
    size_t quote_at = start;
    bool raw = false;
    bool doubled = false;
    bool multiline = false;
    size_t quote_count = 1;
    size_t hashes = 0;
    Interpolation interpolation = Interpolation::None;

    // Prefixes and special forms, by language.
    if (is_c_family(language)) {
        if (starts_at(line, start, u"u8"))
            quote_at += 2;
        else if (ch == u'u' || ch == u'U' || ch == u'L' ||
                 ((language == Language::ObjectiveC || language == Language::ObjectiveCpp) && ch == u'@'))
            ++quote_at;

        // C++ raw strings: R"delimiter( ... )delimiter", with up to 16 delimiter characters.
        if ((language == Language::Cpp || language == Language::ObjectiveCpp) && starts_at(line, quote_at, u"R\"")) {
            size_t delimiter = quote_at + 2;
            size_t end = delimiter;
            while (end - delimiter <= 16 && end < line.size() &&
                   !is_space(line[end]) && line[end] != u'(' && line[end] != u')' && line[end] != u'\\')
                ++end;

            if (end - delimiter <= 16 && char_at(line, end) == u'(') {
                // The closing delimiter is ) then the delimiter then ", at most 18 units.
                char16_t closing[18];
                size_t length = 0;
                closing[length++] = u')';
                for (size_t at = delimiter; at < end; ++at)
                    closing[length++] = line[at];
                closing[length++] = u'"';

                set_mode_and_closing(state, LexMode::Raw, Text(closing, length), true);
                return end + 1;
            }

            return start;
        }
    } else if (language == Language::Python) {
        while (quote_at - start < 2 && char_at(line, quote_at) && is_any_of(char_at(line, quote_at), u"rRbBuUfF"))
            ++quote_at;

        if (line.substr(start, quote_at - start).find_first_of(u"fF") != NOT_FOUND)
            interpolation = Interpolation::Braces;
    } else if (language == Language::GML) {
        // @"verbatim" and $"interpolated {x}".
        char16_t next = char_at(line, start + 1);
        if (ch == u'@' && (next == u'"' || next == u'\'')) {
            raw = multiline = true;
            ++quote_at;
        } else if (ch == u'$' && next == u'"') {
            interpolation = Interpolation::Braces;
            ++quote_at;
        } else if (ch != u'"') {
            return start;
        }
    } else if (language == Language::Rust) {
        // b"bytes", c"C string", and raw strings r#"..."#.
        if (ch == u'b' || ch == u'c')
            ++quote_at;

        if (char_at(line, quote_at) == u'r') {
            size_t first_hash = ++quote_at;
            while (char_at(line, quote_at) == u'#')
                ++quote_at;

            if (char_at(line, quote_at) == u'"' && quote_at - first_hash <= 255) {
                set_mode(state, LexMode::Raw, true);
                set_closing(state.closing, u"\"", u'#', quote_at - first_hash, {});
                return quote_at + 1;
            }

            return start;
        }
    } else if (language == Language::CSharp) {
        // $"..{x}..", @"verbatim", $@"both", and raw """ strings with $$ for {{x}} interpolation.
        size_t dollars = 0;
        while (char_at(line, quote_at) == u'$') {
            ++quote_at;
            ++dollars;
        }

        if (char_at(line, quote_at) == u'@') {
            raw = doubled = multiline = true;
            ++quote_at;
            if (!dollars && char_at(line, quote_at) == u'$') {
                ++quote_at;
                ++dollars;
            }
        }

        if (dollars)
            interpolation = Interpolation::Braces;

        if (!doubled && starts_at(line, quote_at, u"\"\"\"")) {
            quote_count = 3;
            while (char_at(line, quote_at + quote_count) == u'"')
                ++quote_count;

            // An empty raw string puts both delimiters together.
            if (quote_count >= 6 && quote_count % 2 == 0)
                quote_count /= 2;

            raw = multiline = true;
            if (dollars > 1)
                interpolation = Interpolation::None;
        }
    } else if (language == Language::Swift) {
        // #"raw"#, with as many # on each side.
        while (char_at(line, quote_at) == u'#')
            ++quote_at;

        hashes = quote_at - start;
        raw = hashes != 0;
        interpolation = Interpolation::Swift;
    } else if (language == Language::Dart && (ch == u'r' || ch == u'R')) {
        ++quote_at;
        raw = true;
    } else if (language == Language::Scala && (starts_at(line, start, u"s\"") || starts_at(line, start, u"f\"") || starts_at(line, start, u"raw\""))) {
        raw = ch == u'r';
        quote_at += raw ? 3 : 1;
        interpolation = Interpolation::Dollar;
    } else if ((language == Language::Bash || language == Language::Zsh) && starts_at(line, start, u"$'")) {
        ++quote_at;
    } else if (is_lua_family(language) && ch == u'[') {
        return begin_long_bracket(line, start, state, LexMode::Raw);
    } else if ((language == Language::Ruby && ch == u'%' && expects_value) ||
               (language == Language::Elixir && ch == u'~' && is_name_start(char_at(line, start + 1)))) {
        return begin_percent_string(line, start, language, state);
    } else if (language == Language::SQL && ch == u'$') {
        // PostgreSQL dollar quoting: $$ ... $$ and $tag$ ... $tag$.
        size_t at = start + 1;
        if (!is_digit(char_at(line, at))) {
            while (char_at(line, at) != u'$' && is_name_char(char_at(line, at)))
                ++at;
        }

        Text tag = line.substr(start, at - start + 1);
        if (char_at(line, at) == u'$' && tag.size() <= LEX_CLOSING_TEXT_LIMIT) {
            set_mode_and_closing(state, LexMode::Raw, tag, true);
            return at + 1;
        }
    } else if (language == Language::PowerShell && (starts_at(line, start, u"@\"") || starts_at(line, start, u"@'"))) {
        // Here-strings: @" ... "@ and @' ... '@.
        char16_t quote = char_at(line, start + 1);
        char16_t closing[2] = {quote, u'@'};
        set_mode_and_closing(state, LexMode::Raw, Text(closing, 2), true);
        if (quote == u'"')
            state.interpolation = Interpolation::Dollar;
        return start + 2;
    }

    char16_t quote = char_at(line, quote_at);

    // Backquotes: template strings in JavaScript, Luau, and shells, and raw strings or quoted names elsewhere.
    if (quote == u'`') {
        if (is_javascript_family(language) || language == Language::Luau || is_shell(language)) {
            set_mode_and_closing(state, LexMode::Quoted, u"`", true);
            state.interpolation = language == Language::Luau ? Interpolation::Braces : Interpolation::Dollar;
            return quote_at + 1;
        }

        if (language == Language::Go || language == Language::Odin || language == Language::SQL || language == Language::R) {
            set_mode_and_closing(state, LexMode::Raw, u"`", language != Language::R);
            if (language == Language::SQL || language == Language::R)
                state.string_ink = Ink::Name;
            return quote_at + 1;
        }

        return start;
    }

    if (quote != u'\'' && quote != u'"')
        return start;

    // Where ' isn't a string quote.
    if ((language == Language::JSON || language == Language::JSONC || language == Language::Swift ||
         language == Language::VisualBasic || language == Language::Clojure) && quote == u'\'')
        return start;

    // Rust 'a is a lifetime unless it's a one-character literal like 'a'.
    if (language == Language::Rust && quote == u'\'' && is_name_start(char_at(line, quote_at + 1))) {
        char16_t first = char_at(line, quote_at + 1);
        size_t width = first >= 0xD800 && first <= 0xDBFF ? 2 : 1;
        if (char_at(line, quote_at + 1 + width) != u'\'')
            return start;
    }

    bool triple_quotes = (quote == u'"' && (language == Language::Java || language == Language::Kotlin ||
        language == Language::Swift || language == Language::Scala || language == Language::Julia)) ||
        language == Language::Python || language == Language::Dart || language == Language::TOML ||
        language == Language::Groovy || language == Language::Elixir || language == Language::FSharp;
    if (quote_count == 1 && triple_quotes && char_at(line, quote_at + 1) == quote && char_at(line, quote_at + 2) == quote)
        quote_count = 3;

    if (quote_count > 1)
        multiline = true;
    if ((language == Language::Kotlin || language == Language::Scala || language == Language::FSharp) && quote_count == 3)
        raw = true;

    // Which strings interpolate, and how.
    if (quote == u'"') {
        if (language == Language::Ruby || language == Language::Elixir)
            interpolation = Interpolation::Hash;
        if ((!raw && (language == Language::Dart || language == Language::PHP)) || language == Language::Kotlin ||
            language == Language::Groovy || language == Language::PowerShell || language == Language::CMake || is_shell(language))
            interpolation = Interpolation::Dollar;
    } else if (language == Language::Dart && !raw) {
        interpolation = Interpolation::Dollar;
    }

    // Strings where a doubled quote stands for one quote, and strings without escapes.
    if (language == Language::SQL || language == Language::VisualBasic || (language == Language::YAML && quote == u'\'')) {
        raw = doubled = true;
        multiline = language != Language::VisualBasic;
    }
    if (quote == u'\'' && ((is_shell(language) && quote_at == start) || language == Language::TOML || language == Language::PowerShell))
        raw = true;
    if (language == Language::PowerShell && quote == u'\'')
        doubled = true;

    if (is_shell(language) || language == Language::Ruby || language == Language::PHP || language == Language::Perl ||
        language == Language::YAML || language == Language::CMake || (language == Language::Rust && quote == u'"'))
        multiline = true;

    // Python's r"..." keeps backslashes as they are.
    bool python_raw = language == Language::Python && line.substr(start, quote_at - start).find_first_of(u"rR") != NOT_FOUND;

    // Swift's quotes are followed by its hashes. C#'s raw quotes can be any number long.
    if (hashes && !closing_fits(quote_count, hashes, 0))
        return start;

    set_mode(state, raw ? LexMode::Raw : LexMode::Quoted, multiline, !python_raw);
    if (hashes) {
        char16_t quotes[3] = {quote, quote, quote};
        set_closing(state.closing, Text(quotes, quote_count), u'#', hashes, {});
    } else {
        set_closing(state.closing, {}, quote, quote_count, {});
    }

    state.doubled_quote = doubled;
    state.interpolation = interpolation;
    if (language == Language::SQL && quote == u'"')
        state.string_ink = Ink::Name;

    return quote_at + quote_count;
}

// Where the escape sequence that starts with the backslash at start ends.
static size_t escape_end(Text line, size_t start, Language language)
{
    char16_t kind = char_at(line, start + 1);
    size_t end = start + 2 < line.size() ? start + 2 : line.size();

    // An escaped surrogate pair is one character.
    if (kind >= 0xD800 && kind <= 0xDBFF && char_at(line, end) >= 0xDC00 && char_at(line, end) <= 0xDFFF)
        return end + 1;

    if (language == Language::CommonLisp)
        return end;

    // \u{1F600} in Rust and JavaScript.
    if (kind == u'u' && (language == Language::Rust || is_javascript_family(language)) && char_at(line, end) == u'{') {
        ++end;
        while (is_hex_digit(char_at(line, end)) || (language == Language::Rust && char_at(line, end) == u'_'))
            ++end;
        return end + (char_at(line, end) == u'}');
    }

    // \N{NAME} in Python.
    if (kind == u'N' && language == Language::Python && char_at(line, end) == u'{') {
        ++end;
        while (is_name_char(char_at(line, end)) || char_at(line, end) == u' ' || char_at(line, end) == u'-')
            ++end;
        return end + (char_at(line, end) == u'}');
    }

    // Up to three octal digits.
    if (kind >= u'0' && kind <= u'7' && language != Language::Rust) {
        while (end - start < 4 && char_at(line, end) >= u'0' && char_at(line, end) <= u'7')
            ++end;
        return end;
    }

    // Hex escapes. C's \x takes every hex digit that follows.
    bool c_family = is_c_family(language);
    size_t digits = 0;
    if (kind == u'x')
        digits = c_family ? line.size() - end : 2;
    else if (kind == u'u' && language != Language::Rust)
        digits = 4;
    else if (kind == u'U' && (c_family || language == Language::Python || language == Language::Odin))
        digits = 8;

    while (digits && is_hex_digit(char_at(line, end))) {
        ++end;
        --digits;
    }

    return end;
}

// The length of the marker that starts an embedded expression at index, or zero.
static size_t interpolation_marker_length(Text line, size_t index, Language language, const LexState &state)
{
    switch (state.interpolation) {
        case Interpolation::None:
            return 0;

        case Interpolation::Dollar:
            return starts_at(line, index, u"${") ? 2 : 0;

        case Interpolation::Hash:
            return starts_at(line, index, u"#{") ? 2 : 0;

        case Interpolation::Braces:
            // C# and Python escape a literal brace by doubling it.
            if (char_at(line, index) != u'{')
                return 0;
            if ((language == Language::CSharp || language == Language::Python) && char_at(line, index + 1) == u'{')
                return 0;
            return 1;

        case Interpolation::Swift: {
            // \( in a plain string, \#( in a #"raw"# string, and so on.
            if (char_at(line, index) != u'\\')
                return 0;

            size_t at = index + 1;
            size_t hashes = swift_hash_count(state.closing);
            for (size_t count = 0; count < hashes; ++count, ++at) {
                if (char_at(line, at) != u'#')
                    return 0;
            }

            return char_at(line, at) == u'(' ? at - index + 1 : 0;
        }
    }

    return 0;
}

// $name, $1, $?, and other one-character variables.
static size_t variable_end(Text line, size_t start)
{
    char16_t ch = char_at(line, start + 1);
    if (is_name_char(ch) && ch != u'$')
        return name_end(line, start + 1);

    if (ch && is_any_of(ch, u"?@!#*$-"))
        return start + 2;

    return start;
}

// The characters where an open string's text can stop being plain: the first character of its closing delimiter,
// its escape character, its interpolation marker, and the bracket that nests in a %q(...) string.
struct StringStops {
    char16_t characters[4];
    int count;    // zero when every character needs the full check, as with an empty delimiter
};

static StringStops string_stops(const LexState &state, Language language)
{
    StringStops stops = {};
    if (closing_is_empty(state.closing))
        return stops;

    stops.characters[stops.count++] = closing_first_unit(state.closing);

    if (state.mode == LexMode::Quoted)
        stops.characters[stops.count++] = language == Language::PowerShell ? u'`' : u'\\';

    switch (state.interpolation) {
        case Interpolation::None: break;
        case Interpolation::Dollar: stops.characters[stops.count++] = u'$'; break;
        case Interpolation::Hash: stops.characters[stops.count++] = u'#'; break;
        case Interpolation::Braces: stops.characters[stops.count++] = u'{'; break;
        case Interpolation::Swift: stops.characters[stops.count++] = u'\\'; break;
    }

    if (state.string_opening)
        stops.characters[stops.count++] = state.string_opening;

    return stops;
}

static bool is_string_stop(char16_t ch, const StringStops &stops)
{
    for (int index = 0; index < stops.count; ++index) {
        if (ch == stops.characters[index])
            return true;
    }

    return false;
}

// Lexes the open string from index. Its token starts at start, which can be before index when the quote is on
// this line. Returns where the string ends on this line.
static size_t continue_string(Text line, size_t start, size_t index, Language language, LexState &state,
                              std::vector<Token> &tokens, bool finish_line)
{
    bool continued = false;
    Ink string_ink = state.string_ink;
    StringStops stops = string_stops(state, language);

    while (index < line.size()) {
        // Plain string text up to the next character that can matter.
        if (stops.count) {
            while (index < line.size() && !is_string_stop(line[index], stops))
                ++index;

            if (index == line.size())
                break;
        }

        if (closing_at(line, index, state.closing)) {
            size_t length = closing_size(state.closing);
            if (state.doubled_quote && closing_at(line, index + length, state.closing)) {
                index += 2 * length;
                continue;
            }

            index += length;

            // A closing bracket of a %q(...) string only ends it at the outermost level.
            if (state.string_opening && --state.depth)
                continue;

            set_mode(state, LexMode::Code);
            break;
        }

        if (state.interpolation == Interpolation::Braces &&
            (language == Language::CSharp || language == Language::Python) && starts_at(line, index, u"{{")) {
            index += 2;
            continue;
        }

        size_t marker = interpolation_marker_length(line, index, language, state);
        if (marker && state.interpolation_count < LEX_INTERPOLATION_LIMIT) {
            size_t delimiter = index + marker - 1;
            if (delimiter > start)
                add_token(tokens, start, delimiter - start, string_ink, true);

            push_interpolation(state);
            return index + marker;
        }

        if (state.interpolation == Interpolation::Dollar && line[index] == u'$' && interpolates_bare_variables(language)) {
            size_t end = variable_end(line, index);
            if (end != index) {
                if (index > start)
                    add_token(tokens, start, index - start, string_ink, true);
                add_token(tokens, index, end - index, Ink::Escape, true);
                start = index = end;
                continue;
            }
        }

        bool escape = state.mode == LexMode::Quoted &&
            (language == Language::PowerShell ? line[index] == u'`' : line[index] == u'\\');
        if (escape) {
            // A backslash at the end of the line continues the string.
            continued = index + 1 == line.size() && language != Language::Odin && language != Language::GML;

            if (state.highlight_escapes) {
                size_t end = language == Language::PowerShell ? (index + 2 < line.size() ? index + 2 : line.size()) :
                             escape_end(line, index, language);
                if (index > start)
                    add_token(tokens, start, index - start, string_ink, true);
                add_token(tokens, index, end - index, Ink::Escape, true);
                start = index = end;
            } else {
                index = index + 2 < line.size() ? index + 2 : line.size();
            }
        } else {
            if (state.string_opening && line[index] == state.string_opening)
                ++state.depth;
            ++index;
        }
    }

    if (index > start)
        add_token(tokens, start, index - start, string_ink, true);

    if (finish_line && !state.multiline && !continued)
        set_mode(state, LexMode::Code);

    return index;
}

// Brackets in code inside a string interpolation. The bracket that closes the expression resumes the string.
static void interpolation_punctuation(char16_t ch, LexState &state)
{
    if (!state.interpolation_count)
        return;

    LexInterpolation &frame = state.interpolations[state.interpolation_count - 1];
    bool swift = frame.kind == Interpolation::Swift;
    if (ch == (swift ? u'(' : u'{'))
        ++frame.braces;
    else if (ch == (swift ? u')' : u'}') && --frame.braces == 0)
        pop_interpolation(state);
}

//
// Comments.
//

// Lexes the open comment from index and returns where it ends on this line.
static size_t continue_comment(Text line, size_t index, Language language, LexState &state, bool finish_line)
{
    // A line comment ends with its line, unless a C-family line ends with a backslash.
    if (state.mode == LexMode::LineComment) {
        if (finish_line && (!is_c_family(language) || !line.ends_with(u"\\")))
            set_mode(state, LexMode::Code);
        return line.size();
    }

    const CommentSyntax &comments = language_info(language).comments;
    bool own_closing = !closing_is_empty(state.closing);
    if (!own_closing && comments.close.empty()) {
        set_mode(state, LexMode::Code);
        return line.size();
    }

    // Only the first character of the closing delimiter, or of a nested opening one, needs a closer look.
    char16_t close_first = own_closing ? closing_first_unit(state.closing) : comments.close[0];
    char16_t open_first = comments.nested && !comments.open.empty() ? comments.open[0] : close_first;

    while (index < line.size()) {
        if (line[index] != close_first && line[index] != open_first) {
            ++index;
            continue;
        }

        bool closes = own_closing ? closing_at(line, index, state.closing) : starts_at(line, index, comments.close);
        if (closes) {
            index += own_closing ? closing_size(state.closing) : comments.close.size();
            if (--state.depth == 0) {
                set_mode(state, LexMode::Code);
                break;
            }
        } else if (comments.nested && !comments.open.empty() && starts_at(line, index, comments.open)) {
            ++state.depth;
            index += comments.open.size();
        } else {
            ++index;
        }
    }

    return index;
}

// True when a line comment starts at index. first is where the line's text starts.
static bool line_comment_at(Text line, size_t index, size_t first, Language language)
{
    char16_t ch = line[index];
    Text rest = line.substr(index);

    if (language == Language::PHP && ch == u'#')
        return char_at(line, index + 1) != u'[';
    if (language == Language::INI && ch == u'#')
        return index == first || is_space(char_at(line, index - 1));
    if (language == Language::Assembly && (rest.starts_with(u"//") || (ch == u'#' && index == first)))
        return true;
    if (language == Language::Odin && rest.starts_with(u"#!"))
        return true;
    if (language == Language::VisualBasic && index == first && starts_with_ignoring_case(rest, u"rem") &&
        (rest.size() == 3 || is_space(char_at(rest, 3))))
        return true;

    Text marker = language_info(language).comments.line;
    if (marker.empty() || !rest.starts_with(marker))
        return false;

    if (language == Language::Dockerfile)
        return index == first;

    // In shells, YAML, and INI, # inside a word isn't a comment.
    if ((is_shell(language) || language == Language::YAML || language == Language::INI) && index > first) {
        char16_t before = line[index - 1];
        return is_space(before) || (is_shell(language) && is_any_of(before, u";|&()<>"));
    }

    return true;
}

// Starts a block comment at index if one begins there, and returns where its body starts.
static size_t begin_block_comment(Text line, size_t index, Language language, LexState &state)
{
    const CommentSyntax &comments = language_info(language).comments;

    if (is_lua_family(language) && starts_at(line, index, u"--")) {
        size_t body = begin_long_bracket(line, index + 2, state, LexMode::BlockComment);
        return body == index + 2 ? index : body;
    }

    if (language == Language::CMake && char_at(line, index) == u'#') {
        size_t body = begin_long_bracket(line, index + 1, state, LexMode::BlockComment);
        return body == index + 1 ? index : body;
    }

    if (!comments.open.empty() && starts_at(line, index, comments.open)) {
        set_mode(state, LexMode::BlockComment, true);
        state.depth = 1;
        return index + comments.open.size();
    }

    return index;
}

// A JavaScript regular expression literal starting with the / at start, or start when it doesn't close.
static size_t regex_end(Text line, size_t start)
{
    bool in_class = false;
    for (size_t index = start + 1; index < line.size(); ++index) {
        switch (line[index]) {
            case u'\\':
                ++index;
                break;

            case u'[':
                in_class = true;
                break;

            case u']':
                in_class = false;
                break;

            case u'/':
                if (!in_class) {
                    // Flags such as /g and /i.
                    ++index;
                    while (is_name_char(char_at(line, index)))
                        ++index;
                    return index;
                }
                break;

            default:
                break;
        }
    }

    return start;
}

//
// Here-documents: <<EOF in shells, Ruby, and PHP.
//

// Starts a here-document at start if one begins there, and returns where its opening marker ends.
static size_t begin_heredoc(Text line, size_t start, Language language, LexState &state)
{
    Text rest = line.substr(start);
    bool shell = is_shell(language);
    bool php = language == Language::PHP;

    if ((!shell && language != Language::Ruby && !php) || !rest.starts_with(u"<<"))
        return start;
    if (language == Language::Fish || (start && line[start - 1] == u'<') || php != rest.starts_with(u"<<<"))
        return start;

    // <<- and Ruby's <<~ allow an indented terminator. PHP's always can be.
    size_t at = start + (php ? 3 : 2);
    bool indent = php || char_at(line, at) == u'-' || (language == Language::Ruby && char_at(line, at) == u'~');
    if (indent && !php)
        ++at;

    if (language == Language::Ruby && is_space(char_at(line, at)))
        return start;

    at = skip_spaces(line, at);
    bool escaped = char_at(line, at) == u'\\';
    if (escaped)
        ++at;

    // A quoted terminator. Shells never expand a quoted one, and Ruby and PHP expand inside double quotes.
    char16_t quote = char_at(line, at);
    if (quote == u'\'' || quote == u'"') {
        size_t end = quoted_string_end(line, at + 1, quote);
        if (end == at + 1 && char_at(line, end) != quote)
            return start;
        if (end == at + 1)
            ++end;
        if (end == at + 2)
            return start;

        Text terminator = line.substr(at + 1, end - at - 2);
        return push_heredoc(state, terminator, indent, !shell && quote == u'"') ? end : start;
    }

    if (!is_name_start(char_at(line, at)))
        return start;

    size_t end = name_end(line, at + 1);
    return push_heredoc(state, line.substr(at, end - at), indent, !escaped) ? end : start;
}

// Colors a line of a pending here-document's body. Returns false when no here-document is pending.
static bool heredoc_line(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    if (!state.heredoc_count || state.mode != LexMode::Code)
        return false;

    LexHeredoc heredoc = state.heredocs[0];
    Text terminator = first_heredoc_terminator(state);

    size_t at = 0;
    if (heredoc.indent) {
        while (char_at(line, at) == u'\t' || (!is_shell(language) && char_at(line, at) == u' '))
            ++at;
    }

    // PHP's terminator can be followed by more code on its line.
    Text body = line.substr(at);
    if (body == terminator || (language == Language::PHP && body.starts_with(terminator) &&
                               !is_name_char(char_at(body, terminator.size())))) {
        add_token(tokens, at, terminator.size(), Ink::Directive, true);
        if (finish_line)
            pop_first_heredoc(state);
        return true;
    }

    // Variables expand in the body unless the terminator was quoted.
    size_t start = 0;
    if (heredoc.expand && language != Language::Ruby) {
        for (size_t index = 0; index < line.size(); ++index) {
            if (line[index] == u'\\' && index + 1 < line.size()) {
                ++index;
                continue;
            }

            if (line[index] != u'$')
                continue;

            size_t end = variable_end(line, index);
            if (end == index && char_at(line, index + 1) == u'{') {
                size_t close = line.find(u'}', index + 2);
                if (close != NOT_FOUND)
                    end = close + 1;
            }

            if (end != index) {
                if (index > start)
                    add_token(tokens, start, index - start, Ink::String, true);
                add_token(tokens, index, end - index, Ink::Escape, true);
                start = end;
                index = end - 1;
            }
        }
    }

    if (line.size() > start)
        add_token(tokens, start, line.size() - start, Ink::String, true);

    return true;
}

//
// Rust attributes: #[derive(Debug)] and #![cfg(test)].
//

// Starts an attribute at the # at hash if one begins there, and returns where its arguments start.
static size_t begin_rust_attribute(Text line, size_t hash, LexRustAttribute &attribute, std::vector<Token> &tokens)
{
    size_t marker = skip_spaces(line, hash + 1);
    bool inner = char_at(line, marker) == u'!';
    size_t bracket = inner ? skip_spaces(line, marker + 1) : marker;
    if (char_at(line, bracket) != u'[')
        return hash;

    add_token(tokens, hash, 1, Ink::Directive);
    if (inner)
        add_token(tokens, marker, 1, Ink::Directive);

    attribute.brackets = 1;
    attribute.part = RustAttributePart::Name;
    return bracket + 1;
}

static bool is_builtin_rust_attribute(Text word)
{
    static constexpr Text NAMES[] = {
        u"allow", u"automatically_derived", u"bench", u"cfg", u"cfg_attr", u"cold", u"collapse_debuginfo",
        u"crate_name", u"crate_type", u"debugger_visualizer", u"deny", u"deprecated", u"derive", u"doc",
        u"expect", u"export_name", u"feature", u"forbid", u"global_allocator", u"ignore", u"inline",
        u"instruction_set", u"link", u"link_name", u"link_ordinal", u"link_section", u"macro_export",
        u"macro_use", u"must_use", u"naked", u"no_builtins", u"no_implicit_prelude", u"no_link", u"no_main",
        u"no_mangle", u"no_std", u"non_exhaustive", u"panic_handler", u"path", u"proc_macro",
        u"proc_macro_attribute", u"proc_macro_derive", u"recursion_limit", u"repr", u"should_panic",
        u"target_feature", u"test", u"track_caller", u"type_length_limit", u"used", u"warn", u"windows_subsystem",
    };

    return is_in_sorted_list(word, NAMES, sizeof NAMES / sizeof NAMES[0]);
}

static Ink rust_attribute_word_ink(Text line, Text word, size_t end, bool raw, LexRustAttribute &attribute)
{
    RustAttributePart part = attribute.part;
    attribute.part = RustAttributePart::Arguments;

    size_t next = skip_spaces_and_comments(line, end);
    bool qualified = is_scope_operator_at(line, next);

    // The attribute's own name: a built-in, diagnostic::..., or unsafe(...).
    if (part == RustAttributePart::Name) {
        if (qualified && same_text(word, u"diagnostic")) {
            attribute.part = RustAttributePart::DiagnosticName;
            return Ink::Directive;
        }

        if (!qualified && !raw && same_text(word, u"unsafe")) {
            attribute.part = RustAttributePart::Unsafe;
            return Ink::Keyword;
        }

        if (!qualified && is_builtin_rust_attribute(word)) {
            if (same_text(word, u"cfg_attr"))
                attribute.part = RustAttributePart::Conditional;
            return Ink::Directive;
        }
    } else if (part == RustAttributePart::DiagnosticName && !qualified &&
               (same_text(word, u"on_unimplemented") || same_text(word, u"do_not_recommend"))) {
        return Ink::Directive;
    }

    char16_t follow = char_at(line, next);
    if (follow == u'!' && char_at(line, next + 1) == u'=')
        follow = u'=';

    if (!raw && (same_text(word, u"true") || same_text(word, u"false")))
        return Ink::Keyword;
    if (!raw && same_text(word, u"Self"))
        return Ink::Type;

    Ink ink = raw ? (follow == u'(' ? Ink::Function : Ink::Name) : word_ink(word, Language::Rust, follow);
    return qualified && ink == Ink::Name ? Ink::Type : ink;
}

static void rust_attribute_punctuation(char16_t ch, LexRustAttribute &attribute)
{
    if (ch == u':' && attribute.part == RustAttributePart::DiagnosticName)
        return;

    RustAttributePart part = attribute.part;
    attribute.part = RustAttributePart::Arguments;
    bool at_conditional_level = attribute.conditional_count &&
                                attribute.groups == attribute.conditional_groups[attribute.conditional_count - 1];

    switch (ch) {
        case u'(':
            ++attribute.groups;
            if (part == RustAttributePart::Conditional && attribute.conditional_count < LEX_CFG_GROUP_LIMIT)
                attribute.conditional_groups[attribute.conditional_count++] = attribute.groups;
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
                for (uint16_t &group : attribute.conditional_groups)
                    group = 0;
                attribute.conditional_count = 0;
                attribute.groups = 0;
                break;
            }
            [[fallthrough]];

        case u')':
        case u'}':
            if (at_conditional_level)
                attribute.conditional_groups[--attribute.conditional_count] = 0;
            if (attribute.groups)
                --attribute.groups;
            break;

        case u',':
            // Only commas at the cfg_attr argument level start another attribute.
            if (at_conditional_level)
                attribute.part = RustAttributePart::Name;
            break;
    }
}

//
// Markup: HTML, XML, PHP's HTML, and JSX.
//

static bool is_markup_mode(LexMode mode)
{
    return mode == LexMode::MarkupText || mode == LexMode::MarkupTag || mode == LexMode::MarkupString;
}

static size_t markup_name_end(Text line, size_t at)
{
    while (is_name_char(char_at(line, at)) || char_at(line, at) == u'-' || char_at(line, at) == u':' || char_at(line, at) == u'.')
        ++at;

    return at;
}

// An entity such as &amp; or &#39; at start, or start when there isn't one.
static size_t entity_end(Text line, size_t start)
{
    size_t at = start + 1;
    if (char_at(line, at) == u'#')
        ++at;

    size_t end = name_end(line, at);
    return end > at && char_at(line, end) == u';' ? end + 1 : start;
}

// Adds markup text from first to last, with its entities colored as escapes.
static void add_markup_text(Text line, size_t first, size_t last, Ink ink, std::vector<Token> &tokens)
{
    for (size_t at = first; at < last; ++at) {
        if (line[at] != u'&')
            continue;

        size_t entity = entity_end(line.substr(0, last), at);
        if (entity == at)
            continue;

        if (at > first)
            add_token(tokens, first, at - first, ink, true);
        add_token(tokens, at, entity - at, Ink::Escape, true);
        first = entity;
        at = entity - 1;
    }

    if (last > first)
        add_token(tokens, first, last - first, ink, true);
}

static void start_markup_tag(LexState &state, bool end_tag)
{
    state.mode = LexMode::MarkupTag;
    state.markup.part = TagPart::Name;
    state.markup.end_tag = end_tag;
    state.markup.value_is_language = false;
    state.markup.element_language = Language::Plain;
    state.markup.raw_element = RawElement::None;
}

static void end_markup_tag(LexState &state, Language language, bool empty_element)
{
    LexMarkup &markup = state.markup;

    if (is_jsx(language)) {
        // JSX tracks element depth so code resumes after the outermost element closes.
        if (markup.end_tag) {
            if (markup.depth)
                --markup.depth;
        } else if (!empty_element) {
            ++markup.depth;
        }

        if (markup.root_count && markup.depth == markup.roots[markup.root_count - 1]) {
            markup.roots[--markup.root_count] = 0;
            state.mode = LexMode::Code;
            return;
        }
    } else if (!empty_element && !markup.end_tag && markup.raw_element != RawElement::None) {
        // The body of <script> or <style> is code in another language.
        markup.raw_content = true;
        state.embedded = markup.element_language;
        state.mode = LexMode::Code;
        return;
    }

    state.mode = LexMode::MarkupText;
}

// <script type="..."> and <style lang="..."> name the language of their body.
static void set_markup_element_language(Text value, LexMarkup &markup)
{
    if (!markup.value_is_language || markup.raw_element == RawElement::None)
        return;

    if (same_text(value, u"application/ld+json") || same_text(value, u"application/json") || same_text(value, u"importmap"))
        markup.element_language = Language::JSON;
    else if (same_text(value, u"ts") || same_text(value, u"typescript"))
        markup.element_language = Language::TypeScript;
    else if (same_text(value, u"scss"))
        markup.element_language = Language::SCSS;
    else if (same_text(value, u"less"))
        markup.element_language = Language::Less;
    else if (!(value.empty() || same_text(value, u"text/javascript") || same_text(value, u"application/javascript") ||
               same_text(value, u"module") || same_text(value, u"js") || same_text(value, u"javascript") || same_text(value, u"text/css") || same_text(value, u"css")))
        markup.element_language = Language::Plain;
}

// <?php or <?= at the start of rest, or zero.
static size_t php_open_tag_length(Text rest)
{
    if (starts_with_ignoring_case(rest, u"<?php") && (rest.size() == 5 || is_space(char_at(rest, 5))))
        return 5;

    return rest.starts_with(u"<?=") ? 3 : 0;
}

// Lexes one piece of markup at index and returns where it ends.
static size_t markup_step(Text line, size_t index, Language language, LexState &state, std::vector<Token> &tokens)
{
    const size_t start = index;
    Text rest = line.substr(index);
    char16_t ch = line[index];
    LexMarkup &markup = state.markup;
    bool jsx = is_jsx(language);

    // Inside <!-- ... --> or <![CDATA[ ... ]]>.
    if (state.mode == LexMode::BlockComment || state.mode == LexMode::Raw) {
        bool comment = state.mode == LexMode::BlockComment;
        size_t end = find_closing(line, index, state.closing);
        index = end == NOT_FOUND ? line.size() : end + closing_size(state.closing);
        if (end != NOT_FOUND)
            set_mode(state, LexMode::MarkupText);

        add_token(tokens, start, index - start, comment ? Ink::Comment : Ink::String, true);
        return index;
    }

    // Inside an attribute value that started on an earlier line.
    if (state.mode == LexMode::MarkupString) {
        size_t end = find_closing(line, index, state.closing);
        index = end == NOT_FOUND ? line.size() : end + 1;
        if (end != NOT_FOUND) {
            set_markup_element_language(line.substr(start, end - start), markup);
            set_mode(state, LexMode::MarkupTag);
            markup.part = TagPart::Attribute;
        }

        add_markup_text(line, start, index, Ink::String, tokens);
        return index;
    }

    // A JSX { expression } switches to code until its closing brace.
    if (jsx && ch == u'{' && markup.expression_count < LEX_JSX_NESTING_LIMIT) {
        markup.expressions[markup.expression_count++] = {1, state.interpolation_count, state.mode, markup.part, markup.end_tag};
        state.mode = LexMode::Code;
        return index + 1;
    }

    // Text between tags.
    if (state.mode == LexMode::MarkupText) {
        if (!jsx && rest.starts_with(u"<!--")) {
            set_mode_and_closing(state, LexMode::BlockComment, u"-->", true);
            size_t end = line.find(u"-->", index + 4);
            if (end != NOT_FOUND)
                set_mode(state, LexMode::MarkupText);

            index = end == NOT_FOUND ? line.size() : end + 3;
            add_token(tokens, start, index - start, Ink::Comment, true);
            return index;
        }

        if (!jsx && rest.starts_with(u"<![CDATA[")) {
            set_mode_and_closing(state, LexMode::Raw, u"]]>", true);
            size_t end = line.find(u"]]>", index + 9);
            if (end != NOT_FOUND)
                set_mode(state, LexMode::MarkupText);

            index = end == NOT_FOUND ? line.size() : end + 3;
            add_token(tokens, start, index - start, Ink::String, true);
            return index;
        }

        if (language == Language::PHP) {
            size_t length = php_open_tag_length(rest);
            if (length) {
                set_mode(state, LexMode::Code);
                add_token(tokens, index, length, Ink::Directive, true);
                return index + length;
            }
        }

        // A tag opens: <name, </name, <!DOCTYPE, <?xml, and JSX's <> fragment.
        bool end_tag = rest.starts_with(u"</");
        size_t name = index + (end_tag ? 2 : 1);
        char16_t after = char_at(line, name);
        if (ch == u'<' && (is_name_start(after) || (jsx && after == u'>') || (!jsx && (after == u'!' || after == u'?')))) {
            if (after == u'!' || after == u'?')
                ++name;

            start_markup_tag(state, end_tag);
            add_token(tokens, index, name - index, Ink::Keyword, true);
            return name;
        }

        do {
            ++index;
        } while (index < line.size() && line[index] != u'<' && (!jsx || line[index] != u'{'));

        add_markup_text(line, start, index, Ink::Text, tokens);
        return index;
    }

    // Inside a tag.
    if (ch == u'>' || rest.starts_with(u"/>") || rest.starts_with(u"?>")) {
        index += ch == u'>' ? 1 : 2;
        end_markup_tag(state, language, ch == u'/');
        add_token(tokens, start, index - start, Ink::Keyword, true);
        return index;
    }

    if (is_space(ch))
        return skip_spaces(line, index + 1);

    if (markup.part == TagPart::Name) {
        index = markup_name_end(line, index);
        if (index == start)
            return start + 1;

        Text name = line.substr(start, index - start);
        if ((language == Language::HTML || language == Language::PHP) && !markup.end_tag) {
            if (name.size() == 6 && starts_with_ignoring_case(name, u"script")) {
                markup.element_language = Language::JavaScript;
                markup.raw_element = RawElement::Script;
            } else if (name.size() == 5 && starts_with_ignoring_case(name, u"style")) {
                markup.element_language = Language::CSS;
                markup.raw_element = RawElement::Style;
            }
        }

        markup.part = TagPart::Attribute;
        add_token(tokens, start, index - start, Ink::Type);
        return index;
    }

    if (markup.part == TagPart::Value) {
        if (ch == u'"' || ch == u'\'') {
            size_t end = line.find(ch, index + 1);
            index = end == NOT_FOUND ? line.size() : end + 1;
            if (end == NOT_FOUND) {
                char16_t quote[1] = {ch};
                set_mode_and_closing(state, LexMode::MarkupString, Text(quote, 1), true);
            } else {
                set_markup_element_language(line.substr(start + 1, end - start - 1), markup);
                markup.part = TagPart::Attribute;
            }
        } else {
            while (index < line.size() && !is_space(line[index]) && !starts_at(line, index, u"/>") && line[index] != u'>')
                ++index;

            set_markup_element_language(line.substr(start, index - start), markup);
            markup.part = TagPart::Attribute;
        }

        add_markup_text(line, start, index, Ink::String, tokens);
        return index;
    }

    if (ch == u'=') {
        markup.part = TagPart::Value;
        return index + 1;
    }

    // An attribute name.
    index = markup_name_end(line, index);
    if (index == start)
        return start + 1;

    Text attribute = line.substr(start, index - start);
    markup.value_is_language = attribute.size() == 4 &&
        (starts_with_ignoring_case(attribute, u"type") || starts_with_ignoring_case(attribute, u"lang"));
    add_token(tokens, start, index - start, Ink::Name);
    return index;
}

// Braces in a JSX { expression }. Returns true when the brace ends the expression and markup resumes.
static bool jsx_expression_punctuation(char16_t ch, LexState &state)
{
    LexMarkup &markup = state.markup;
    if (!markup.expression_count)
        return false;

    LexJSXExpression &expression = markup.expressions[markup.expression_count - 1];
    if (state.interpolation_count != expression.interpolation_count)
        return false;

    if (ch == u'{') {
        ++expression.braces;
    } else if (ch == u'}' && --expression.braces == 0) {
        state.mode = expression.mode;
        markup.part = expression.part == TagPart::Value ? TagPart::Attribute : expression.part;
        markup.end_tag = expression.end_tag;
        markup.expressions[--markup.expression_count] = {};
        return true;
    }

    return false;
}

// True when a JSX element starts at index.
static bool starts_jsx_element(Text line, size_t index, bool expects_value, Language language)
{
    if (!expects_value || char_at(line, index) != u'<')
        return false;

    if (char_at(line, index + 1) == u'>')
        return true;

    if (!is_name_start(char_at(line, index + 1)))
        return false;

    // In TSX, a trailing comma or constraint makes <T, ...> or <T extends ...> a generic arrow function instead.
    if (language == Language::TSX) {
        size_t after_name = skip_spaces(line, markup_name_end(line, index + 1));
        if (char_at(line, after_name) == u',' || starts_at(line, after_name, u"extends ") || starts_at(line, after_name, u"extends\t"))
            return false;
    }

    return true;
}

//
// CSS, data formats, and annotations.
//

static size_t css_name_end(Text line, size_t index)
{
    while (is_name_char(char_at(line, index)) || char_at(line, index) == u'-')
        ++index;

    return index;
}

// A selector, color, url(), property, or value at index. Returns index when there isn't one.
static size_t css_token_end(Text line, size_t index, Language language, const LexState &state, std::vector<Token> &tokens)
{
    char16_t ch = line[index];
    char16_t next = char_at(line, index + 1);

    // .class, #id, #fff colors, and SCSS $variables.
    if ((ch == u'.' || ch == u'#' || (ch == u'$' && language == Language::SCSS)) &&
        (is_name_start(next) || next == u'-' || (ch == u'#' && is_digit(next)))) {
        size_t end = css_name_end(line, index + 1);
        Text word = line.substr(index + 1, end - index - 1);

        bool color = ch == u'#' && (word.size() == 3 || word.size() == 4 || word.size() == 6 || word.size() == 8);
        for (char16_t digit : word) {
            if (!is_hex_digit(digit))
                color = false;
        }

        add_token(tokens, index, end - index, color ? Ink::Number : ch == u'$' ? Ink::Name : Ink::Type);
        return end;
    }

    // url(unquoted/path.png).
    if (starts_with_ignoring_case(line.substr(index), u"url(")) {
        size_t end = skip_spaces(line, index + 4);
        if (char_at(line, end) != u'"' && char_at(line, end) != u'\'') {
            size_t close = line.find(u')', end);
            if (close != NOT_FOUND) {
                add_token(tokens, index, 3, Ink::Function);
                if (close > end)
                    add_token(tokens, end, close - end, Ink::String, true);
                return close + 1;
            }
        }
    }

    // A property name inside a rule, a pseudo-class after :, or a word.
    if (is_name_start(ch) || (ch == u'-' && (is_name_start(next) || next == u'-'))) {
        size_t end = css_name_end(line, index + 1);
        size_t after = skip_spaces(line, end);
        Ink ink = word_ink(line.substr(index, end - index), language, char_at(line, after));

        if (state.names.brace_depth && char_at(line, after) == u':') {
            // A nested selector like a:hover { has a { before the next ; or }.
            size_t boundary = line.find_first_of(u"{};", after + 1);
            if (boundary == NOT_FOUND || line[boundary] != u'{')
                ink = Ink::Type;
        } else if (index && char_at(line, index - 1) == u':') {
            ink = Ink::Control;
        }

        add_token(tokens, index, end - index, ink);
        return end;
    }

    return index;
}

static bool is_yaml_colon(Text line, size_t at)
{
    char16_t next = char_at(line, at + 1);
    return char_at(line, at) == u':' && (!next || is_space(next) || is_any_of(next, u",]}[{"));
}

// Where a key that starts at start ends: before = in TOML and INI, : in INI, or a YAML colon. Returns start
// when there's no key, as when the line holds only a value.
static size_t config_key_end(Text line, size_t start, Language language)
{
    size_t end = start;
    for (; end < line.size(); ++end) {
        char16_t ch = line[end];

        // Separators inside quotes don't count.
        if (ch == u'"' || ch == u'\'') {
            size_t next = quoted_string_end(line, end + 1, ch, ch == u'\'' && language == Language::YAML);
            if (next == end + 1)
                return start;

            end = next - 1;
            continue;
        }

        if ((language == Language::YAML && is_yaml_colon(line, end)) ||
            (is_ini_or_toml(language) && (ch == u'=' || (language == Language::INI && ch == u':'))))
            break;

        if (ch == u'{' || ch == u'}' || ch == u'[' || ch == u']' || ch == u',' ||
            (ch == u'#' && (end == start || is_space(line[end - 1]))) || (ch == u';' && language == Language::INI))
            return start;
    }

    if (end == line.size())
        return start;

    while (end > start && is_space(line[end - 1]))
        --end;

    return end;
}

// Section headers, YAML markers, and keys in YAML, TOML, and INI. Returns index when there isn't one.
static size_t data_token_end(Text line, size_t index, size_t first, Language language, LexState &state, std::vector<Token> &tokens)
{
    char16_t ch = line[index];

    // [section] and TOML's [[array of tables]].
    if (is_ini_or_toml(language) && index == first && ch == u'[') {
        bool double_bracket = char_at(line, index + 1) == u'[';
        size_t end = line.find(double_bracket ? u"]]" : u"]", index + 1 + double_bracket);
        end = end == NOT_FOUND ? line.size() : end + 1 + double_bracket;
        add_token(tokens, index, end - index, Ink::Directive, true);
        return end;
    }

    if (language == Language::YAML) {
        // Document markers.
        if (index == first && (same_text(line.substr(index), u"---") || same_text(line.substr(index), u"..."))) {
            add_token(tokens, index, 3, Ink::Directive, true);
            return index + 3;
        }

        // &anchors, *aliases, and !tags.
        if (ch == u'&' || ch == u'*' || ch == u'!') {
            size_t end = index + 1;
            while (is_name_char(char_at(line, end)) || char_at(line, end) == u'-' || char_at(line, end) == u'!')
                ++end;

            add_token(tokens, index, end - index, Ink::Directive, true);
            return end;
        }

        // Block scalars: | and >, with an optional chomping indicator and indentation width, then the body lines.
        if (ch == u'|' || ch == u'>') {
            size_t end = index + 1;
            unsigned indentation = 0;
            if (char_at(line, end) == u'+' || char_at(line, end) == u'-')
                ++end;
            if (char_at(line, end) >= u'1' && char_at(line, end) <= u'9')
                indentation = unsigned(line[end++] - u'0');
            if (end == index + 1 + (indentation != 0) && (char_at(line, end) == u'+' || char_at(line, end) == u'-'))
                ++end;

            size_t tail = skip_spaces(line, end);
            if (tail == line.size() || char_at(line, tail) == u'#') {
                add_token(tokens, index, end - index, Ink::Directive, true);

                // The body is indented past the key, or past the item's key in a "- key: |" line.
                size_t base = first;
                if (char_at(line, first) == u'-' && is_space(char_at(line, first + 1))) {
                    size_t key = skip_spaces(line, first + 1);
                    if (key < index && config_key_end(line, key, language) != key)
                        base = key;
                }

                state.depth = unsigned(base) + (indentation ? indentation : 1);
                state.mode = LexMode::BlockScalar;
                if (tail < line.size())
                    add_token(tokens, tail, line.size() - tail, Ink::Comment, true);
                return line.size();
            }
        }
    }

    // A key at the start of the line, after "- " in a YAML list, or after { or , in a YAML flow mapping.
    size_t previous = previous_non_space(line, index);
    bool sequence_key = language == Language::YAML && previous == first + 1 && line[first] == u'-' && index > previous;
    bool flow_key = language == Language::YAML && previous && (line[previous - 1] == u'{' || line[previous - 1] == u',');
    if ((index == first || sequence_key || flow_key) && (is_name_start(ch) || is_digit(ch) || ch == u'"' || ch == u'\'')) {
        size_t end = config_key_end(line, index, language);
        if (end > index) {
            bool plain_name = true;
            for (size_t at = index; at < end; ++at) {
                if (!is_name_char(line[at]))
                    plain_name = false;
            }

            add_token(tokens, index, end - index, Ink::Type, !plain_name);
            return end;
        }
    }

    return index;
}

// Annotations and attributes: @Override, #[...] in Swift, #region in C#, and #private in JavaScript.
// Returns index when there isn't one.
static size_t directive_end(Text line, size_t index, size_t first, Language language)
{
    char16_t ch = line[index];
    char16_t next = char_at(line, index + 1);

    if (language == Language::Odin && (ch == u'#' || ch == u'@')) {
        size_t name = skip_spaces(line, index + 1);
        return is_name_start(char_at(line, name)) ? name_end(line, name + 1) : index + 1;
    }

    if (ch == u'@' && is_name_start(next) && (language == Language::Swift || language == Language::Java ||
        language == Language::Kotlin || language == Language::Scala || language == Language::Groovy ||
        language == Language::Zig || is_c_family(language) || is_css_family(language) || language == Language::Dart))
        return markup_name_end(line, index + 2);

    // Zig's @"quoted identifier".
    if (ch == u'@' && language == Language::Zig && next == u'"')
        return index + 1;

    if (ch == u'#' && (language == Language::Swift || (index == first && (language == Language::CSharp ||
        language == Language::FSharp || language == Language::VisualBasic)))) {
        size_t name = skip_spaces(line, index + 1);
        return name_end(line, name);
    }

    if (ch == u'#' && is_javascript_family(language) && is_name_start(next))
        return name_end(line, index + 2);

    return index;
}

//
// GameMaker.
//

// A /// doc comment, with its @tag colored as a directive.
static void add_gml_doc_comment(Text line, size_t start, std::vector<Token> &tokens)
{
    size_t tag = skip_spaces(line, start + 3);
    if (char_at(line, tag) == u'@' && is_name_start(char_at(line, tag + 1))) {
        add_token(tokens, start, tag - start, Ink::Comment, true);
        size_t end = name_end(line, tag + 2);
        add_token(tokens, tag, end - tag, Ink::Directive, true);
        start = end;
    }

    if (start < line.size())
        add_token(tokens, start, line.size() - start, Ink::Comment, true);
}

// #region, #endregion, and #macro name value. Returns start when there isn't one.
static size_t gml_directive_end(Text line, size_t start, std::vector<Token> &tokens)
{
    size_t end = name_end(line, start + 1);
    Text name = line.substr(start + 1, end - start - 1);

    if (same_text(name, u"region") || same_text(name, u"endregion")) {
        add_token(tokens, start, end - start, Ink::Directive, true);
        if (end < line.size())
            add_token(tokens, end, line.size() - end, Ink::Comment, true);
        return line.size();
    }

    if (!same_text(name, u"macro"))
        return start;

    add_token(tokens, start, end - start, Ink::Directive, true);
    size_t symbol = skip_spaces(line, end);
    if (!is_name_start(char_at(line, symbol)))
        return end;

    // #macro config:name value.
    end = name_end(line, symbol + 1);
    if (char_at(line, end) == u':') {
        add_token(tokens, symbol, end + 1 - symbol, Ink::Directive, true);
        symbol = skip_spaces(line, end + 1);
        if (!is_name_start(char_at(line, symbol)))
            return end + 1;
        end = name_end(line, symbol + 1);
    }

    add_token(tokens, symbol, end - symbol, Ink::Constant);
    return end;
}

//
// Words in languages without C++ and Rust's name tracking.
//

static bool is_clojure_name_char(char16_t ch)
{
    return is_name_char(ch) || is_any_of(ch, u".*+!-?$%&=<>#/:'");
}

// Java's sealed and non-sealed are modifiers only in a class or interface declaration.
static bool is_java_modifier_context(Text line, size_t start, size_t end)
{
    static constexpr Text MODIFIERS[] = {u"abstract", u"public", u"protected", u"private", u"static", u"strictfp"};

    size_t next = skip_spaces_and_comments(line, end);
    if (next < line.size()) {
        if (char_at(line, next) == u'@' || is_word_at(line, next, u"class") || is_word_at(line, next, u"interface"))
            return true;

        for (Text modifier : MODIFIERS) {
            if (is_word_at(line, next, modifier))
                return true;
        }
        return false;
    }

    // At the end of a line, everything before the word has to be modifiers too.
    for (size_t at = skip_spaces_and_comments(line, 0); at < start;) {
        size_t word_end = name_end(line, at);
        Text word = line.substr(at, word_end - at);

        bool modifier = false;
        for (Text known : MODIFIERS) {
            if (word == known)
                modifier = true;
        }
        if (!modifier)
            return false;

        at = skip_spaces_and_comments(line, word_end);
    }

    return true;
}

static Ink odin_word_ink(Text line, Text word, size_t start, size_t end, LexNames &names)
{
    // The first word inside @(...) is an attribute name.
    if (names.parameter_start) {
        names.parameter_start = false;
        return Ink::Directive;
    }

    size_t after = skip_spaces(line, end);
    char16_t follow = char_at(line, after);

    // Polymorphic parameters: $T is a type, and $N: int is a constant.
    if (word.starts_with(u"$") && word.size() > 1) {
        if (follow != u':')
            return Ink::Type;

        size_t constraint = skip_spaces(line, after + 1);
        Text type = line.substr(constraint, name_end(line, constraint) - constraint);
        return same_text(type, u"typeid") ? Ink::Type : Ink::Constant;
    }

    Ink ink = word_ink(word, Language::Odin, follow);

    // name :: proc ..., name :: struct ..., and name :: #type ....
    if (follow == u':' && (char_at(line, after + 1) == u':' || char_at(line, after + 1) == u'=')) {
        size_t value = skip_spaces_and_comments(line, after + 2);
        if (char_at(line, value) == u'#') {
            size_t name = skip_spaces(line, value + 1);
            Text directive = line.substr(name, name_end(line, name) - name);
            if (same_text(directive, u"type") || same_text(directive, u"simd") || same_text(directive, u"soa"))
                return Ink::Type;
        }

        Text head = line.substr(value, name_end(line, value) - value);
        if (same_text(head, u"proc"))
            return Ink::Function;
        if (same_text(head, u"struct") || same_text(head, u"union") || same_text(head, u"enum") || same_text(head, u"distinct") ||
            same_text(head, u"bit_field") || same_text(head, u"bit_set") || same_text(head, u"map") || same_text(head, u"matrix"))
            return Ink::Type;
    }

    if (is_in_sorted_list(word, ODIN_PROCEDURES, ODIN_PROCEDURE_COUNT))
        return Ink::Function;

    // Implicit selector expressions such as .Value are enum constants.
    size_t before = previous_non_space(line, start);
    if (before && char_at(line, before - 1) == u'.' &&
        (before == 1 || is_space(char_at(line, before - 2)) || is_any_of(char_at(line, before - 2), u"(:,[={")))
        return Ink::Constant;

    if (ink == Ink::Name || ink == Ink::Constant) {
        size_t previous = before;
        while (previous && is_name_char(char_at(line, previous - 1)))
            --previous;

        Text prior = line.substr(previous, before - previous);
        if (same_text(prior, u"package") || same_text(prior, u"import"))
            return Ink::Type;

        // A single capital letter after ^, ], :, or ->, or before {, is a type.
        if (word.size() == 1 && word.front() >= u'A' && word.front() <= u'Z' && before) {
            char16_t ch = line[before - 1];
            if (ch == u'^' || ch == u']' || (ch == u':' && (before < 2 || line[before - 2] != u':')) ||
                (ch == u'>' && before >= 2 && line[before - 2] == u'-') || follow == u'{')
                return Ink::Type;
        }
    }

    return ink;
}

static bool is_function_keyword(Text word, Language language)
{
    return same_text(word, u"func") || same_text(word, u"fun") || same_text(word, u"fn") || same_text(word, u"def") ||
           (same_text(word, u"function") && language != Language::GML) ||
           same_text(word, u"defp") || same_text(word, u"sub") || same_text(word, u"defn") || same_text(word, u"defn-") || same_text(word, u"defmacro");
}

static bool is_type_keyword(Text word, Language language)
{
    return same_text(word, u"class") || same_text(word, u"struct") || same_text(word, u"enum") || same_text(word, u"trait") || same_text(word, u"record") ||
           same_text(word, u"protocol") || same_text(word, u"interface") || same_text(word, u"extends") || same_text(word, u"implements") ||
           same_text(word, u"typealias") || same_text(word, u"typedef") || same_text(word, u"type") || same_text(word, u"actor") ||
           (same_text(word, u"new") && language != Language::GML);
}

// The color of a word in languages other than C++, Rust, Lisp, and JSON. start and end bound the word.
static Ink other_word_ink(Text line, Text word, size_t start, size_t end, Language language, LexState &state)
{
    if (language == Language::Odin)
        return odin_word_ink(line, word, start, end, state.names);

    size_t after = language == Language::GML ? skip_spaces_and_comments(line, end) : skip_spaces(line, end);
    char16_t follow = char_at(line, after);

    if (language == Language::Clojure && word.starts_with(u":"))
        return Ink::Constant;

    Ink ink = word_ink(word, language, follow);
    if (language == Language::Java && same_text(word, u"sealed") && !is_java_modifier_context(line, start, end))
        ink = follow == u'(' ? Ink::Function : Ink::Name;

    // A declaration keyword colors the name after it.
    if (ink == Ink::Keyword) {
        if (is_function_keyword(word, language))
            state.names.next_name = NameRole::Function;
        else if (is_type_keyword(word, language))
            state.names.next_name = NameRole::Type;
        else
            state.names.next_name = NameRole::None;
        return ink;
    }

    NameRole expected = state.names.next_name;
    state.names.next_name = NameRole::None;
    if (expected == NameRole::Type)
        return Ink::Type;
    if (expected == NameRole::Function)
        return Ink::Function;

    // A single capital letter is a type parameter in <T>, T:, or T, in typed languages.
    bool typed_language = language == Language::TypeScript || language == Language::TSX || language == Language::Swift ||
                          language == Language::Kotlin || language == Language::Luau;
    if (typed_language && word.size() == 1 && word.front() >= u'A' && word.front() <= u'Z') {
        size_t before = previous_non_space(line, start);
        char16_t earlier = before ? line[before - 1] : 0;
        if (earlier == u'<' || earlier == u':' || follow == u'>' || follow == u':' || follow == u',')
            return Ink::Type;
    }

    // Register names: x0, w12, r8, %rax-style v1 and q3, and sp, lr, fp, pc.
    if (language == Language::Assembly) {
        Text digits = word;
        if (word.starts_with(u"%"))
            digits.remove_prefix(1);

        if (digits.size() >= 2 && is_any_of(lowercase(digits.front()), u"xwrvsdq")) {
            bool numbered = true;
            for (char16_t ch : digits.substr(1)) {
                if (!is_digit(ch))
                    numbered = false;
            }
            if (numbered)
                return Ink::Type;
        }

        if (same_text(word, u"sp") || same_text(word, u"lr") || same_text(word, u"fp") || same_text(word, u"pc"))
            return Ink::Type;
    }

    return ink;
}

//
// The general code tokenizer, for every language but Markdown, markup, and Lisp.
//

// How words are colored: by the keyword tables, by C++ and Rust's declaration tracking, or as parts of a Rust
// attribute.
enum class WordColoring : uint8_t { Ordinary, Contextual, RustAttribute };

static void tokenize_general_code(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    // The language checks the loop needs, worked out once per line.
    bool c_family = is_c_family(language);
    bool cpp = language == Language::Cpp || language == Language::ObjectiveCpp;
    bool rust = language == Language::Rust;
    bool odin = language == Language::Odin;
    bool gml = language == Language::GML;
    bool javascript = is_javascript_family(language);
    bool jsx = is_jsx(language);
    bool php = language == Language::PHP;
    bool css = is_css_family(language);
    bool ini_or_toml = is_ini_or_toml(language);
    bool json = is_json_family(language);
    bool yaml = language == Language::YAML;
    bool clojure = language == Language::Clojure;
    bool makefile = language == Language::Makefile;
    bool regex = javascript || language == Language::Ruby || language == Language::Perl;
    bool bare_variables = interpolates_bare_variables(language);

    const CommentSyntax &comments = language_info(language).comments;
    char16_t block_comment_start = comments.open.empty() ? 0 : comments.open.front();
    char16_t line_comment_start = comments.line.empty() ? 0 : comments.line.front();
    bool other_line_comments = php || language == Language::INI || language == Language::Assembly ||
                               language == Language::VisualBasic || odin;

    size_t first = skip_spaces(line, 0);
    bool expects_value = !regex || state.expects_value;

    if (heredoc_line(line, language, state, tokens, finish_line)) {
        if (!finish_line)
            state.mode = LexMode::Raw;
        return;
    }

    // A YAML block scalar continues while lines are indented past its key.
    if (state.mode == LexMode::BlockScalar) {
        if (first >= state.depth || first == line.size()) {
            if (!line.empty())
                add_token(tokens, 0, line.size(), Ink::String, true);
            return;
        }

        set_mode(state, LexMode::Code);
    }

    if (line.empty()) {
        if (finish_line && (state.mode == LexMode::LineComment ||
                            ((state.mode == LexMode::Quoted || state.mode == LexMode::Raw) && !state.multiline)))
            set_mode(state, LexMode::Code);
        return;
    }

    // Ruby's =begin ... =end and Perl's POD blocks start at the beginning of a line.
    bool ruby_block = language == Language::Ruby && first == 0 && line.starts_with(u"=begin") &&
                      (line.size() == 6 || is_space(line[6]));
    bool perl_pod = language == Language::Perl && first == 0 &&
                    (line.starts_with(u"=pod") || line.starts_with(u"=head") || line.starts_with(u"=begin") ||
                     line.starts_with(u"=item") || line.starts_with(u"=over"));
    if (ruby_block || perl_pod) {
        set_mode_and_closing(state, LexMode::BlockComment, language == Language::Ruby ? u"=end" : u"=cut", true);
        state.depth = 1;
        add_token(tokens, 0, line.size(), Ink::Comment, true);
        return;
    }

    if (state.mode == LexMode::BlockComment && (lex_closing_is(state.closing, u"=end") || lex_closing_is(state.closing, u"=cut"))) {
        add_token(tokens, 0, line.size(), Ink::Comment, true);

        Text end_marker(state.closing.text, state.closing.length);
        if (line.starts_with(end_marker) && !is_name_char(char_at(line, end_marker.size())))
            set_mode(state, LexMode::Code);
        return;
    }

    WordColoring words = rust || cpp ? WordColoring::Contextual : WordColoring::Ordinary;
    if (rust && state.attribute.brackets)
        words = WordColoring::RustAttribute;

    for (size_t index = 0; index < line.size();) {
        size_t start = index;
        char16_t ch = line[index];
        char16_t next = char_at(line, index + 1);

        // Markup inside JSX and PHP.
        if ((jsx || php) && is_markup_mode(state.mode)) {
            index = markup_step(line, index, language, state, tokens);
            expects_value = state.mode == LexMode::Code;
            continue;
        }

        // A string that is already open.
        if (state.mode == LexMode::Quoted || state.mode == LexMode::Raw) {
            size_t open_interpolations = state.interpolation_count;
            index = continue_string(line, index, index, language, state, tokens, finish_line);
            expects_value = state.interpolation_count > open_interpolations;
            continue;
        }

        // A comment that is already open.
        if (state.mode == LexMode::BlockComment || state.mode == LexMode::LineComment) {
            if (php && lex_closing_is(state.closing, u"-->")) {
                index = markup_step(line, index, language, state, tokens);
                continue;
            }

            index = continue_comment(line, index, language, state, finish_line);
            add_token(tokens, start, index - start, Ink::Comment, true);
            continue;
        }

        if (is_space(ch)) {
            index = skip_spaces(line, index + 1);
            continue;
        }

        // Block comments, including CMake's #[[ ... ]].
        if (ch == block_comment_start || (language == Language::CMake && ch == u'#')) {
            size_t body = begin_block_comment(line, index, language, state);
            if (body != index) {
                index = continue_comment(line, body, language, state, finish_line);
                add_token(tokens, start, index - start, Ink::Comment, true);
                continue;
            }
        }

        // Line comments run to the end of the line.
        if ((ch == line_comment_start || other_line_comments) && line_comment_at(line, index, first, language)) {
            if (!finish_line || (c_family && line.ends_with(u"\\")))
                state.mode = LexMode::LineComment;

            if (gml && starts_at(line, index, u"///")) {
                add_gml_doc_comment(line, start, tokens);
            } else {
                bool go_directive = language == Language::Go && (starts_at(line, index, u"//go:") || starts_at(line, index, u"//line "));
                add_token(tokens, start, line.size() - start, go_directive ? Ink::Directive : Ink::Comment, true);
            }
            break;
        }

        // PHP's <?php and ?> tags.
        if (php) {
            size_t length = php_open_tag_length(line.substr(index));
            if (length) {
                add_token(tokens, start, length, Ink::Directive, true);
                index += length;
                continue;
            }

            if (starts_at(line, index, u"?>")) {
                add_token(tokens, start, 2, Ink::Directive, true);
                index += 2;
                state.mode = LexMode::MarkupText;
                continue;
            }
        }

        // A JSX element inside code.
        if (jsx && state.markup.root_count < LEX_JSX_NESTING_LIMIT && starts_jsx_element(line, index, expects_value, language)) {
            state.markup.roots[state.markup.root_count++] = state.markup.depth;
            state.mode = LexMode::MarkupText;
            index = markup_step(line, index, language, state, tokens);
            continue;
        }

        if (css) {
            size_t after = css_token_end(line, index, language, state, tokens);
            if (after != index) {
                index = after;
                continue;
            }

            // CSS uses the name tracker's brace depth to tell properties from nested selectors.
            if (ch == u'{')
                ++state.names.brace_depth;
            else if (ch == u'}' && state.names.brace_depth)
                --state.names.brace_depth;
        }

        if (ini_or_toml || yaml) {
            size_t after = data_token_end(line, index, first, language, state, tokens);
            if (after != index) {
                index = after;
                continue;
            }
        }

        // Here-documents. In shells, << inside $(( )) arithmetic is a shift instead.
        if (ch == u'<' && (!is_shell(language) || expects_value || !state.names.groups)) {
            size_t after = begin_heredoc(line, index, language, state);
            if (after != index) {
                add_token(tokens, start, after - start, Ink::Directive, true);
                index = after;
                continue;
            }
        }

        // Preprocessor directives, with the <header> of #include colored as a string.
        if (c_family && index == first && ch == u'#') {
            size_t directive = skip_spaces(line, index + 1);
            index = name_end(line, directive);
            Text name = line.substr(directive, index - directive);
            size_t header = skip_spaces(line, index);

            if ((same_text(name, u"include") || same_text(name, u"include_next") || same_text(name, u"import")) && char_at(line, header) == u'<') {
                add_token(tokens, start, index - start, Ink::Directive);

                size_t end = line.find(u'>', header + 1);
                index = end == NOT_FOUND ? line.size() : end + 1;
                add_token(tokens, header, index - header, Ink::String, true);

                if (end == NOT_FOUND && !finish_line)
                    set_mode_and_closing(state, LexMode::Raw, u">");
                continue;
            }

            add_token(tokens, start, index - start, Ink::Directive);
            continue;
        }

        if (ch == u'#' && rust && words == WordColoring::Contextual) {
            size_t body = begin_rust_attribute(line, index, state.attribute, tokens);
            if (body != index) {
                words = WordColoring::RustAttribute;
                index = body;
                continue;
            }
        }

        // Odin's #+build tags, @(attributes), and --- for uninitialized values.
        if (odin && starts_at(line, index, u"#+")) {
            index = name_end(line, index + 2);
            add_token(tokens, start, index - start, Ink::Directive, true);

            size_t arguments = index;
            while (index < line.size() && !starts_at(line, index, u"//") && !starts_at(line, index, u"/*"))
                ++index;
            if (index > arguments)
                add_token(tokens, arguments, index - arguments, Ink::Text, true);
            continue;
        }

        if (odin && ch == u'@' && !state.names.groups && char_at(line, skip_spaces(line, index + 1)) == u'(') {
            state.names.groups = 1;
            state.names.parameter_start = true;
            add_token(tokens, start, 1, Ink::Directive);
            index = skip_spaces(line, index + 1) + 1;
            continue;
        }

        if (odin && starts_at(line, index, u"---")) {
            index += 3;
            add_token(tokens, start, 3, Ink::Constant);
            continue;
        }

        if (gml && ch == u'#' && index == first) {
            size_t after = gml_directive_end(line, index, tokens);
            if (after != index) {
                index = after;
                continue;
            }
        }

        // GameMaker's [$ accessor, which isn't a $"..." string.
        if (gml && ch == u'$' && index && line[index - 1] == u'[') {
            ++index;
            continue;
        }

        // Strings start with a quote or one of the language's prefix characters.
        size_t body = index;
        if (ch == u'"' || ch == u'\'' || ch == u'`' || is_string_prefix(ch, language))
            body = begin_string(line, index, language, state, expects_value);

        if (body != index) {
            if (words == WordColoring::Contextual)
                clear_name_expectation(state.names);
            else if (words == WordColoring::RustAttribute)
                state.attribute.part = RustAttributePart::Arguments;

            // A JSON string followed by : is a key.
            if (json) {
                size_t end = quoted_string_end(line, body, u'"');
                if (end > body && char_at(line, skip_spaces(line, end)) == u':')
                    state.string_ink = Ink::Type;
            }

            size_t open_interpolations = state.interpolation_count;
            index = continue_string(line, start, body, language, state, tokens, finish_line);
            expects_value = state.interpolation_count > open_interpolations;
            continue;
        }

        size_t directive = ch == u'@' || ch == u'#' ? directive_end(line, index, first, language) : index;
        if (directive != index) {
            index = directive;
            add_token(tokens, start, index - start, Ink::Directive);
            continue;
        }

        // Zig's \\ multiline string lines.
        if (language == Language::Zig && starts_at(line, index, u"\\\\")) {
            add_token(tokens, start, line.size() - start, Ink::String, true);
            break;
        }

        // CMake's [[bracket arguments]].
        if (language == Language::CMake && ch == u'[' && begin_long_bracket(line, index, state, LexMode::Raw) != index) {
            size_t string_body = index + closing_size(state.closing);
            index = continue_string(line, start, string_body, language, state, tokens, finish_line);
            continue;
        }

        // `quoted names` in Swift, Kotlin, and Scala.
        if (ch == u'`' && (language == Language::Swift || language == Language::Kotlin || language == Language::Scala)) {
            size_t end = line.find(u'`', index + 1);
            index = end == NOT_FOUND ? line.size() : end + 1;
            add_token(tokens, start, index - start, Ink::Name, true);
            continue;
        }

        // Ruby :symbols.
        if (ch == u':' && language == Language::Ruby && is_name_start(next) && (!index || line[index - 1] != u':')) {
            index = ruby_name_end(line, index + 2);
            add_token(tokens, start, index - start, Ink::Constant);
            continue;
        }

        // ${name} in shells and similar, and $(name) in Makefiles.
        bool dollar_variables = bare_variables || language == Language::Perl || language == Language::Makefile ||
                                language == Language::Dockerfile;
        if (ch == u'$' && (dollar_variables || language == Language::CMake) &&
            (next == u'{' || (next == u'(' && language == Language::Makefile))) {
            char16_t stop = next == u'{' ? u'}' : u')';
            size_t end = line.find(stop, index + 2);
            if (end != NOT_FOUND && line.substr(index + 2, end - index - 2).find_first_of(u"$({") == NOT_FOUND) {
                add_token(tokens, start, end - start + 1, Ink::Name, true);
                index = end + 1;
                expects_value = false;
            } else {
                ++index;
            }
            continue;
        }

        // $name.
        if (ch == u'$' && dollar_variables && variable_end(line, index) != index) {
            index = variable_end(line, index);
            add_token(tokens, start, index - start, word_ink(line.substr(start, index - start), language, 0));
            expects_value = false;
            continue;
        }

        if (gml && (ch == u'$' || ch == u'#')) {
            size_t end = gml_hex_number_end(line, index);
            if (end != index) {
                index = end;
                add_token(tokens, start, index - start, Ink::Number);
                continue;
            }
        }

        // Numbers, including .5 but not the 5 in a..5.
        if (is_digit(ch) || (ch == u'.' && is_digit(next) && (!index || line[index - 1] != u'.'))) {
            index = odin ? odin_number_end(line, index) : number_end(line, index);
            if (words == WordColoring::Contextual)
                clear_name_expectation(state.names);
            else if (words == WordColoring::RustAttribute)
                state.attribute.part = RustAttributePart::Arguments;

            add_token(tokens, start, index - start, Ink::Number);
            expects_value = false;
            continue;
        }

        // Words, and the forms that read like words: R's .name, Clojure's :keyword, Rust's 'lifetime, and
        // assembly's %register.
        bool word_start = is_name_start(ch) ||
                          (ch == u'.' && (language == Language::R || (makefile && is_name_start(next)))) ||
                          (clojure && ch == u':' && is_clojure_name_char(next)) ||
                          (rust && ch == u'\'' && is_name_start(next)) ||
                          (language == Language::Assembly && ch == u'%' && is_name_start(next));
        if (word_start) {
            bool lifetime = ch == u'\'';
            bool raw_identifier = rust && starts_at(line, index, u"r#") && is_name_start(char_at(line, index + 2));
            if (lifetime)
                ++index;
            if (raw_identifier)
                index += 2;

            size_t word_begin = index;
            index = language == Language::Ruby ? ruby_name_end(line, index + 1) : name_end(line, index + 1);

            // Longer words: Clojure's punctuation, R's and Make's dotted names, Haskell's primes, and Java's non-sealed.
            if (clojure) {
                while (is_clojure_name_char(char_at(line, index)))
                    ++index;
            } else if (language == Language::R || makefile) {
                while (char_at(line, index) == u'.')
                    index = name_end(line, index + 1);
            } else if (language == Language::Haskell || language == Language::FSharp) {
                while (char_at(line, index) == u'\'')
                    index = name_end(line, index + 1);
            } else if (language == Language::Java) {
                Text non_sealed = u"non-sealed";
                size_t end = word_begin + non_sealed.size();
                if (is_word_at(line, word_begin, non_sealed) && is_java_modifier_context(line, word_begin, end))
                    index = end;
            }

            Text word = line.substr(word_begin, index - word_begin);
            Ink ink = Ink::Text;
            bool always_add = false;

            if (lifetime) {
                ink = Ink::Type;
                if (words == WordColoring::RustAttribute)
                    state.attribute.part = RustAttributePart::Arguments;
                else if (at_generic_parameter_start(state.names))
                    state.names.parameter_start = false;
            } else if (words == WordColoring::Contextual) {
                // Names in C++ and Rust get a token even in the foreground color, for completion and navigation.
                ink = contextual_word_ink(line, word, index, language, state.names, raw_identifier);
                always_add = true;
            } else if (words == WordColoring::RustAttribute) {
                ink = rust_attribute_word_ink(line, word, index, raw_identifier, state.attribute);
            } else if (json) {
                ink = (word_flags(language, word) & WORD_CONSTANT) ? Ink::Constant : Ink::Text;
            } else {
                ink = other_word_ink(line, word, start, index, language, state);

                // A Makefile target: name: but not name := value.
                size_t after = skip_spaces(line, index);
                if (makefile && !(word.starts_with(u".") && ink == Ink::Constant) &&
                    char_at(line, after) == u':' && char_at(line, after + 1) != u'=')
                    ink = Ink::Function;
            }

            if (ink != Ink::Text || always_add)
                add_token(tokens, start, index - start, ink);

            expects_value = same_text(word, u"return") || same_text(word, u"throw") || same_text(word, u"case") || same_text(word, u"yield") || same_text(word, u"in");
            continue;
        }

        // Regular expression literals, where a value can start.
        if (regex && ch == u'/' && expects_value) {
            size_t end = regex_end(line, index);

            // An unclosed JavaScript literal runs to the end of the line. Elsewhere the / is division.
            if (end != index)
                index = end;
            else
                index = javascript ? line.size() : index + 1;

            if (end != start || javascript)
                add_token(tokens, start, index - start, Ink::String);

            if (end == start && !finish_line && javascript)
                set_mode_and_closing(state, LexMode::Raw, u"/");

            expects_value = false;
            continue;
        }

        // Everything else is punctuation.
        bool returns_to_markup = jsx && jsx_expression_punctuation(ch, state);
        if (!returns_to_markup)
            interpolation_punctuation(ch, state);

        expects_value = has_char_class(ch, CHAR_VALUE_FOLLOWS) || (ch == u'>' && index && line[index - 1] == u'=');

        if (words == WordColoring::Contextual) {
            index = name_context_punctuation(line, index, rust, state.names);
            continue;
        }

        if (words == WordColoring::RustAttribute) {
            rust_attribute_punctuation(ch, state.attribute);
            if (state.attribute.brackets == 0)
                words = WordColoring::Contextual;
        }

        // Odin's @(...) attribute list: the first word after ( or , is an attribute name.
        if (odin && state.names.groups) {
            if (ch == u'(' || ch == u'[' || ch == u'{')
                ++state.names.groups;
            else if (ch == u')' || ch == u']' || ch == u'}')
                --state.names.groups;
            state.names.parameter_start = state.names.groups == 1 && ch == u',';
        }

        if (ch == u';' || ch == u'=' || ch == u'{')
            state.names.next_name = NameRole::None;

        ++index;
    }

    if (regex)
        state.expects_value = expects_value;
}

//
// Common Lisp.
//

static size_t lisp_digits_end(Text text, size_t at, unsigned radix)
{
    while (at < text.size()) {
        char16_t ch = lowercase(text[at]);
        unsigned value = is_digit(ch) ? unsigned(ch - u'0') : ch >= u'a' && ch <= u'z' ? unsigned(ch - u'a') + 10 : 36;
        if (value >= radix)
            break;
        ++at;
    }

    return at;
}

// Integers, ratios like 1/3, and floats like 1.5d0. A radix from #x or #36r reads integers and ratios only.
static bool is_lisp_number(Text word, unsigned radix = 0)
{
    if (word.starts_with(u"+") || word.starts_with(u"-"))
        word.remove_prefix(1);

    unsigned base = radix ? radix : 10;
    size_t at = lisp_digits_end(word, 0, base);
    bool digits = at != 0;

    if (digits && char_at(word, at) == u'/') {
        size_t denominator = at + 1;
        return denominator < word.size() && lisp_digits_end(word, denominator, base) == word.size();
    }

    if (radix)
        return digits && at == word.size();

    if (char_at(word, at) == u'.') {
        size_t fraction = ++at;
        at = lisp_digits_end(word, at, 10);
        digits = digits || at != fraction;
    }

    if (digits && is_any_of(lowercase(char_at(word, at)), u"esfdl")) {
        ++at;
        if (char_at(word, at) == u'+' || char_at(word, at) == u'-')
            ++at;

        size_t exponent = at;
        at = lisp_digits_end(word, at, 10);
        digits = at != exponent;
    }

    return digits && at == word.size();
}

// Where a symbol ends. |bars| and backslashes quote characters, and a quoted part can continue onto the next line.
static size_t lisp_symbol_end(Text line, size_t at, LexState &state, bool &quoted)
{
    bool in_bars = state.mode == LexMode::Raw && !closing_is_empty(state.closing);
    bool continued = false;

    while (at < line.size()) {
        char16_t ch = line[at];
        if (ch == u'\\') {
            continued = at + 1 == line.size();
            quoted = true;
            at = escape_end(line, at, Language::CommonLisp);
        } else if (ch == u'|') {
            in_bars = !in_bars;
            quoted = true;
            ++at;
        } else if (in_bars || is_lisp_symbol_char(ch)) {
            ++at;
        } else {
            break;
        }
    }

    if (in_bars || continued)
        set_mode_and_closing(state, LexMode::Raw, in_bars ? u"|" : u"", true);
    else if (state.mode == LexMode::Raw)
        set_mode(state, LexMode::Code);

    return at;
}

static Ink lisp_word_ink(Text word, LexState &state)
{
    NameRole expected = state.names.next_name;
    bool list_head = state.lisp_list_head;
    state.names.next_name = NameRole::None;
    state.lisp_list_head = false;

    if (expected == NameRole::Function)
        return Ink::Function;
    if (expected == NameRole::Type)
        return Ink::Type;
    if (same_text(word, u"."))
        return Ink::Text;
    if (is_lisp_number(word))
        return Ink::Number;
    if (word.starts_with(u":"))
        return Ink::Constant;

    // package:name colors by name.
    Text name = word.substr(word.rfind(u':') + 1);
    Ink ink = word_ink(name, Language::CommonLisp, 0);

    // A defining form at the head of a list colors the name it defines.
    if (list_head && ink == Ink::Keyword) {
        static constexpr Text FUNCTION_FORMS[] = {u"defun", u"defmacro", u"defgeneric", u"defmethod", u"define-compiler-macro"};
        static constexpr Text TYPE_FORMS[] = {u"defclass", u"defstruct", u"deftype", u"define-condition"};

        for (Text form : FUNCTION_FORMS) {
            if (name.size() == form.size() && starts_with_ignoring_case(name, form))
                state.names.next_name = NameRole::Function;
        }

        for (Text form : TYPE_FORMS) {
            if (name.size() == form.size() && starts_with_ignoring_case(name, form))
                state.names.next_name = NameRole::Type;
        }
    }

    return ink;
}

// Reader macros: #\c characters, #'function, #( vectors, #x1F numbers, #+feature, and the rest. Returns start
// when there isn't one.
static size_t lisp_reader_macro_end(Text line, size_t start, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    size_t dispatch = start + 1;
    unsigned radix = 0;
    while (is_digit(char_at(line, dispatch))) {
        radix = radix * 10 + unsigned(line[dispatch] - u'0');
        if (radix > 37)
            radix = 37;
        ++dispatch;
    }

    char16_t kind = lowercase(char_at(line, dispatch));
    size_t end = dispatch + 1;
    if (end > line.size() || !is_any_of(kind, u"\\'(+-.=*#abcoprsx"))
        return start;

    state.lisp_list_head = false;
    state.names.next_name = kind == u'\'' ? NameRole::Function : NameRole::None;

    if (kind == u'\\') {
        // A character, such as #\a or #\Space.
        char16_t first = char_at(line, end);
        if (end < line.size())
            ++end;
        else if (!finish_line)
            set_mode(state, LexMode::Raw);

        if (is_lisp_symbol_char(first)) {
            while (is_lisp_symbol_char(char_at(line, end)))
                ++end;
        }

        add_token(tokens, start, end - start, Ink::String, true);
    } else if (kind == u'(') {
        // The vector's parenthesis still pairs with its closing one.
        add_token(tokens, start, dispatch - start, Ink::Directive);
    } else {
        if (kind == u'b') radix = 2;
        if (kind == u'o') radix = 8;
        if (kind == u'x') radix = 16;

        Ink ink = Ink::Directive;
        if ((kind == u'b' || kind == u'o' || kind == u'x' || kind == u'r') && radix >= 2 && radix <= 36) {
            size_t payload = end;
            while (is_lisp_symbol_char(char_at(line, end)))
                ++end;
            if (is_lisp_number(line.substr(payload, end - payload), radix))
                ink = Ink::Number;
        } else if (kind == u'*') {
            // A bit vector, #*1011.
            while (char_at(line, end) == u'0' || char_at(line, end) == u'1')
                ++end;
            ink = Ink::Number;
        }

        add_token(tokens, start, end - start, ink);
    }

    return end;
}

static void tokenize_lisp(Text line, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    const Language language = Language::CommonLisp;

    for (size_t at = 0; at < line.size();) {
        size_t start = at;
        char16_t ch = line[at];

        if (state.mode == LexMode::Quoted) {
            at = continue_string(line, start, at, language, state, tokens, finish_line);
            continue;
        }

        // A |quoted symbol| or escaped character continuing from the line before.
        if (state.mode == LexMode::Raw) {
            bool quoted = true;
            at = lisp_symbol_end(line, at, state, quoted);
            if (at > start)
                add_token(tokens, start, at - start, Ink::Name, true);
            continue;
        }

        if (state.mode == LexMode::BlockComment || state.mode == LexMode::LineComment) {
            at = continue_comment(line, at, language, state, finish_line);
            add_token(tokens, start, at - start, Ink::Comment, true);
            continue;
        }

        // A #! script line, and ; comments.
        if ((at == 0 && line.starts_with(u"#!")) || ch == u';') {
            if (!finish_line)
                set_mode(state, LexMode::LineComment);
            add_token(tokens, start, line.size() - start, Ink::Comment, true);
            return;
        }

        if (ch == u'#' && char_at(line, at + 1) == u'|') {
            size_t body = begin_block_comment(line, at, language, state);
            at = continue_comment(line, body, language, state, finish_line);
            add_token(tokens, start, at - start, Ink::Comment, true);
            continue;
        }

        if (ch == u'"') {
            state.lisp_list_head = false;
            state.names.next_name = NameRole::None;
            set_mode_and_closing(state, LexMode::Quoted, u"\"", true);
            at = continue_string(line, start, at + 1, language, state, tokens, finish_line);
            continue;
        }

        if (ch == u'(' || ch == u')') {
            state.lisp_list_head = ch == u'(';
            state.names.next_name = NameRole::None;
            ++at;
            continue;
        }

        // Quote, quasiquote, and unquote: ' ` , ,@ ,.
        if (ch == u'\'' || ch == u'`' || ch == u',') {
            state.lisp_list_head = false;
            state.names.next_name = NameRole::None;
            at += ch == u',' && (char_at(line, at + 1) == u'@' || char_at(line, at + 1) == u'.') ? 2 : 1;
            add_token(tokens, start, at - start, Ink::Directive);
            continue;
        }

        if (ch == u'#') {
            size_t end = lisp_reader_macro_end(line, at, state, tokens, finish_line);
            if (end != at) {
                at = end;
                continue;
            }
        }

        if (is_lisp_symbol_char(ch) || ch == u'|' || ch == u'\\') {
            bool quoted = false;
            at = lisp_symbol_end(line, at, state, quoted);
            Text word = line.substr(start, at - start);

            if (quoted) {
                state.lisp_list_head = false;
                state.names.next_name = NameRole::None;
                add_token(tokens, start, at - start, Ink::Name, true);
            } else {
                // Brackets in a symbol are part of its name, not code brackets.
                bool literal_brackets = word.find_first_of(u"[]{}") != NOT_FOUND;
                add_token(tokens, start, at - start, lisp_word_ink(word, state), literal_brackets);
            }
            continue;
        }

        ++at;
    }

    if (line.empty() && finish_line && state.mode == LexMode::Raw && closing_is_empty(state.closing))
        set_mode(state, LexMode::Code);
}

static void tokenize_code(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    if (language == Language::CommonLisp)
        tokenize_lisp(line, state, tokens, finish_line);
    else
        tokenize_general_code(line, language, state, tokens, finish_line);
}

//
// Markup documents.
//

// Where </script> or </style> starts, or the end of the line.
static size_t raw_element_end(Text line, size_t start, RawElement element)
{
    Text end_tag = element == RawElement::Style ? u"</style" : u"</script";
    for (size_t at = line.find(u'<', start); at != NOT_FOUND; at = line.find(u'<', at + 1)) {
        if (starts_with_ignoring_case(line.substr(at), end_tag)) {
            char16_t next = char_at(line, at + end_tag.size());
            if (next == u'>' || next == u'/' || !next || is_space(next))
                return at;
        }
    }

    return line.size();
}

// Lexes code from at to end of the line and moves its tokens to their place in the whole line.
static void tokenize_embedded_code(Text line, size_t at, size_t end, Language language, LexState &state,
                                   std::vector<Token> &tokens, bool finish_line)
{
    size_t before = tokens.size();
    tokenize_code(line.substr(at, end - at), language, state, tokens, finish_line);

    for (size_t index = before; index < tokens.size(); ++index)
        tokens[index].start += uint32_t(at);
}

static void tokenize_markup(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    if (state.mode == LexMode::Code && !state.markup.raw_content && language != Language::PHP)
        state.mode = LexMode::MarkupText;

    for (size_t at = 0; at < line.size();) {
        // The body of <script> or <style>.
        if (state.markup.raw_content) {
            size_t end = raw_element_end(line, at, state.markup.raw_element);
            if (state.embedded == Language::Plain) {
                if (end > at)
                    add_token(tokens, at, end - at, Ink::Text, true);
            } else {
                tokenize_embedded_code(line, at, end, state.embedded, state, tokens, end == line.size() && finish_line);
            }

            if (end == line.size())
                return;

            // The closing tag: everything about the embedded code is done.
            at = end;
            state.embedded = Language::Plain;
            state.markup = LexMarkup();
            state.names = LexNames();
            clear_interpolations(state);
            state.expects_value = true;
            set_mode(state, LexMode::MarkupText);
            continue;
        }

        // PHP code between <?php and ?>.
        if (language == Language::PHP && !is_markup_mode(state.mode) &&
            !(state.mode == LexMode::BlockComment && lex_closing_is(state.closing, u"-->"))) {
            tokenize_embedded_code(line, at, line.size(), language, state, tokens, finish_line);
            return;
        }

        at = markup_step(line, at, language, state, tokens);
    }
}

//
// Markdown.
//

static void tokenize_markdown(Text line, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    size_t first = skip_spaces(line, 0);
    char16_t mark = char_at(line, first);
    size_t run = first;
    if (mark == u'`' || mark == u'~') {
        while (char_at(line, run) == mark)
            ++run;
    }

    // Inside a fenced code block: the closing fence, or a line of code in the fence's language.
    if (state.fence) {
        if (mark == state.fence && run - first >= state.fence_length && skip_spaces(line, run) == line.size()) {
            add_token(tokens, first, run - first, Ink::Directive, true);
            state = LexState();
        } else if (state.fence_language == Language::HTML || state.fence_language == Language::XML) {
            tokenize_markup(line, state.fence_language, state, tokens, finish_line);
        } else if (state.fence_language != Language::Plain) {
            tokenize_code(line, state.fence_language, state, tokens, finish_line);
        } else if (!line.empty()) {
            add_token(tokens, 0, line.size(), Ink::String, true);
        }
        return;
    }

    // An opening fence: ``` or ~~~ with an optional language name.
    if (state.mode == LexMode::Code && first <= 3 && run - first >= 3 && (mark == u'~' || line.find(u'`', run) == NOT_FOUND)) {
        size_t info = skip_spaces(line, run);
        size_t end = info;
        while (end < line.size() && !is_space(line[end]))
            ++end;

        state.fence = mark;
        state.fence_length = uint16_t(run - first);
        state.fence_language = language_for_fence(line.substr(info, end - info));
        if (state.fence_language == Language::Markdown)
            state.fence_language = Language::Plain;

        add_token(tokens, first, run - first, Ink::Directive, true);
        if (end > info)
            add_token(tokens, info, end - info, Ink::Type, true);
        return;
    }

    // Block markers: the rest of an open <!-- comment -->, headings, quotes, and list items.
    size_t at = first;
    if (state.mode == LexMode::BlockComment) {
        size_t end = line.find(u"-->");
        at = end == NOT_FOUND ? line.size() : end + 3;
        if (at)
            add_token(tokens, 0, at, Ink::Comment, true);

        if (end == NOT_FOUND)
            return;

        set_mode(state, LexMode::Code);
    } else if (mark == u'#') {
        run = first + 1;
        while (char_at(line, run) == u'#')
            ++run;

        if (run - first <= 6 && (!char_at(line, run) || is_space(line[run]))) {
            add_token(tokens, first, line.size() - first, Ink::Keyword, true);
            return;
        }
    } else if ((mark == u'>' || mark == u'-' || mark == u'+' || mark == u'*') && is_space(char_at(line, first + 1))) {
        add_token(tokens, first, 1, Ink::Directive, true);
        at = first + 1;
    } else if (is_digit(mark)) {
        size_t end = first + 1;
        while (is_digit(char_at(line, end)))
            ++end;

        if ((char_at(line, end) == u'.' || char_at(line, end) == u')') && is_space(char_at(line, end + 1))) {
            add_token(tokens, first, end + 1 - first, Ink::Directive, true);
            at = end + 1;
        }
    }

    // Inline: comments, escapes, code spans, emphasis, and links.
    while (at < line.size()) {
        char16_t ch = line[at];

        if (starts_at(line, at, u"<!--")) {
            size_t end = line.find(u"-->", at + 4);
            if (end == NOT_FOUND) {
                set_mode_and_closing(state, LexMode::BlockComment, u"-->", true);
                add_token(tokens, at, line.size() - at, Ink::Comment, true);
                return;
            }

            add_token(tokens, at, end + 3 - at, Ink::Comment, true);
            at = end + 3;
        } else if (ch == u'\\' && at + 1 < line.size()) {
            add_token(tokens, at, 2, Ink::Escape, true);
            at += 2;
        } else if (ch == u'`' || ch == u'*' || ch == u'_' || ch == u'~') {
            size_t end = at + 1;
            while (char_at(line, end) == ch)
                ++end;

            Text delimiter = line.substr(at, end - at);
            size_t close = end;
            if (ch == u'`') {
                // A code span closes with a run of the same length.
                while ((close = line.find(u'`', close)) != NOT_FOUND) {
                    size_t after = close + 1;
                    while (char_at(line, after) == u'`')
                        ++after;

                    if (after - close == delimiter.size())
                        break;
                    close = after;
                }
            } else {
                // Emphasis can't start before a space, ~ needs two, and _ inside a word is just a character.
                close = line.find(delimiter, end);
                if ((ch == u'~' && delimiter.size() != 2) || is_space(char_at(line, end)) ||
                    (ch == u'_' && at && is_name_char(line[at - 1])))
                    close = NOT_FOUND;
            }

            if (close != NOT_FOUND && close > end) {
                size_t after = close + delimiter.size();
                add_token(tokens, at, after - at, ch == u'`' ? Ink::String : Ink::Type, true);
                at = after;
            } else {
                at = end;
            }
        } else if (ch == u'[' || (ch == u'!' && char_at(line, at + 1) == u'[')) {
            // [caption](target) and ![image](target), with parentheses allowed in the target.
            size_t caption = line.find(u']', at + 1);
            size_t end = NOT_FOUND;
            if (caption != NOT_FOUND && char_at(line, caption + 1) == u'(') {
                unsigned nesting = 1;
                for (size_t index = caption + 2; index < line.size(); ++index) {
                    if (line[index] == u'\\') {
                        ++index;
                    } else if (line[index] == u'(') {
                        ++nesting;
                    } else if (line[index] == u')' && --nesting == 0) {
                        end = index;
                        break;
                    }
                }
            }

            if (end != NOT_FOUND) {
                add_token(tokens, at, caption + 1 - at, Ink::Function, true);
                add_token(tokens, caption + 1, end - caption, Ink::String, true);
                at = end + 1;
            } else {
                ++at;
            }
        } else {
            ++at;
        }
    }
}

//
// Entry point.
//

void tokenize_line(Text line, Language language, LexState &state, std::vector<Token> &tokens, bool finish_line)
{
    tokens.clear();

    if (language == Language::Plain || language == Language::Count)
        return;

    if (language == Language::Markdown) {
        tokenize_markdown(line, state, tokens, finish_line);
    } else if (language == Language::HTML || language == Language::XML) {
        tokenize_markup(line, language, state, tokens, finish_line);
    } else if (language == Language::PHP) {
        // A PHP file can start in HTML.
        Text rest = line.substr(skip_spaces(line, 0));
        if (state.mode == LexMode::Code && !state.markup.raw_content && !php_open_tag_length(rest) &&
            rest.starts_with(u"<") && (is_name_start(char_at(rest, 1)) || rest.starts_with(u"<!")))
            state.mode = LexMode::MarkupText;

        tokenize_markup(line, language, state, tokens, finish_line);
    } else if (language == Language::Makefile && line.starts_with(u"\t")) {
        // Recipe lines are shell commands.
        tokenize_code(line, Language::Bash, state, tokens, finish_line);
    } else {
        tokenize_code(line, language, state, tokens, finish_line);
    }
}
