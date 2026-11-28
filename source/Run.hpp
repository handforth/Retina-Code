#pragma once

// Running a file: the project it belongs to, the tools that build and run it, and what they write, as lines with
// colors and links. A run is a RunJob. run_job() takes it from start to end on a thread of its own, step by step the
// way a person would: find the tools, write the tab's draft to a file, build, run what the build made.
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

// One line of output, or the start of one that the next message goes on with. Its text and the link's file are byte
// ranges in RunLog::text, and its colors are RunLog::spans[spans_start, spans_start + span_count), whose ranges count
// UTF-16 units of the text.
struct RunMessage {
    uint32_t text_start, text_length;
    uint32_t spans_start, span_count;
    uint32_t link_start, link_length;      // the UTF-16 units of the text the link covers; no link when link_length is 0
    uint32_t file_start, file_length;      // the file the link opens, empty for the file that ran
    uint32_t line, column;                 // where the link goes, from 1; column 0 is the line's start
    RunColumns columns;
    OutputTone tone;
    bool colored;                          // the program gave it colors, so its tone doesn't color it
    bool current_source;                   // the link goes to the file that ran, which is the tab
};

// The lines a job wrote that the frontend hasn't taken yet.
struct RunLog {
    std::string text;
    std::vector<OutputColorSpan> spans;
    std::vector<RunMessage> messages;
    bool discarded;                        // older lines were dropped before the frontend took them

    // The job as it was when the frontend took the log.
    bool input_open;                       // the program runs and reads its input
    bool finished;                         // run_job() has returned, and these are the last lines
};

// What run_child() runs, and what becomes of what it writes.
enum RunChildKind : uint8_t {
    CHILD_TOOL,       // a build step, whose lines show
    CHILD_PROGRAM,    // the program that ran, whose input is open while it runs
    CHILD_CAPTURE,    // its standard output goes to RunJob::capture, and its errors show
    CHILD_QUIET,      // its standard output goes to RunJob::capture, and nothing shows
};

struct RunChild {
    std::string_view program;
    std::string_view arguments;    // each one followed by a NUL
    std::string_view folder;
    std::string_view input;        // written to its input, which then closes; for children that aren't the program
    RunChildKind kind;
};

// What run_child() returns for a program that crashed, and for one that couldn't start.
static const int CHILD_CRASHED = -2;
static const int CHILD_NOT_STARTED = -1;

struct RunStream {
    RunRecords records;
    TerminalDecoder decoder;
    bool continued;                // the last message didn't end its line
};

struct RunJob {
    // What to run, which the frontend sets before run_job().
    Language language;
    std::string file;              // the tab's file, or empty for text never saved
    std::string name;              // the tab's name, which lines about the file show instead of its path
    std::string draft;             // the tab's text when it isn't saved
    bool has_draft;
    std::string workspace;         // the folder the window has open, or empty
    void *frontend;                // the frontend's, for notify_run_output()

    // Shared with the frontend's thread, under mutex.
    std::mutex mutex;
    RunLog log;
    std::string typed;             // what the frontend sent the program that run_child() hasn't written yet
    bool end_of_input;             // the program's input closes once typed is written
    bool input_open;               // the program runs and reads its input
    bool finished;                 // run_job() returned
    bool notified;                 // notify_run_output() was called, and the frontend hasn't taken the log since
    std::atomic_bool stop;

    // The job's own while it runs.
    RunChildKind child_kind;       // of the child running now
    std::string temporary;         // a folder for what builds make, removed when the job ends
    std::string snapshot;          // the draft written next to the file, removed when the job ends
    std::string input_path;        // the file the tools read: the tab's file, or the draft's
    std::string environment;       // every child's, as NAME=value entries each followed by a NUL; empty to inherit
    std::string extra_path;        // folders added to PATH for every child, for tools found outside it
    std::string capture;           // the standard output of a CHILD_CAPTURE or CHILD_QUIET child
    RunStream streams[2];          // standard output, then standard error
    DecodedOutput decoded;         // scratch for a line's text and colors
    std::string line;              // scratch for a line rewritten as a diagnostic

    // How lines are read for diagnostics, which a recipe sets before each child.
    bool diagnostics;              // lines that name a place in a file link to it
    bool runtime_locations;        // Python and JavaScript traceback lines link too
    bool rust_json;                // rustc writes its diagnostics as JSON lines on standard error
    bool cargo_json;               // cargo writes JSON records on standard output until its build finishes
    bool cargo_built;
    bool announce_program;         // a script says "Running..." as it starts
    bool build_error;              // a diagnostic error with a place showed
    bool msvc;                     // cl's diagnostics, which come in the console's code page
    RunColumns columns;
    CompilerFormat format;
    std::string diagnostic_folder; // where relative paths in diagnostics start
    std::string manifest_folder;   // a Cargo manifest's folder, for paths relative to the package
    int exit_code;                 // the program's, or -1
};

// Runs the job from start to end. The frontend makes the job with new RunJob() and sets its inputs first.
void run_job(RunJob &job);

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
int run_child(RunJob &job, const RunChild &child);

// The frontend's: called from the job's thread when the log gets lines and job.notified was false.
void notify_run_output(RunJob &job);
