#pragma once

// Running a file: the project it belongs to, the tools that build and run it, and what they write, as lines with
// colors and links. A job does one of three things, each on a thread of its own and step by step the way a person
// would: run_job() builds and runs a file, check_job() looks for errors in the text being edited without running
// it, and debug_build_job() builds a file for the debugger.
//
// The frontend supplies two functions. run_child() runs one program to its end, and while it runs, hands what the
// program writes to child_output(). notify_run_output() tells the frontend's thread that the job's log has lines.

#include "Lexer.hpp"
#include "RunText.hpp"

#include <atomic>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

// How a link's column counts: characters, UTF-8 bytes, or UTF-16 units.
enum RunColumns : uint8_t { RUN_COLUMN_CHARACTERS, RUN_COLUMN_BYTES, RUN_COLUMN_UTF16 };

// One line of output, or the start of one that the next line goes on with. Its text, the link's file, a diagnostic's
// own words and its label are byte ranges in RunLog::text. Its colors are RunLog::spans[spans_start, spans_start +
// span_count), whose ranges count UTF-16 units of the text.
struct RunLine {
    uint32_t text_start, text_length;
    uint32_t spans_start, span_count;
    uint32_t link_start, link_length;      // the UTF-16 units of the text the link covers; no link when link_length is 0
    uint32_t file_start, file_length;      // the file the link opens, empty for the file that ran
    uint32_t diagnostic_start, diagnostic_length;    // what a diagnostic says, without its place
    uint32_t label_start, label_length;    // the diagnostic's code, as in "clang(-Wunused-variable)"
    uint32_t line, column;                 // where the link goes, from 1; column 0 is the line's start
    uint32_t first_column, end_column;     // the range the diagnostic marks on that line, when it names one
    RunColumns columns;
    OutputTone tone;
    bool colored;                          // the program gave it colors, so its tone doesn't color it
    bool current_source;                   // the link goes to the file that ran, which is the tab
};

// The lines a job wrote that the frontend hasn't taken yet.
struct RunLog {
    std::string text;
    std::vector<OutputColorSpan> spans;
    std::vector<RunLine> messages;
    bool discarded;                        // older lines were dropped before the frontend took them

    // The job as it was when the frontend took the log.
    bool input_open;                       // the program runs and reads its input
    bool finished;                         // the job has returned, and these are its last lines
};

// What run_child() runs, and what becomes of what it writes.
enum RunChildKind : uint8_t {
    CHILD_TOOL,       // a build step, whose lines show
    CHILD_PROGRAM,    // the program that ran, whose input is open while it runs
    CHILD_CAPTURE,    // its standard output goes to RunJob::capture, and its errors show
    CHILD_QUIET,      // its standard output goes to RunJob::capture, and nothing shows
};

struct ChildCommand {
    std::string_view program;
    std::string_view arguments;    // each one followed by a NUL
    std::string_view folder;
    std::string_view input;        // written to its input, which then closes; for children that aren't the program
    RunChildKind kind;
};

// What run_child() returns for a program that crashed, and for one that couldn't start.
static const int CHILD_CRASHED = -2;
static const int CHILD_NOT_STARTED = -1;

// What a file belongs to, which decides how it builds and runs.
enum ProjectKind : uint8_t {
    PROJECT_SOURCE, PROJECT_SCRIPT, PROJECT_NATIVE, PROJECT_CARGO, PROJECT_GO_MODULE, PROJECT_SWIFT_PACKAGE, PROJECT_DOT_NET,
    PROJECT_ODIN_PACKAGE,
};

struct Project {
    ProjectKind kind;
    std::string folder;
    std::string manifest;
};

// How the debugger runs what debug_build_job() made.
enum DebugAdapter : uint8_t { DEBUG_LLDB, DEBUG_SBCL, DEBUG_PYTHON };

// A file open in the editor whose text a check reads instead of the file's.
struct CheckDraft {
    std::string file;
    std::string text;
    bool saved;                    // the text is what the file holds
};

struct RunStream {
    RunRecords records;
    TerminalDecoder decoder;
    bool continued;                // the last line didn't end
};

struct RunJob {
    // What to do, which the frontend sets before the job starts.
    Language language;
    std::string file;              // the tab's file, or empty for text never saved
    std::string name;              // the tab's name, which lines about the file show instead of its path
    std::string draft;             // the tab's text when it isn't saved
    bool has_draft;
    std::string workspace;         // the folder the window has open, or empty
    std::vector<CheckDraft> drafts;    // for check_job(): the open files' texts, the tab's first
    std::string cache;             // for check_job(): a folder kept between Rust checks, so cargo builds less
    void *frontend;                // the frontend's, for notify_run_output()

    // Shared with the frontend's thread, under mutex.
    std::mutex mutex;
    RunLog log;
    std::string typed;             // what the frontend sent the program that run_child() hasn't written yet
    bool end_of_input;             // the program's input closes once typed is written
    bool input_open;               // the program runs and reads its input
    bool finished;                 // the job returned
    bool notified;                 // notify_run_output() was called, and the frontend hasn't taken the log since
    std::atomic_bool stop;

    // What check_job() found, and what debug_build_job() made. The debugger owns the temporary folder then.
    uint32_t errors, warnings;
    std::string debug_program;
    std::string debug_folder;
    std::string debug_interpreter;
    DebugAdapter debug_adapter;

    // The job's own while it runs.
    RunChildKind child_kind;       // of the child running now
    std::string temporary;         // a folder for what builds make, removed when the job ends
    std::string snapshot;          // the draft written next to the file, removed when the job ends
    std::string input_path;        // the file the tools read: the tab's file, or the draft's
    std::string environment;       // every child's, as NAME=value entries each followed by a NUL; empty to inherit
    std::string extra_path;        // folders added to PATH for every child, for tools found outside it
    std::string capture;           // the standard output of a CHILD_CAPTURE or CHILD_QUIET child
    std::string errors_capture;    // a child's standard error, instead of showing it, when capture_errors is set
    RunStream streams[2];          // standard output, then standard error
    DecodedOutput decoded;         // scratch for a line's text and colors
    std::string line;              // scratch for a line rewritten as a diagnostic
    std::string diagnostic;        // scratch for what the diagnostic says
    std::string label;             // scratch for its code
    std::vector<uint64_t> seen;    // the diagnostics a check showed, sorted, so each shows once
    std::vector<std::string> artifacts;    // the executables a debug build of a Cargo project made

    // How lines are read, which a recipe sets before each child.
    bool checking;                 // only diagnostics show, each once, and they're counted
    bool located_only;             // a check shows only diagnostics that name a place
    bool capture_errors;
    bool diagnostics;              // lines that name a place in a file link to it
    bool runtime_locations;        // Python and JavaScript traceback lines link too
    bool rust_json;                // rustc writes its diagnostics as JSON lines on standard error
    bool cargo_json;               // cargo writes JSON records on standard output until its build finishes
    bool cargo_built;
    bool collect_artifacts;        // a debug build keeps the executables cargo names
    bool tests_only;               // of those, only tests
    bool announce_program;         // a script says "Running..." as it starts
    bool build_error;              // a diagnostic error with a place showed
    bool msvc;                     // cl's diagnostics, which come in the console's code page
    bool keep_temporary;           // the temporary folder outlives the job
    RunColumns columns;
    CompilerFormat format;
    std::string diagnostic_folder; // where relative paths in diagnostics start
    std::string manifest_folder;   // a Cargo manifest's folder, for paths relative to the package
    std::string mirror;            // a check's copy of the project, whose paths stand for the project's own
    int exit_code;                 // the program's, or -1
};

// The three jobs. The frontend makes the job with new RunJob() and sets what to do first.
void run_job(RunJob &job);
void check_job(RunJob &job);
void debug_build_job(RunJob &job);

// The project a file belongs to, looking up from its folder to the workspace's, or the whole way up without one.
Project locate_project(Language language, const std::string &file, std::string workspace);

bool runnable_language(Language language);
bool checkable_language(Language language);
bool debuggable_language(Language language, std::string_view file);

// Where a tool is: on PATH, or in the folders its language installs to. A tool found outside PATH adds its folder to
// extra_path, when there is one, for the job's children.
std::string find_tool(std::string_view name, Language language, std::string *extra_path);

// A file with a name in a folder or a folder above it, up to limit or the root.
std::string find_parent_file(std::string_view folder, std::string_view limit, std::string_view name);

// For run_child(): the child started; what it wrote on a stream (0 for standard output, 1 for errors); and a moment
// with nothing written, when a prompt without a line break shows.
void child_started(RunJob &job);
void child_output(RunJob &job, int stream, std::string_view bytes);
void child_idle(RunJob &job);

// For run_child(): what the frontend sent the program since the last call, and whether its input should close then.
bool take_child_input(RunJob &job, std::string &bytes, bool &close);

// A line from the job itself, as when a tool can't start.
void log_status(RunJob &job, std::string_view text, OutputTone tone);

// Moves the job's lines into into, which must be empty, and leaves its buffers with the job for the next lines.
void take_run_log(RunJob &job, RunLog &into);

// The frontend's: runs a child to its end and returns its exit code, CHILD_CRASHED, or CHILD_NOT_STARTED after
// logging why. It stops the child, and everything the child started, as soon as job.stop is set.
int run_child(RunJob &job, const ChildCommand &child);

// The frontend's: called from the job's thread when the log gets lines and job.notified was false.
void notify_run_output(RunJob &job);
