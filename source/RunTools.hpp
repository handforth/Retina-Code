#pragma once

#include "Lexer.hpp"

struct RunTool {
    const char *tool = nullptr;
    const char *suffix = nullptr;
    const char *check = nullptr;
};

inline RunTool ToolForRun(Language language)
{
    switch (language) {
    case Language::C: return {"clang", ".c", "clang"};
    case Language::Cpp: return {"clang++", ".cpp", "clang++"};
    case Language::Python: return {"python3", ".py", "python3"};
    case Language::Rust: return {"rustc", ".rs"};
    case Language::JavaScript: return {"node", ".js", "node"};
    case Language::TypeScript: return {"node", ".ts"};
    case Language::JSX: return {"tsx", ".jsx"};
    case Language::TSX: return {"tsx", ".tsx"};
    case Language::ObjectiveC: return {"clang", ".m", "clang"};
    case Language::ObjectiveCpp: return {"clang++", ".mm", "clang++"};
    case Language::CSharp: return {"dotnet", ".cs"};
    case Language::Java: return {"java", ".java"};
    case Language::Kotlin: return {"kotlinc", ".kt"};
    case Language::Swift: return {"swiftc", ".swift", "swiftc"};
    case Language::Go: return {"go", ".go", "gofmt"};
    case Language::Zig: return {"zig", ".zig", "zig"};
    case Language::Dart: return {"dart", ".dart"};
    case Language::Ruby: return {"ruby", ".rb", "ruby"};
    case Language::PHP: return {"php", ".php", "php"};
    case Language::Perl: return {"perl", ".pl"};
    case Language::Lua: return {"lua", ".lua", "luac"};
    case Language::Luau: return {"luau", ".luau"};
    case Language::Bash: return {"bash", ".sh", "bash"};
    case Language::Zsh: return {"zsh", ".zsh", "zsh"};
    case Language::Fish: return {"fish", ".fish", "fish"};
    case Language::PowerShell: return {"pwsh", ".ps1"};
    case Language::R: return {"Rscript", ".R"};
    case Language::Julia: return {"julia", ".jl"};
    case Language::Scala: return {"scala", ".scala"};
    case Language::Groovy: return {"groovy", ".groovy"};
    case Language::Haskell: return {"runghc", ".hs"};
    case Language::FSharp: return {"dotnet", ".fsx"};
    case Language::Elixir: return {"elixir", ".exs"};
    case Language::Clojure: return {"clojure", ".clj"};
    case Language::VisualBasic: return {"dotnet"};
    case Language::Assembly: return {"clang", ".s"};
    case Language::Odin: return {"odin", ".odin", "odin"};
    case Language::CommonLisp: return {"sbcl", ".lisp"};
    default: return {};
    }
}

// Fixed flag lists precede the file path in both runners.
struct RunFlags {
    const char *values[3]{};
    unsigned count = 0;
};
inline RunFlags ScriptRunFlags(Language language)
{
    switch (language) {
    case Language::Python: return {{"-B", "-u"}, 2};
    case Language::Zig: case Language::Dart: return {{"run"}, 1};
    case Language::Kotlin: return {{"-script"}, 1};
    case Language::FSharp: return {{"fsi", "--exec"}, 2};
    case Language::PowerShell: return {{"-NoLogo", "-NoProfile", "-File"}, 3};
    case Language::R: return {{"--no-save", "--no-restore"}, 2};
    case Language::Clojure: return {{"-M"}, 1};
    case Language::CommonLisp: return {{"--script"}, 1};
    default: return {};
    }
}
