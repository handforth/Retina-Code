// Text buffer tests.
//
//   text_test check <folder>...   random edits on every file in the folders, run on a TextBuffer and on Qt's
//                                 QTextDocument side by side, the way QPlainTextEdit makes them
//   text_test bench <folder>...   load, typing, and lexing times and memory, for a large text made from the files
//
// After every edit, check compares the buffer's text with the document's. Undo and redo run on the buffer alone and
// must bring back the text it had at that point of its history, which the check remembers by hash; the document then
// starts over from the buffer's text. The check also checks the buffer's line starts and lexer states against a fresh
// pass over its text, and that it counts as modified exactly when its history isn't at the saved point.

// The shared code comes before Qt's headers, as in main_qt.cpp, because Qt defines words like slots as macros.
#include "Languages.cpp"
#include "Lexer.cpp"
#include "TextBuffer.cpp"

#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QTextCursor>
#include <QTextDocument>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <psapi.h>

#include <cstdio>

struct TestFile {
    QString path;
    QString text;
};

// Every file under the folders, with line endings turned into '\n' the way the editor loads files. Qt also breaks
// lines at U+2029, so that becomes '\n' too.
static std::vector<TestFile> load_files(int folder_count, char **folders)
{
    std::vector<TestFile> files;
    for (int index = 0; index < folder_count; ++index) {
        QDirIterator iterator(QString::fromLocal8Bit(folders[index]), QDir::Files, QDirIterator::Subdirectories);
        while (iterator.hasNext()) {
            QFile file(iterator.next());
            if (!file.open(QIODevice::ReadOnly))
                continue;

            QString text = QString::fromUtf8(file.readAll());
            text.replace(QStringLiteral("\r\n"), QStringLiteral("\n"));
            text.replace(u'\r', u'\n');
            text.replace(QChar::ParagraphSeparator, u'\n');
            files.push_back({file.fileName(), text});
        }
    }

    return files;
}

static std::u16string_view view_of(const QString &text)
{
    return std::u16string_view((const char16_t *)text.utf16(), size_t(text.size()));
}

static Language language_of(const QString &path)
{
    QByteArray utf8 = path.toUtf8();
    return detect_language(std::string_view(utf8.constData(), size_t(utf8.size())));
}

static bool buffer_matches_document(const TextBuffer &text, QTextDocument &document)
{
    QString document_text = document.toRawText();
    document_text.replace(QChar::ParagraphSeparator, u'\n');
    return view_of(document_text) == std::u16string_view(text.units.data(), text.units.size());
}

// Checks the buffer against a fresh pass over its own text: where each line starts and the state each line ends in.
static bool buffer_is_consistent(const TextBuffer &text, std::vector<Token> &tokens)
{
    if (!lex_states_equal(text.lex_states[0], LexState{}) || text.lines[0].start != 0)
        return false;

    uint32_t line_count = 1;
    for (uint32_t at = 0; at < text.units.size(); ++at) {
        if (text.units[at] != u'\n')
            continue;

        if (line_count >= text.lines.size() || text.lines[line_count].start != at + 1)
            return false;
        line_count += 1;
    }

    if (line_count != text.lines.size())
        return false;

    Language language = text.language == Language::Plain ? Language::C : text.language;
    LexState state = {};
    for (uint32_t line = 0; line < text.lines.size(); ++line) {
        tokenize_line(line_text(text, line), language, state, tokens);
        if (!lex_states_equal(state, text.lex_states[text.lines[line].end_state]))
            return false;
    }

    return true;
}

//
// Random edits.
//

static uint32_t random_state;

static uint32_t next_random()
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}

static const char16_t *TYPED_TEXTS[] = {
    u"a", u"b", u"x", u" ", u"_", u"(", u")", u"{", u"}", u"\"", u"'", u"/", u"*", u"#", u"<", u">", u"\t",
    u"\u00e9", u"\u0301", u"\U0001F600", u"if", u"//", u"/*", u"*/", u"${",
};

static const char16_t *PASTED_TEXTS[] = {u"\n", u"\n    ", u"a\nb", u"/*\n*/", u"\"\n\"", u"x\n\ny\n", u"`\n`"};

static const int RANDOM_TEXT_COUNT = int(sizeof TYPED_TEXTS / sizeof TYPED_TEXTS[0]);
static const int PASTED_TEXT_COUNT = int(sizeof PASTED_TEXTS / sizeof PASTED_TEXTS[0]);

// The caret and selection both sides edit at, with the QTextCursor that edits the document.
struct EditSession {
    TextBuffer text;
    QTextDocument document;
    QTextCursor cursor;
    uint32_t anchor, caret;
    std::vector<uint64_t> history;    // the hash of the text at each point of the undo history
};

static uint64_t hash_text(const TextBuffer &text)
{
    uint64_t hash = 14695981039346656037ull;
    for (char16_t unit : text.units)
        hash = (hash ^ unit) * 1099511628211ull;
    return hash;
}

static uint32_t selection_start(const EditSession &session)
{
    return session.anchor < session.caret ? session.anchor : session.caret;
}

static uint32_t selection_length(const EditSession &session)
{
    return session.anchor < session.caret ? session.caret - session.anchor : session.anchor - session.caret;
}

static void select_in_document(EditSession &session, uint32_t anchor, uint32_t caret)
{
    session.cursor.setPosition(int(anchor));
    session.cursor.setPosition(int(caret), QTextCursor::KeepAnchor);
}

static void collapse_selection(EditSession &session, uint32_t at)
{
    session.anchor = session.caret = at;
}

// Typing replaces the selection. QTextCursor::insertText makes that, or any insertion with a line break, one undo
// step, and leaves a plain insertion on its own so it can merge with the typing before it.
static void insert_at_selection(EditSession &session, const QString &inserted)
{
    uint32_t start = selection_start(session);
    uint32_t length = selection_length(session);
    bool grouped = length > 0 || inserted.contains(u'\n');

    select_in_document(session, session.anchor, session.caret);
    session.cursor.insertText(inserted);

    if (grouped)
        begin_undo_group(session.text, NO_POSITION);
    replace_text(session.text, start, length, view_of(inserted));
    if (grouped)
        end_undo_group(session.text);

    collapse_selection(session, start + uint32_t(inserted.size()));
}

// Pasting replaces the selection the way the editor does it: insertText in an edit block that starts at the caret.
static void paste_at_selection(EditSession &session, const QString &pasted)
{
    uint32_t start = selection_start(session);

    select_in_document(session, session.anchor, session.caret);
    session.cursor.beginEditBlock();
    session.cursor.insertText(pasted);
    session.cursor.endEditBlock();

    begin_undo_group(session.text, session.caret);
    replace_text(session.text, start, selection_length(session), view_of(pasted));
    end_undo_group(session.text);

    collapse_selection(session, start + uint32_t(pasted.size()));
}

// Enter without a typing rule replaces the selection with a line break through QTextCursor::insertBlock, which stores
// it in Qt's string differently from insertText, in a way no undo rule can tell apart.
static void insert_line_break(EditSession &session)
{
    uint32_t start = selection_start(session);

    select_in_document(session, session.anchor, session.caret);
    session.cursor.insertBlock();

    begin_undo_group(session.text, NO_POSITION);
    replace_text(session.text, start, selection_length(session), u"\n");
    end_undo_group(session.text);

    collapse_selection(session, start + 1);
}

// QTextCursor::removeSelectedText makes the removal one undo step.
static void remove_selection(EditSession &session)
{
    uint32_t start = selection_start(session);

    select_in_document(session, session.anchor, session.caret);
    session.cursor.removeSelectedText();

    begin_undo_group(session.text, NO_POSITION);
    replace_text(session.text, start, selection_length(session), {});
    end_undo_group(session.text);

    collapse_selection(session, start);
}

// Backspace and Delete through QTextCursor::deletePreviousChar and deleteChar. Qt decides how much they remove: one
// code point, a whole character, or a whole emoji sequence. The buffer removes the same units as one change.
static void delete_character(EditSession &session, bool backward)
{
    uint32_t old_size = uint32_t(session.text.units.size());

    select_in_document(session, session.caret, session.caret);
    if (backward)
        session.cursor.deletePreviousChar();
    else
        session.cursor.deleteChar();

    uint32_t start = uint32_t(session.cursor.position());
    uint32_t length = old_size - uint32_t(session.document.characterCount() - 1);
    if (length)
        replace_text(session.text, start, length, {});

    collapse_selection(session, start);
}

// A random offset in the text that isn't between the halves of a surrogate pair, where the editor never puts the caret.
static uint32_t random_offset(const EditSession &session)
{
    uint32_t size = uint32_t(session.text.units.size());
    uint32_t at = next_random() % (size + 1);
    if (at > 0 && at < size && QChar::isLowSurrogate(session.text.units[at]))
        at -= 1;

    return at;
}

// Changes made together in one undo group starting at the caret, like the editor's typing rules and comment toggle.
static void edit_in_group(EditSession &session)
{
    QTextCursor group_cursor(&session.document);
    group_cursor.setPosition(int(session.caret));
    group_cursor.beginEditBlock();
    begin_undo_group(session.text, session.caret);

    uint32_t change_count = 1 + next_random() % 3;
    for (uint32_t change = 0; change < change_count; ++change) {
        uint32_t start = random_offset(session);
        uint32_t end = random_offset(session);
        if (end < start || end - start > 3)
            end = start;
        uint32_t length = end - start;

        QString inserted = next_random() % 3 ? QString::fromUtf16(TYPED_TEXTS[next_random() % RANDOM_TEXT_COUNT]) : QString();

        QTextCursor change_cursor(&session.document);
        change_cursor.setPosition(int(start));
        change_cursor.setPosition(int(start + length), QTextCursor::KeepAnchor);
        if (inserted.isEmpty())
            change_cursor.removeSelectedText();
        else
            change_cursor.insertText(inserted);

        replace_text(session.text, start, length, view_of(inserted));
    }

    group_cursor.endEditBlock();
    end_undo_group(session.text);

    collapse_selection(session, random_offset(session));
}

// Moves the caret, sometimes selecting up to 40 units around it, and rarely anything up to the whole text.
static void move_caret(EditSession &session)
{
    uint32_t caret = random_offset(session);
    uint32_t anchor = caret;

    uint32_t roll = next_random() % 100;
    if (roll < 1) {
        anchor = random_offset(session);
    } else if (roll < 30) {
        uint32_t size = uint32_t(session.text.units.size());
        uint32_t reach = next_random() % 40;
        anchor = next_random() % 2 ? (caret + reach < size ? caret + reach : size) : (caret > reach ? caret - reach : 0);
        if (anchor > 0 && anchor < size && QChar::isLowSurrogate(session.text.units[anchor]))
            anchor -= 1;
    }

    session.anchor = anchor;
    session.caret = caret;
}

struct EditReport {
    uint64_t steps;
    uint64_t undo_steps;
    uint64_t text_differences;      // an edit left the buffer's text different from the document's
    uint64_t undo_differences;      // undo or redo brought back text the history didn't have there
    uint64_t modified_differences;  // the buffer counted as modified, or not, against its history
    uint64_t inconsistent;          // the buffer's own lines or lexer states were wrong, which is a bug in it
    uint64_t checked_lines;
    int printed;
};

static void report_difference(EditReport &report, const TestFile &file, uint64_t step, const char *operation, const char *what)
{
    if (report.printed >= 12)
        return;

    printf("  %s, step %llu after %s: %s\n", file.path.toUtf8().constData(), (unsigned long long)step, operation, what);
    report.printed += 1;
}

// Both start over with this text and an empty undo history. QTextDocument::setPlainText leaves the document counted
// as modified, and QPlainTextEdit then marks it unmodified, so this does too.
static void start_session(EditSession &session, const QString &units, Language language)
{
    session.document.setPlainText(units);
    session.document.setModified(false);
    set_text(session.text, view_of(units), language);
    session.history.assign(1, hash_text(session.text));
    collapse_selection(session, 0);
}

static void run_random_edits(const TestFile &file, uint32_t seed, uint32_t step_count, EditReport &report)
{
    EditSession *session = new EditSession;
    session->cursor = QTextCursor(&session->document);
    start_session(*session, file.text, language_of(file.path));

    std::vector<Token> tokens;
    random_state = seed;

    for (uint64_t step = 0; step < step_count; ++step) {
        const char *operation = "";
        bool undid_or_redid = false;

        uint32_t roll = next_random() % 100;
        if (roll < 34) {
            operation = "typing";
            insert_at_selection(*session, QString::fromUtf16(TYPED_TEXTS[next_random() % RANDOM_TEXT_COUNT]));
        } else if (roll < 37) {
            operation = "inserting lines";
            insert_at_selection(*session, QString::fromUtf16(PASTED_TEXTS[next_random() % PASTED_TEXT_COUNT]));
        } else if (roll < 40) {
            operation = "pasting";
            const char16_t *pasted = next_random() % 2 ? PASTED_TEXTS[next_random() % PASTED_TEXT_COUNT] :
                                                         TYPED_TEXTS[next_random() % RANDOM_TEXT_COUNT];
            paste_at_selection(*session, QString::fromUtf16(pasted));
        } else if (roll < 42) {
            operation = "enter";
            insert_line_break(*session);
        } else if (roll < 50) {
            operation = "backspace";
            if (selection_length(*session))
                remove_selection(*session);
            else
                delete_character(*session, true);
        } else if (roll < 55) {
            operation = "delete";
            if (selection_length(*session))
                remove_selection(*session);
            else
                delete_character(*session, false);
        } else if (roll < 61) {
            operation = "group";
            edit_in_group(*session);
        } else if (roll < 76) {
            operation = "move";
            move_caret(*session);
        } else if (roll < 94) {
            bool undo = roll < 87;
            operation = undo ? "undo" : "redo";
            undid_or_redid = true;

            uint32_t caret = undo ? undo_text_change(session->text) : redo_text_change(session->text);
            if (caret != NO_POSITION && hash_text(session->text) != session->history[session->text.undo_position]) {
                report.undo_differences += 1;
                report_difference(report, file, step, operation, "the text isn't what the history had there");
            }
            if (caret > session->text.units.size())
                caret = session->caret > session->text.units.size() ? uint32_t(session->text.units.size()) : session->caret;

            QString units = QString::fromUtf16(session->text.units.data(), qsizetype(session->text.units.size()));
            session->document.setPlainText(units);
            collapse_selection(*session, caret);
            report.undo_steps += 1;
        } else {
            operation = "save";
            session->document.setModified(false);
            mark_text_saved(session->text);
        }

        report.steps += 1;
        bool same_text = buffer_matches_document(session->text, session->document);
        if (!same_text) {
            report.text_differences += 1;
            report_difference(report, file, step, operation, "the text differs");
        }

        // An edit makes the history's present point what the text is now, and drops what could have been redone along
        // with the buffer's records of it. Moves and saves leave both as they were.
        if (!undid_or_redid) {
            session->history.resize(session->text.undo_records.size() + 1);
            session->history[session->text.undo_position] = hash_text(session->text);
        }

        if (session->text.modified != (session->text.undo_position != session->text.saved_undo_position)) {
            report.modified_differences += 1;
            report_difference(report, file, step, operation, "it counts as modified against its history");
        }

        report.checked_lines += session->text.lines.size();
        if (!buffer_is_consistent(session->text, tokens)) {
            report.inconsistent += 1;
            report_difference(report, file, step, operation, "the buffer's lines or lexer states are wrong");
        }

        // After a difference, both start over from Qt's text, so one difference doesn't make every later step differ.
        if (!same_text) {
            QString document_text = session->document.toRawText();
            document_text.replace(QChar::ParagraphSeparator, u'\n');
            start_session(*session, document_text, session->text.language);
        }
    }

    delete session;
}

static int run_check(int folder_count, char **folders)
{
    std::vector<TestFile> files = load_files(folder_count, folders);
    EditReport report = {};

    for (size_t index = 0; index < files.size(); ++index)
        run_random_edits(files[index], 1234567u + uint32_t(index) * 7919u, 3000, report);

    printf("%zu files, %llu steps, %llu of them undo or redo\n", files.size(), (unsigned long long)report.steps,
           (unsigned long long)report.undo_steps);
    printf("text different from QTextDocument's: %llu, undo or redo to the wrong text: %llu, modified wrongly: %llu\n",
           (unsigned long long)report.text_differences, (unsigned long long)report.undo_differences,
           (unsigned long long)report.modified_differences);
    printf("lines checked against a fresh lexer pass: %llu, wrong: %llu steps\n", (unsigned long long)report.checked_lines,
           (unsigned long long)report.inconsistent);
    return report.inconsistent || report.undo_differences || report.modified_differences ? 1 : 0;
}

//
// Measurements.
//

static double private_megabytes()
{
    PROCESS_MEMORY_COUNTERS_EX counters = {};
    GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&counters, sizeof counters);
    return double(counters.PrivateUsage) / 1e6;
}

static int run_bench(int folder_count, char **folders)
{
    std::vector<TestFile> files = load_files(folder_count, folders);

    // One large text: the files over and over, until it has 100,000 lines.
    QString big;
    while (big.count(u'\n') < 100000) {
        for (const TestFile &file : files)
            big += file.text + u'\n';
    }
    big.squeeze();
    uint32_t line_count = uint32_t(big.count(u'\n') + 1);
    printf("text: %u lines, %.1f MB of UTF-16\n", line_count, double(big.size()) * 2 / 1e6);

    QElapsedTimer timer;
    double before = private_megabytes();
    timer.start();
    TextBuffer *text = new TextBuffer;
    set_text(*text, view_of(big), Language::Cpp);
    double load_ms = double(timer.nsecsElapsed()) / 1e6;
    double buffer_megabytes = private_megabytes() - before;

    printf("TextBuffer: loads and lexes in %.1f ms, %.1f MB private\n", load_ms, buffer_megabytes);
    printf("  units %.1f MB, lines %.1f MB, %zu distinct lexer states %.2f MB\n",
           double(text->units.capacity()) * 2 / 1e6, double(text->lines.capacity()) * sizeof(TextLine) / 1e6, text->lex_states.size(),
           double(text->lex_states.capacity()) * sizeof(LexState) / 1e6);

    before = private_megabytes();
    timer.restart();
    QTextDocument *document = new QTextDocument;
    document->setPlainText(big);
    printf("QTextDocument, text only with no layout or highlighting: loads in %.1f ms, %.1f MB private\n",
           double(timer.nsecsElapsed()) / 1e6, private_megabytes() - before);
    delete document;

    // Typing in the middle: each key moves the half of the text after it and the line starts after it.
    uint32_t middle = text->lines[line_count / 2].start;
    const int KEY_COUNT = 2000;
    timer.restart();
    for (int key = 0; key < KEY_COUNT; ++key)
        replace_text(*text, middle + uint32_t(key), 0, u"x");
    double typing_us = double(timer.nsecsElapsed()) / 1e3 / KEY_COUNT;

    timer.restart();
    for (int key = 0; key < KEY_COUNT; ++key)
        replace_text(*text, middle + uint32_t(KEY_COUNT - key - 1), 1, {});
    double backspace_us = double(timer.nsecsElapsed()) / 1e3 / KEY_COUNT;
    printf("typing in the middle: %.1f us a key, backspace %.1f us a key\n", typing_us, backspace_us);

    // No change can cost more lexing than every line, as when a comment opened on the first line never closes.
    timer.restart();
    set_text_language(*text, Language::Cpp);
    printf("lexing every line again, the most a change can need: %.1f ms\n", double(timer.nsecsElapsed()) / 1e6);

    delete text;
    return 0;
}

int main(int argument_count, char **arguments)
{
    QGuiApplication application(argument_count, arguments);
    if (argument_count >= 3 && !strcmp(arguments[1], "check"))
        return run_check(argument_count - 2, arguments + 2);
    if (argument_count >= 3 && !strcmp(arguments[1], "bench"))
        return run_bench(argument_count - 2, arguments + 2);

    printf("usage: text_test check|bench <folder>...\n");
    return 2;
}
