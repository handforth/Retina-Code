// Lexer test tool. tests/build.bat builds it twice: against the current tree (lexer_test.exe) and against the
// reference commit (lexer_reference.exe). Comparing their dumps proves a lexer change kept every token and state.
//
//   lexer_test dump <output> <folder>...    every token and state for the files in the folders, plus fuzz input
//   lexer_test compare <reference> <current>
//   lexer_test bench <folder>...            time and heap allocations
//   lexer_test profile <folder>...          samples where the time goes, by function and source line
//
// The hand-written samples in tests/lexer/samples cover every language's edge cases. Any folder of real source
// files makes a good second corpus.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dbghelp.h>

#include "Languages.cpp"
#include "Lexer.cpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#pragma comment(lib, "dbghelp.lib")

//
// Heap counting. Every operator new in the process goes through here.
//

static long long heap_allocations;
static long long heap_bytes_allocated;
static long long heap_bytes_live;

void *operator new(size_t size)
{
    // The size sits in front of the block so delete can take it off the live total.
    size_t *block = (size_t *)malloc(size + 16);
    block[0] = size;

    heap_allocations += 1;
    heap_bytes_allocated += size;
    heap_bytes_live += size;
    return (char *)block + 16;
}

void operator delete(void *memory) noexcept
{
    if (!memory)
        return;

    size_t *block = (size_t *)((char *)memory - 16);
    heap_bytes_live -= block[0];
    free(block);
}

void operator delete(void *memory, size_t) noexcept { operator delete(memory); }
void *operator new[](size_t size) { return operator new(size); }
void operator delete[](void *memory) noexcept { operator delete(memory); }
void operator delete[](void *memory, size_t) noexcept { operator delete(memory); }

struct Document {
    std::string path;
    Language language;
    std::vector<std::u16string> lines;
};

static double seconds_now()
{
    LARGE_INTEGER counter, frequency;
    QueryPerformanceCounter(&counter);
    QueryPerformanceFrequency(&frequency);
    return double(counter.QuadPart) / double(frequency.QuadPart);
}

//
// Loading files.
//

static void decode_utf8_lines(const std::string &bytes, std::vector<std::u16string> &lines)
{
    std::u16string line;
    size_t at = 0;

    // Skip a byte order mark.
    if (bytes.size() >= 3 && (unsigned char)bytes[0] == 0xEF && (unsigned char)bytes[1] == 0xBB && (unsigned char)bytes[2] == 0xBF)
        at = 3;

    while (at < bytes.size()) {
        unsigned char lead = (unsigned char)bytes[at];
        uint32_t code = 0xFFFD;
        size_t width = 1;

        if (lead < 0x80) {
            code = lead;
        } else if ((lead & 0xE0) == 0xC0 && at + 1 < bytes.size()) {
            code = ((lead & 0x1F) << 6) | (bytes[at + 1] & 0x3F);
            width = 2;
        } else if ((lead & 0xF0) == 0xE0 && at + 2 < bytes.size()) {
            code = ((lead & 0x0F) << 12) | ((bytes[at + 1] & 0x3F) << 6) | (bytes[at + 2] & 0x3F);
            width = 3;
        } else if ((lead & 0xF8) == 0xF0 && at + 3 < bytes.size()) {
            code = ((lead & 0x07) << 18) | ((bytes[at + 1] & 0x3F) << 12) | ((bytes[at + 2] & 0x3F) << 6) | (bytes[at + 3] & 0x3F);
            width = 4;
        }
        at += width;

        if (code == '\n') {
            if (!line.empty() && line.back() == u'\r')
                line.pop_back();
            lines.push_back(line);
            line.clear();
        } else if (code >= 0x10000) {
            code -= 0x10000;
            line.push_back(char16_t(0xD800 + (code >> 10)));
            line.push_back(char16_t(0xDC00 + (code & 0x3FF)));
        } else {
            line.push_back(char16_t(code));
        }
    }

    if (!line.empty() && line.back() == u'\r')
        line.pop_back();
    lines.push_back(line);
}

static int compare_names(const void *a, const void *b)
{
    return strcmp(((const std::string *)a)->c_str(), ((const std::string *)b)->c_str());
}

static void load_folder(const std::string &folder, std::vector<Document> &documents)
{
    WIN32_FIND_DATAA found;
    HANDLE search = FindFirstFileA((folder + "\\*").c_str(), &found);
    if (search == INVALID_HANDLE_VALUE)
        return;

    std::vector<std::string> names;
    do {
        if (strcmp(found.cFileName, ".") && strcmp(found.cFileName, ".."))
            names.push_back(found.cFileName);
    } while (FindNextFileA(search, &found));
    FindClose(search);

    // Sorted, so every run reads the files in the same order.
    qsort(names.data(), names.size(), sizeof(std::string), compare_names);

    for (const std::string &name : names) {
        std::string path = folder + "\\" + name;
        if (GetFileAttributesA(path.c_str()) & FILE_ATTRIBUTE_DIRECTORY) {
            load_folder(path, documents);
            continue;
        }

        FILE *file = fopen(path.c_str(), "rb");
        if (!file)
            continue;

        std::string bytes;
        char buffer[65536];
        size_t count;
        while ((count = fread(buffer, 1, sizeof buffer, file)) > 0)
            bytes.append(buffer, count);
        fclose(file);

        if (bytes.find('\0') != std::string::npos)
            continue;

        // Detection sees forward slashes and the first 512 bytes, like the editors.
        std::string slashed = path;
        for (char &ch : slashed) {
            if (ch == '\\')
                ch = '/';
        }

        Document document;
        document.path = slashed;
        document.language = detect_language(slashed, std::string_view(bytes).substr(0, 512));
        decode_utf8_lines(bytes, document.lines);
        documents.push_back(document);
    }
}

//
// Fuzz documents: random runs of the characters and pieces that change lexer state.
//

static uint32_t fuzz_seed = 12345;

static uint32_t fuzz_next()
{
    fuzz_seed ^= fuzz_seed << 13;
    fuzz_seed ^= fuzz_seed >> 17;
    fuzz_seed ^= fuzz_seed << 5;
    return fuzz_seed;
}

static const char *FUZZ_PIECES[] = {
    "\"", "'", "`", "\\", "/", "*", "#", "$", "{", "}", "(", ")", "[", "]", "<", ">", "=", ":", ";", ",", ".", "|",
    "!", "@", "%", "^", "&", "-", "+", "?", "~", " ", " ", " ", "\t", "a", "b", "x", "T", "Foo", "foo", "bar", "0x1F",
    "12", "3.5e-3", "r#\"", "\"#", "\"\"\"", "'''", "${", "#{", "\\(", "<<EOF", "<<-END", "<<~SQL", "<<<EOT", "EOF",
    "END", "-->", "<!--", "<script>", "</script>", "<style>", "</style>", "--[[", "--[==[", "]]", "]==]", "#|", "|#",
    "{-", "-}", "(*", "*)", "/*", "*/", "//", "--", ";", "R\"x(", ")x\"", "@\"", "$\"", "$@\"", "f\"", "s\"", "<?php",
    "?>", "<?=", "---", "...", "```", "```rust", "~~~", "::", "->", "=>", "template", "typename", "fn", "impl", "struct",
    "class", "let", "mut", "const", "#[", "#![", "cfg_attr", "derive", "'a", "<T>", "<T,", "extends", "return", "def",
    "function", "%w(", "%q{", "~s(", "@{", "$$", "$tag$", "&amp;", "<div", "</div>", "/>", "<>", "</>", "#define",
    "#include", "<x.h>", "#if", "#region", "#macro", "|2-", "&anchor", "*ref", "!!str", "=begin", "=end", "=pod",
    "=cut", "#+sbcl", "#'", "#\\", "#x1F", "#36rZZ", "|sym|", ":key", "@Override", "__init__", "self", "nil",
};

static void add_fuzz_documents(std::vector<Document> &documents)
{
    const uint32_t piece_count = sizeof FUZZ_PIECES / sizeof FUZZ_PIECES[0];

    for (int language = 1; language < int(Language::Count); ++language) {
        for (int round = 0; round < 3; ++round) {
            Document document;
            document.path = "fuzz/" + std::to_string(language) + "_" + std::to_string(round);
            document.language = Language(language);

            for (int line_index = 0; line_index < 250; ++line_index) {
                std::string line;
                uint32_t pieces = fuzz_next() % 24;
                for (uint32_t piece = 0; piece < pieces; ++piece)
                    line += FUZZ_PIECES[fuzz_next() % piece_count];

                document.lines.push_back(std::u16string(line.begin(), line.end()));
            }

            documents.push_back(document);
        }
    }
}

//
// Dumps.
//

static void dump_view(FILE *out, std::u16string_view text)
{
    for (char16_t ch : text)
        fputc(ch < 128 ? char(ch) : '?', out);
}

static void dump_tokens(FILE *out, const std::vector<Token> &tokens)
{
    for (const Token &token : tokens)
        fprintf(out, " %u,%u,%u%s", token.start, unsigned(token.length), unsigned(token.ink), token.non_code ? "n" : "");
}

static void dump_language_tables(FILE *out)
{
    for (int index = 0; index < int(Language::Count); ++index) {
        const LanguageInfo &info = language_info(Language(index));
        fprintf(out, "language %d %s [%.*s] ignore_case=%d comments=", index, info.name, int(info.extensions.size()),
                info.extensions.data(), info.ignore_case);
        dump_view(out, info.comments.line);
        fputc('|', out);
        dump_view(out, info.comments.open);
        fputc('|', out);
        dump_view(out, info.comments.close);

        fprintf(out, " nested=%d\n words:", info.comments.nested);
        std::u16string_view lists[] = {info.keywords, info.control, info.types, info.constants};
        for (std::u16string_view list : lists) {
            fputc(' ', out);
            dump_view(out, list);
            fputc('|', out);
        }

        fprintf(out, "\n completion:");
        for (std::u16string_view word : completion_words(Language(index))) {
            fputc(' ', out);
            dump_view(out, word);
        }
        fputc('\n', out);
    }

    static const char16_t *FENCES[] = {
        u"c", u"C++", u"cpp", u"csharp", u"C#", u"objc", u"Objective-C", u"objective-c++", u"objcpp", u"javascript",
        u"js", u"typescript", u"ts", u"tsx", u"python", u"Python3", u"py", u"rust", u"rs", u"shell", u"sh", u"console",
        u"bash", u"zsh", u"kotlin", u"kt", u"haskell", u"fsharp", u"F#", u"powershell", u"pwsh", u"ps1", u"ruby", u"rb",
        u"perl", u"julia", u"elixir", u"clojure", u"common-lisp", u"lisp", u"cl", u"gamemaker", u"gml", u"make",
        u"makefile", u"html", u"xml", u"json", u"yaml", u"md", u"markdown", u"\u00e9", u"", u"unknown",
    };
    for (const char16_t *fence : FENCES) {
        fprintf(out, "fence ");
        dump_view(out, fence);
        fprintf(out, " -> %d\n", int(language_for_fence(fence)));
    }

    static const char *PATHS[] = {
        "a/Makefile", "a/GNUmakefile", "a/CMakeLists.txt", "a/Dockerfile", "a/Dockerfile.dev", "a/Containerfile",
        "a/Gemfile", "a/Rakefile", "a/.bashrc", "a/configure", "a/.zshrc", "a/.Rprofile", "a/README", "a/CHANGELOG",
        "a/.editorconfig", "a/.env", "a/.env.local", "a/tsconfig.json", "x/.vscode/settings.json", "x/settings.json",
        "a/go.mod", "a/go.work", "a/build.zig.zon", "a/main.C", "a/main.M", "a/x.c", "a/x.H", "a/x.gml", "a/script",
        "a/notes.txt", "a/data.unknown", "a/x.PY", "a/thing.Jsx", "a/q.SQL", "a/README.md",
    };
    static const char *BEGINNINGS[] = {
        "", "#!/usr/bin/env python3\n", "#!/bin/sh\n", "#!/usr/bin/env -S node --flag\n", "#!/usr/bin/env -u X ruby\n",
        "<?xml version=\"1.0\"?>", "<?php echo 1;", "<?= $x ?>", "  \n<gml:Point/>", "#!/usr/local/bin/pwsh",
        "#!/usr/bin/env sbcl --script", "#! /usr/bin/perl -w", "#!/usr/bin/luajit", "#!/usr/bin/env luau",
    };
    for (const char *path : PATHS) {
        for (const char *beginning : BEGINNINGS)
            fprintf(out, "detect %s | %s -> %d\n", path, beginning, int(detect_language(path, beginning)));
    }
}

static void dump_documents(FILE *out, const std::vector<Document> &documents)
{
    std::vector<Token> tokens;
    LexState empty_state;

    for (const Document &document : documents) {
        fprintf(out, "== %s language=%d\n", document.path.c_str(), int(document.language));

        LexState state;
        for (size_t line_index = 0; line_index < document.lines.size(); ++line_index) {
            const std::u16string &line = document.lines[line_index];

            // The half-line pass is what typing uses for context at a caret partway through a line.
            LexState prefix_state = state;
            tokenize_line(std::u16string_view(line).substr(0, line.size() / 2), document.language, prefix_state, tokens, false);
            fprintf(out, "%zu p m%d c%d:", line_index + 1, int(prefix_state.mode),
                    int(language_in_context(document.language, prefix_state)));
            dump_tokens(out, tokens);
            fputc('\n', out);

            LexState before = state;
            tokenize_line(line, document.language, state, tokens, true);
            fprintf(out, "%zu m%d c%d s%d%d:", line_index + 1, int(state.mode), int(language_in_context(document.language, state)),
                    lex_states_equal(before, state), lex_states_equal(empty_state, state));
            dump_tokens(out, tokens);
            fputc('\n', out);
        }
    }
}

// Reads a whole text file into lines, for comparing dumps.
static std::vector<std::string> read_lines(const char *path)
{
    std::vector<std::string> lines;
    FILE *file = fopen(path, "rb");
    if (!file)
        return lines;

    std::string line;
    int ch;
    while ((ch = fgetc(file)) != EOF) {
        if (ch == '\n') {
            lines.push_back(line);
            line.clear();
        } else {
            line += char(ch);
        }
    }
    lines.push_back(line);
    fclose(file);
    return lines;
}

static int compare_dumps(const char *reference_path, const char *current_path)
{
    std::vector<std::string> reference = read_lines(reference_path);
    std::vector<std::string> current = read_lines(current_path);
    if (reference.size() != current.size())
        printf("line counts differ: reference %zu, current %zu\n", reference.size(), current.size());

    size_t count = reference.size() < current.size() ? reference.size() : current.size();
    size_t differences = 0;
    std::string document;
    for (size_t index = 0; index < count; ++index) {
        if (reference[index].starts_with("== "))
            document = reference[index];

        if (reference[index] == current[index])
            continue;

        differences += 1;
        if (differences <= 12) {
            printf("line %zu in %s\n  reference: %.240s\n  current:   %.240s\n", index + 1, document.c_str(),
                   reference[index].c_str(), current[index].c_str());
        }
    }

    printf("compared %zu lines, %zu differences\n", count, differences);
    return differences || reference.size() != current.size() ? 1 : 0;
}

//
// Benchmarks.
//

static void run_benchmarks(const std::vector<Document> &documents)
{
    size_t total_lines = 0, total_units = 0;
    for (const Document &document : documents) {
        total_lines += document.lines.size();
        for (const std::u16string &line : document.lines)
            total_units += line.size();
    }
    printf("corpus: %zu documents, %zu lines, %.1f MB of UTF-16\n", documents.size(), total_lines, total_units * 2 / 1e6);
    printf("sizeof(LexState) = %zu, sizeof(Token) = %zu\n", sizeof(LexState), sizeof(Token));

    std::vector<Token> tokens;
    tokens.reserve(4096);

    // The first line of a language builds its keyword tables.
    long long allocations = heap_allocations, live = heap_bytes_live;
    double start = seconds_now();
    for (int language = 0; language < int(Language::Count); ++language) {
        LexState state;
        tokenize_line(u"warm up words", Language(language), state, tokens, true);
    }
    printf("keyword tables, all languages: %.3f ms, %lld allocations, %.1f KB kept\n", (seconds_now() - start) * 1e3,
           heap_allocations - allocations, (heap_bytes_live - live) / 1e3);

    const int repeats = 5;

    // The lexer alone: one state carried through each document.
    double best = 1e9;
    allocations = heap_allocations;
    for (int repeat = 0; repeat < repeats; ++repeat) {
        start = seconds_now();
        for (const Document &document : documents) {
            LexState state;
            for (const std::u16string &line : document.lines)
                tokenize_line(line, document.language, state, tokens, true);
        }

        double elapsed = seconds_now() - start;
        if (elapsed < best)
            best = elapsed;
    }
    printf("lexer only: best %.1f ms  %.1f ns/line  %.0f MB/s  %.1f allocations/pass\n", best * 1e3,
           best * 1e9 / total_lines, total_units * 2 / best / 1e6, double(heap_allocations - allocations) / repeats);

    // The editors' pattern: each line keeps an index into a table of distinct states. Lexing a line copies its
    // incoming state, and the result is matched against the line's old state, the default state, the previous
    // line's state, and the 16 most recently added states before it's added.
    best = 1e9;
    allocations = heap_allocations;
    size_t distinct_states = 0;
    for (int repeat = 0; repeat < repeats; ++repeat) {
        start = seconds_now();
        distinct_states = 0;

        for (const Document &document : documents) {
            std::vector<uint32_t> line_state_index(document.lines.size() + 1, 0);
            std::vector<LexState> unique_states(1);
            uint32_t recent[16] = {};
            uint32_t next_recent = 0;

            for (int pass = 0; pass < 2; ++pass) {
                for (size_t line_index = 0; line_index < document.lines.size(); ++line_index) {
                    LexState state = unique_states[line_state_index[line_index]];
                    tokenize_line(document.lines[line_index], document.language, state, tokens, true);

                    uint32_t old_index = line_state_index[line_index + 1];
                    uint32_t found = UINT32_MAX;
                    if (lex_states_equal(state, unique_states[old_index]))
                        found = old_index;
                    else if (lex_states_equal(state, unique_states[0]))
                        found = 0;
                    else if (lex_states_equal(state, unique_states[line_state_index[line_index]]))
                        found = line_state_index[line_index];

                    for (int slot = 0; found == UINT32_MAX && slot < 16; ++slot) {
                        if (recent[slot] && lex_states_equal(state, unique_states[recent[slot]]))
                            found = recent[slot];
                    }

                    if (found == UINT32_MAX) {
                        found = uint32_t(unique_states.size());
                        unique_states.push_back(state);
                        recent[next_recent++ % 16] = found;
                    }
                    line_state_index[line_index + 1] = found;
                }
            }

            distinct_states += unique_states.size();
        }

        double elapsed = seconds_now() - start;
        if (elapsed < best)
            best = elapsed;
    }
    printf("editor pattern: best %.1f ms  %.1f ns/line  %.1f allocations/pass  %zu distinct states\n", best * 1e3,
           best * 1e9 / (2 * total_lines), double(heap_allocations - allocations) / repeats, distinct_states);
}

//
// Sampling profiler: a second thread stops the lexing thread every 50 microseconds and records where it was.
//

static HANDLE profiled_thread;
static volatile bool profiling;
static DWORD64 *samples;
static size_t sample_count;
static const size_t SAMPLE_LIMIT = 4 << 20;

static DWORD WINAPI sample_thread(void *)
{
    LARGE_INTEGER frequency, now, next;
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&next);

    while (profiling && sample_count < SAMPLE_LIMIT) {
        next.QuadPart += frequency.QuadPart / 20000;
        do {
            QueryPerformanceCounter(&now);
        } while (now.QuadPart < next.QuadPart);

        SuspendThread(profiled_thread);
        CONTEXT context = {};
        context.ContextFlags = CONTEXT_CONTROL;
        if (GetThreadContext(profiled_thread, &context))
            samples[sample_count++] = context.Rip;
        ResumeThread(profiled_thread);
    }

    return 0;
}

struct ProfileBucket {
    std::string name;
    size_t count;
};

static void count_sample(std::vector<ProfileBucket> &buckets, const std::string &name)
{
    for (ProfileBucket &bucket : buckets) {
        if (bucket.name == name) {
            bucket.count += 1;
            return;
        }
    }

    buckets.push_back({name, 1});
}

static int compare_buckets(const void *a, const void *b)
{
    size_t left = ((const ProfileBucket *)a)->count, right = ((const ProfileBucket *)b)->count;
    return left < right ? 1 : left > right ? -1 : 0;
}

static void print_buckets(std::vector<ProfileBucket> &buckets, const char *title, size_t limit)
{
    qsort(buckets.data(), buckets.size(), sizeof(ProfileBucket), compare_buckets);
    printf("\n%s:\n", title);
    for (size_t index = 0; index < buckets.size() && index < limit; ++index)
        printf("  %5.1f%%  %s\n", 100.0 * buckets[index].count / sample_count, buckets[index].name.c_str());
}

static void run_profile(const std::vector<Document> &documents)
{
    samples = (DWORD64 *)malloc(SAMPLE_LIMIT * sizeof(DWORD64));
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &profiled_thread, 0, FALSE, DUPLICATE_SAME_ACCESS);

    std::vector<Token> tokens;
    profiling = true;
    HANDLE sampler = CreateThread(nullptr, 0, sample_thread, nullptr, 0, nullptr);
    for (int repeat = 0; repeat < 10; ++repeat) {
        for (const Document &document : documents) {
            LexState state;
            for (const std::u16string &line : document.lines)
                tokenize_line(line, document.language, state, tokens, true);
        }
    }
    profiling = false;
    WaitForSingleObject(sampler, INFINITE);

    HANDLE process = GetCurrentProcess();
    SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_DEFERRED_LOADS);
    SymInitialize(process, nullptr, TRUE);

    std::vector<ProfileBucket> functions, lines;
    for (size_t index = 0; index < sample_count; ++index) {
        char buffer[sizeof(SYMBOL_INFO) + 256] = {};
        SYMBOL_INFO *symbol = (SYMBOL_INFO *)buffer;
        symbol->SizeOfStruct = sizeof(SYMBOL_INFO);
        symbol->MaxNameLen = 255;
        DWORD64 displacement = 0;
        std::string function = SymFromAddr(process, samples[index], &displacement, symbol) ? symbol->Name : "?";

        IMAGEHLP_LINE64 line = {};
        line.SizeOfStruct = sizeof line;
        DWORD line_displacement = 0;
        std::string where = function;
        if (SymGetLineFromAddr64(process, samples[index], &line_displacement, &line)) {
            const char *file = strrchr(line.FileName, '\\');
            where = std::string(file ? file + 1 : line.FileName) + ":" + std::to_string(line.LineNumber) + " " + function;
        }

        count_sample(functions, function);
        count_sample(lines, where);
    }

    printf("%zu samples\n", sample_count);
    print_buckets(functions, "by function", 25);
    print_buckets(lines, "by line", 45);
}

int main(int argument_count, char **arguments)
{
    if (argument_count >= 4 && !strcmp(arguments[1], "compare"))
        return compare_dumps(arguments[2], arguments[3]);

    if (argument_count < 3) {
        printf("usage: lexer_test dump <output> <folder>... | compare <reference> <current> | bench <folder>... | profile <folder>...\n");
        return 2;
    }

    bool dump = !strcmp(arguments[1], "dump");
    std::vector<Document> documents;
    for (int index = dump ? 3 : 2; index < argument_count; ++index)
        load_folder(arguments[index], documents);

    if (dump) {
        add_fuzz_documents(documents);
        FILE *out = fopen(arguments[2], "wb");
        dump_language_tables(out);
        dump_documents(out, documents);
        fclose(out);
        printf("dumped %zu documents\n", documents.size());
    } else if (!strcmp(arguments[1], "profile")) {
        run_profile(documents);
    } else {
        run_benchmarks(documents);
    }

    return 0;
}
