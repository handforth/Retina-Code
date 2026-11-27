#pragma once

#include "../Lexer.hpp"
#include "LSPProcess.hpp"

namespace lsp {

enum class InstallKind { None, Brew, Rust, Python, Npm, Go, Roswell, DotNet };

struct Tool {
    const char *executable;
    const char *argument;
    const char *package;
    InstallKind install;
    const char *secondArgument = nullptr;
};

struct ToolPaths {
    std::string home;
    std::string managed;
};

const Tool *ToolForLanguage(Language language);
std::string_view LanguageID(Language language, char (&lowercase)[64]);
std::string ProjectRoot(std::string_view file, Language language);
bool HasRustProject(std::string_view file);
std::string FileURI(std::string_view path, bool directory);
std::string CanonicalURIPath(std::string_view uri);

Environment LanguageEnvironment(const ToolPaths &paths, Language language = Language::Plain);
void ConfigureToolEnvironment(Environment &environment, const ToolPaths &paths, const Tool *tool, std::string_view executable);
std::string FindExecutable(const ToolPaths &paths, const Tool *tool, Language language, std::string_view root);
bool HasOwnedTools(const ToolPaths &paths, const Tool *tool);
std::string RemoveOwnedTools(const ToolPaths &paths, const Tool *tool);
std::string InstallTool(const ToolPaths &paths, const Tool &tool, Language language, std::string_view root,
                        const std::atomic_bool &cancelled, Progress progress);

} // namespace lsp