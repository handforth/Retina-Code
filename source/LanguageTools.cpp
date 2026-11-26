#include "LanguageTools.hpp"
#include "ChildProcess.hpp"
#include "LSPJson.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdlib>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <limits.h>
#include <mutex>
#include <span>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace lsp {
namespace fs = std::filesystem;
using namespace std::chrono_literals;

const Tool *ToolForLanguage(Language language)
{
    static constexpr Tool clangd{"clangd", "-j=2", "llvm", InstallKind::Brew};
    static constexpr Tool rust{"rust-analyzer", nullptr, "rust-analyzer", InstallKind::Rust};
    static constexpr Tool python{"pylsp", nullptr, "python-lsp-server[pyflakes,autopep8]", InstallKind::Python};
    static constexpr Tool typescript{"typescript-language-server", "--stdio", "typescript-language-server", InstallKind::Npm};
    static constexpr Tool go{"gopls", nullptr, "golang.org/x/tools/gopls@latest", InstallKind::Go};
    static constexpr Tool swift{"sourcekit-lsp", nullptr, nullptr, InstallKind::None};
    static constexpr Tool lua{"lua-language-server", nullptr, "lua-language-server", InstallKind::Brew};
    static constexpr Tool zig{"zls", nullptr, "zls", InstallKind::Brew};
    static constexpr Tool odin{"ols", nullptr, nullptr, InstallKind::None};
    static constexpr Tool bash{"bash-language-server", "start", "bash-language-server", InstallKind::Npm};
    static constexpr Tool json{"vscode-json-language-server", "--stdio", "vscode-langservers-extracted", InstallKind::Npm};
    static constexpr Tool html{"vscode-html-language-server", "--stdio", "vscode-langservers-extracted", InstallKind::Npm};
    static constexpr Tool css{"vscode-css-language-server", "--stdio", "vscode-langservers-extracted", InstallKind::Npm};
    static constexpr Tool yaml{"yaml-language-server", "--stdio", "yaml-language-server", InstallKind::Npm};
    static constexpr Tool lisp{"alive-lsp", nullptr, "nobody-famous/alive-lsp", InstallKind::Roswell};
    static constexpr Tool clojure{"clojure-lsp", nullptr, "clojure-lsp/brew/clojure-lsp-native", InstallKind::Brew};
    static constexpr Tool ruby{"ruby-lsp", nullptr, nullptr, InstallKind::None};
    static constexpr Tool php{"phpactor", "language-server", nullptr, InstallKind::None};
    static constexpr Tool csharp{"csharp-ls", nullptr, "csharp-ls", InstallKind::DotNet};
    static constexpr Tool fsharp{"fsautocomplete", nullptr, "fsautocomplete", InstallKind::DotNet};
    static constexpr Tool java{"jdtls", nullptr, "jdtls", InstallKind::Brew};
    static constexpr Tool dart{"dart", "language-server", nullptr, InstallKind::None, "--protocol=lsp"};
    static constexpr Tool haskell{"haskell-language-server-wrapper", "--lsp", "haskell-language-server", InstallKind::Brew};
    static constexpr Tool cmake{"cmake-language-server", nullptr, "cmake-language-server", InstallKind::Python};
    static constexpr Tool docker{"docker-langserver", "--stdio", "dockerfile-language-server-nodejs", InstallKind::Npm};
    static constexpr Tool toml{"taplo", "lsp", "taplo", InstallKind::Brew, "stdio"};
    if (CFamily(language))
        return &clangd;
    switch (language) {
    case Language::Rust: return &rust;
    case Language::Python: return &python;
    case Language::JavaScript: case Language::JSX: case Language::TypeScript: case Language::TSX: return &typescript;
    case Language::Go: return &go;
    case Language::Swift: return &swift;
    case Language::Lua: return &lua;
    case Language::Zig: return &zig;
    case Language::Odin: return &odin;
    case Language::Bash: return &bash;
    case Language::JSON: case Language::JSONC: return &json;
    case Language::HTML: return &html;
    case Language::CSS: case Language::SCSS: case Language::Less: return &css;
    case Language::YAML: return &yaml;
    case Language::CommonLisp: return &lisp;
    case Language::Clojure: return &clojure;
    case Language::Ruby: return &ruby;
    case Language::PHP: return &php;
    case Language::CSharp: return &csharp;
    case Language::FSharp: return &fsharp;
    case Language::Java: return &java;
    case Language::Dart: return &dart;
    case Language::Haskell: return &haskell;
    case Language::CMake: return &cmake;
    case Language::Dockerfile: return &docker;
    case Language::TOML: return &toml;
    default: return nullptr;
    }
}

std::string_view LanguageID(Language language, char (&lowercase)[64])
{
    switch (language) {
    case Language::Plain: return "plaintext";
    case Language::Cpp: return "cpp";
    case Language::ObjectiveC: return "objective-c";
    case Language::ObjectiveCpp: return "objective-cpp";
    case Language::JSX: return "javascriptreact";
    case Language::TSX: return "typescriptreact";
    case Language::CSharp: return "csharp";
    case Language::FSharp: return "fsharp";
    case Language::Bash: case Language::Zsh: return "shellscript";
    case Language::CommonLisp: return "lisp";
    default: break;
    }
    std::string_view name = InfoForLanguage(language).name;
    if (name.size() > sizeof(lowercase))
        return name;
    std::ranges::transform(name, lowercase, [](char ch) {
        return ch >= 'A' && ch <= 'Z' ? char(ch + 'a' - 'A') : ch;
    });
    return {lowercase, name.size()};
}

static constexpr const char *rustMarkers[]{"Cargo.toml", "rust-project.json", ".rust-project.json"};

static std::span<const char *const> ProjectMarkers(Language language)
{
    static constexpr const char *clang[]{"compile_commands.json", "compile_flags.txt", ".clangd", "CMakeLists.txt"};
    static constexpr const char *go[]{"go.work", "go.mod"};
    static constexpr const char *swift[]{"Package.swift"};
    static constexpr const char *python[]{"pyproject.toml", "setup.py", "requirements.txt"};
    static constexpr const char *js[]{"tsconfig.json", "jsconfig.json", "package.json"};
    static constexpr const char *lua[]{".luarc.json", ".luarc.jsonc"};
    static constexpr const char *zig[]{"build.zig"};
    static constexpr const char *odin[]{"ols.json"};
    static constexpr const char *clojure[]{"deps.edn", "project.clj", "bb.edn", "shadow-cljs.edn"};
    static constexpr const char *ruby[]{"Gemfile", ".ruby-version"};
    static constexpr const char *php[]{"composer.json", ".phpactor.json", ".phpactor.yml"};
    static constexpr const char *dotnet[]{"global.json", "Directory.Build.props"};
    static constexpr const char *java[]{"pom.xml", "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts"};
    static constexpr const char *dart[]{"pubspec.yaml"};
    static constexpr const char *haskell[]{"hie.yaml", "cabal.project", "stack.yaml"};
    static constexpr const char *cmake[]{"CMakeLists.txt"};
    if (CFamily(language))
        return clang;
    if (JavaScriptFamily(language))
        return js;
    switch (language) {
    case Language::Rust: return rustMarkers;
    case Language::Go: return go;
    case Language::Swift: return swift;
    case Language::Python: return python;
    case Language::Lua: return lua;
    case Language::Zig: return zig;
    case Language::Odin: return odin;
    case Language::Clojure: return clojure;
    case Language::Ruby: return ruby;
    case Language::PHP: return php;
    case Language::CSharp: case Language::FSharp: return dotnet;
    case Language::Java: return java;
    case Language::Dart: return dart;
    case Language::Haskell: return haskell;
    case Language::CMake: return cmake;
    default: return {};
    }
}

static bool Exists(const fs::path &path)
{
    struct stat info;
    return stat(path.c_str(), &info) == 0;
}

static std::string_view ProjectFileSuffix(Language language)
{
    switch (language) {
    case Language::CommonLisp: return ".asd";
    case Language::CSharp: return ".csproj";
    case Language::FSharp: return ".fsproj";
    case Language::Haskell: return ".cabal";
    default: return {};
    }
}

static bool HasProjectFile(const fs::path &directory, std::string_view suffix)
{
    DIR *entries = opendir(directory.c_str());
    if (!entries)
        return false;

    bool found = false;
    while (auto *entry = readdir(entries)) {
        if (!std::string_view(entry->d_name).ends_with(suffix))
            continue;

        struct stat info;
        if (entry->d_type == DT_REG || (stat((directory / entry->d_name).c_str(), &info) == 0 && S_ISREG(info.st_mode))) {
            found = true;
            break;
        }
    }

    closedir(entries);
    return found;
}

std::string ProjectRoot(std::string_view file, Language language)
{
    fs::path directory = fs::path(file).parent_path();
    auto markers = ProjectMarkers(language);
    auto suffix = ProjectFileSuffix(language);
    for (auto parent = directory; parent.has_relative_path(); parent = parent.parent_path()) {
        for (const char *marker : markers) {
            if (Exists(parent / marker))
                return parent.string();
        }
        if (Exists(parent / ".git"))
            return parent.string();

        if (!suffix.empty() && HasProjectFile(parent, suffix))
            return parent.string();
    }
    return directory.string();
}

bool HasRustProject(std::string_view file)
{
    for (auto parent = fs::path(file).parent_path(); parent.has_relative_path(); parent = parent.parent_path()) {
        for (const char *marker : rustMarkers) {
            struct stat info;
            if (stat((parent / marker).c_str(), &info) == 0 && S_ISREG(info.st_mode))
                return true;
        }
    }
    return false;
}

std::string FileURI(std::string_view path, bool directory)
{
    constexpr char digits[] = "0123456789ABCDEF";
    std::string url = "file://";
    url.reserve(url.size() + path.size() + 1);
    for (unsigned char ch : path) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || JsonDigit(ch) || ch == '/' || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
            url += char(ch);
        } else {
            url += '%';
            url += digits[ch >> 4];
            url += digits[ch & 15];
        }
    }
    if (directory && !path.ends_with('/'))
        url += '/';
    return url;
}

std::string CanonicalURIPath(std::string_view uri)
{
    if (!uri.starts_with("file://"))
        return {};
    uri.remove_prefix(7);
    if (uri.starts_with("localhost/"))
        uri.remove_prefix(9);
    if (!uri.starts_with('/'))
        return {};
    std::string path;
    path.reserve(uri.size());
    for (size_t i = 0; i < uri.size(); ++i) {
        char ch = uri[i];
        if (ch == '%') {
            if (uri.size() - i < 3)
                return {};
            int high = HexDigit(uri[i + 1]), low = HexDigit(uri[i + 2]);
            if (high < 0 || low < 0 || (!high && !low))
                return {};
            ch = char(high * 16 + low);
            i += 2;
        }
        path += ch;
    }
    std::error_code error;
    auto canonical = fs::weakly_canonical(path, error);
    return error ? fs::path(path).lexically_normal().string() : canonical.string();
}

static std::string_view EnvironmentValue(const char *key)
{
    const char *value = getenv(key);
    return value ? std::string_view(value) : std::string_view{};
}

static void AddToolBin(std::string &path, std::string_view folder)
{
    if (!folder.starts_with('/') || PathHasFolder(path, folder))
        return;
    if (!path.empty())
        path += ':';

    path += folder;
}

Environment LanguageEnvironment(const ToolPaths &paths, Language language)
{
    auto environment = ReadEnvironment();
    std::string path;
    for (auto bins : {EnvironmentValue("PATH"), systemToolPath}) {
        while (!bins.empty())
            AddToolBin(path, NextPathFolder(bins));
    }

    AddToolBin(path, "/usr/local/go/bin");
    AddToolBin(path, paths.home + "/.cargo/bin");
    AddToolBin(path, paths.home + "/go/bin");
    if (language == Language::Odin) {
        AddToolBin(path, EnvironmentValue("ODIN_ROOT"));
        AddToolBin(path, paths.home + "/opt/odin");
    }

    SetEnvironment(environment, "PATH", path);
    return environment;
}

static std::string Executable(std::string path)
{
    return IsExecutable(path.c_str()) ? std::move(path) : std::string{};
}

static std::string FindTool(const ToolPaths &paths, std::string_view name, Language language)
{
    std::string file;
    if (ExecutableOnPath(file, EnvironmentValue("PATH"), name))
        return file;

    if (language == Language::CommonLisp && name == "alive-lsp") {
        if (ExecutableIn(file, EnvironmentValue("ROSWELL_HOME"), "bin/alive-lsp"))
            return file;

        file = paths.home + "/.roswell/bin/";
    } else if (language == Language::CSharp || language == Language::FSharp) {
        if (name == "dotnet")
            return Executable("/usr/local/share/dotnet/dotnet");

        file = paths.home + "/.dotnet/tools/";
    } else if (language == Language::Haskell) {
        if (ExecutableIn(file, paths.home + "/.ghcup/bin", name))
            return file;

        file = paths.home + "/.local/bin/";
    } else if (language == Language::Odin) {
        if (ExecutableIn(file, EnvironmentValue("ODIN_ROOT"), name))
            return file;
        file = paths.home + "/opt/odin/";
    } else if (language == Language::Rust)
        file = paths.home + "/.cargo/bin/";
    else if (language == Language::Go)
        file = "/usr/local/go/bin/";
    else
        return {};
    file += name;
    return Executable(std::move(file));
}

static std::string ManagedFolder(const ToolPaths &paths, const Tool &tool)
{
    return paths.managed + "/" + (tool.install == InstallKind::Npm ? tool.package : tool.executable);
}

static bool PrivateInstall(const Tool &tool)
{
    return tool.install == InstallKind::Python || tool.install == InstallKind::Npm || tool.install == InstallKind::Go ||
           tool.install == InstallKind::Roswell || tool.install == InstallKind::DotNet;
}

static bool HasPrivateInstall(const ToolPaths &paths, const Tool &tool)
{
    if (!PrivateInstall(tool))
        return false;
    auto folder = ManagedFolder(paths, tool);
    struct stat info;
    return lstat(folder.c_str(), &info) == 0 && S_ISDIR(info.st_mode) &&
           lstat((folder + "/.installed").c_str(), &info) == 0 && S_ISREG(info.st_mode);
}

static std::string PrivateExecutable(const ToolPaths &paths, const Tool &tool)
{
    return ManagedFolder(paths, tool) + (tool.install == InstallKind::Npm ? "/node_modules/.bin/" : "/bin/") + tool.executable;
}

static void UseDotNetRoot(Environment &environment, std::string_view root)
{
    SetEnvironment(environment, "DOTNET_ROOT", root);
    SetEnvironment(environment, "DOTNET_ROOT_ARM64", root);
    SetEnvironment(environment, "DOTNET_ROOT_X64", root);

    std::string path(root);
    std::string_view entries = environment;
    while (!entries.empty()) {
        auto entry = NextItem(entries);
        if (entry.starts_with("PATH=")) {
            path += ':';
            path += entry.substr(5);
            break;
        }
    }
    SetEnvironment(environment, "PATH", path);
}

void ConfigureToolEnvironment(Environment &environment, const ToolPaths &paths, const Tool *tool, std::string_view executable)
{
    if (tool && std::string_view(tool->executable) == "jdtls" && fs::path(executable).filename() == "jdtls") {
        RemoveEnvironment(environment, "CLIENT_HOST");
        RemoveEnvironment(environment, "CLIENT_PORT");
        RemoveEnvironment(environment, "CLIENT_PIPE");
    }

    if (tool && tool->install == InstallKind::Roswell && executable == PrivateExecutable(paths, *tool)) {
        auto folder = ManagedFolder(paths, *tool);
        SetEnvironment(environment, "ROSWELL_HOME", folder);
        SetEnvironment(environment, "XDG_CACHE_HOME", folder + "/cache");
    } else if (tool && tool->install == InstallKind::DotNet && executable == PrivateExecutable(paths, *tool)) {
        std::ifstream file(ManagedFolder(paths, *tool) + "/.dotnet-root");
        char root[PATH_MAX];
        if (file.getline(root, sizeof(root)) && root[0] == '/' && IsExecutable((std::string(root) + "/dotnet").c_str()))
            UseDotNetRoot(environment, root);
    }
}

std::string FindExecutable(const ToolPaths &paths, const Tool *tool, Language language, std::string_view root)
{
    if (!tool)
        return {};
    std::string_view name = tool->executable;
    if (HasPrivateInstall(paths, *tool)) {
        auto file = Executable(PrivateExecutable(paths, *tool));
        if (!file.empty())
            return file;
    }
    if (language == Language::Go) {
        auto directory = EnvironmentValue("GOBIN");
        if (!directory.empty()) {
            std::string file(directory);
            file += '/';
            file += name;
            file = Executable(std::move(file));
            if (!file.empty())
                return file;
        }
        auto file = Executable(paths.home + "/go/bin/gopls");
        if (!file.empty())
            return file;
    }
    auto installed = FindTool(paths, name, language);
    if (language == Language::Rust) {
        if (!installed.empty() && installed != paths.home + "/.cargo/bin/rust-analyzer")
            return installed;
        auto rustup = FindTool(paths, "rustup", language);
        if (!rustup.empty()) {
            auto environment = LanguageEnvironment(paths);
            SetEnvironment(environment, "RUSTUP_AUTO_INSTALL", "0");
            auto result = RunCommand(rustup, {"which", name}, root, environment, 8s);
            return result.succeeded ? Executable(std::move(result.output)) : std::string{};
        }
    }
    if (CFamily(language) || language == Language::Swift) {
        if (!installed.empty() && !installed.starts_with("/usr/bin/"))
            return installed;
        if (CFamily(language)) {
            for (const char *prefix : {"/opt/homebrew", "/usr/local"}) {
                auto file = Executable(std::string(prefix) + "/opt/llvm/bin/clangd");
                if (!file.empty())
                    return file;
            }
        }
        auto result = RunCommand("/usr/bin/xcrun", {"--find", name}, root, LanguageEnvironment(paths), 8s);
        return result.succeeded ? Executable(std::move(result.output)) : std::string{};
    }
    return installed;
}

static std::string Probe(std::string_view program, std::initializer_list<std::string_view> arguments,
                         std::string_view root, const Environment &environment)
{
    auto result = RunCommand(program, arguments, root, environment, 12s);
    return result.succeeded ? std::move(result.output) : std::string{};
}

static std::string BrewCellar(std::string_view program, std::string_view package, std::string_view root, const Environment &environment)
{
    auto slash = package.rfind('/');
    auto path = slash == package.npos ? Probe(program, {"--cellar", package}, root, environment) :
                                       Probe(program, {"--cellar"}, root, environment);
    if (!path.empty() && slash != package.npos)
        path += std::string(package.substr(slash));

    return path.starts_with('/') && path.find_first_of("\r\n") == path.npos ? std::move(path) : std::string{};
}

static std::string BrewReceipt(const std::string &cellar)
{
    if (cellar.empty())
        return {};
    std::error_code error;
    fs::path version;
    for (fs::directory_iterator entry(cellar, error), end; !error && entry != end; entry.increment(error)) {
        if (entry->path().filename().string().starts_with('.'))
            continue;
        if (!version.empty())
            return {};
        version = entry->path();
    }
    return version.empty() || error ? std::string{} : (version / "INSTALL_RECEIPT.json").string();
}

static std::string RustToolFile(std::string_view program, std::string_view toolchain, std::string_view root, const Environment &environment)
{
    fs::path rustc = Probe(program, {"which", "--toolchain", toolchain, "rustc"}, root, environment);
    return rustc.is_absolute() && rustc.filename() == "rustc" ? (rustc.parent_path() / "rust-analyzer").string() : std::string{};
}

static bool MissingPath(const std::string &path)
{
    struct stat info;
    return !path.empty() && lstat(path.c_str(), &info) != 0 && errno == ENOENT;
}

using Stamp = std::array<int64_t, 5>;

static std::optional<Stamp> FileStamp(const std::string &path)
{
    struct stat info;
    if (!path.starts_with('/') || stat(path.c_str(), &info) || !S_ISREG(info.st_mode))
        return {};
    return Stamp{int64_t(info.st_dev), int64_t(info.st_ino), int64_t(info.st_size),
                 int64_t(info.st_mtimespec.tv_sec), int64_t(info.st_mtimespec.tv_nsec)};
}

struct Receipt {
    std::string manager;
    std::string file;
    std::string toolchain;
    Stamp stamp;
};

static std::string PlistString(const void *value)
{
    if (!value || CFGetTypeID(value) != CFStringGetTypeID())
        return {};
    auto text = static_cast<CFStringRef>(value);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8);
    if (capacity < 0)
        return {};
    std::string result(size_t(capacity) + 1, '\0');
    if (!CFStringGetCString(text, result.data(), result.size(), kCFStringEncodingUTF8))
        return {};
    result.resize(std::char_traits<char>::length(result.c_str()));
    return result;
}

static std::vector<Receipt> ReadReceipts(const ToolPaths &paths, const Tool &tool)
{
    if (tool.install != InstallKind::Brew && tool.install != InstallKind::Rust)
        return {};
    std::ifstream file(ManagedFolder(paths, tool) + "/receipts.plist", std::ios::binary | std::ios::ate);
    auto length = file.tellg();
    if (length <= 0 || length > 64 * 1024)
        return {};
    std::string bytes(size_t(length), '\0');
    if (!file.seekg(0) || !file.read(bytes.data(), bytes.size()))
        return {};
    auto data = CFDataCreateWithBytesNoCopy(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()), bytes.size(), kCFAllocatorNull);
    auto plist = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr);
    CFRelease(data);
    std::vector<Receipt> receipts;
    if (plist && CFGetTypeID(plist) == CFArrayGetTypeID()) {
        auto list = static_cast<CFArrayRef>(plist);
        for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
            auto entry = CFArrayGetValueAtIndex(list, i);
            if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID())
                continue;
            auto fields = static_cast<CFDictionaryRef>(entry);
            Receipt receipt{PlistString(CFDictionaryGetValue(fields, CFSTR("manager"))),
                            PlistString(CFDictionaryGetValue(fields, CFSTR("file"))),
                            PlistString(CFDictionaryGetValue(fields, CFSTR("toolchain"))), {}};
            auto numbers = static_cast<CFArrayRef>(CFDictionaryGetValue(fields, CFSTR("stamp")));
            if (!numbers || CFGetTypeID(numbers) != CFArrayGetTypeID() || CFArrayGetCount(numbers) != CFIndex(receipt.stamp.size()))
                continue;
            bool valid = true;
            for (size_t item = 0; item < receipt.stamp.size(); ++item) {
                auto number = static_cast<CFNumberRef>(CFArrayGetValueAtIndex(numbers, item));
                if (!number || CFGetTypeID(number) != CFNumberGetTypeID() || !CFNumberGetValue(number, kCFNumberSInt64Type, &receipt.stamp[item]))
                    valid = false;
            }
            if (valid && !receipt.manager.empty() && FileStamp(receipt.file) == receipt.stamp)
                receipts.push_back(std::move(receipt));
        }
    }
    if (plist)
        CFRelease(plist);
    return receipts;
}

static bool WriteAtomic(const std::string &path, std::string_view bytes)
{
    std::string temporary = path + ".XXXXXX";
    int fd = mkstemp(temporary.data());
    if (fd < 0)
        return false;
    while (!bytes.empty()) {
        ssize_t count = write(fd, bytes.data(), bytes.size());
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            break;
        bytes.remove_prefix(size_t(count));
    }
    if (close(fd) == 0 && bytes.empty() && rename(temporary.c_str(), path.c_str()) == 0)
        return true;
    unlink(temporary.c_str());
    return false;
}

static bool InstallAliveLauncher(const std::string &executable)
{
    auto source = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("AliveLSP"), CFSTR("ros"), nullptr);
    if (!source)
        return false;

    char path[PATH_MAX];
    bool found = CFURLGetFileSystemRepresentation(source, true, reinterpret_cast<UInt8 *>(path), sizeof(path));
    CFRelease(source);
    if (!found)
        return false;

    std::ifstream input(path, std::ios::binary);
    std::string script((std::istreambuf_iterator<char>(input)), {});
    std::error_code error;
    fs::create_directories(fs::path(executable).parent_path(), error);
    return !error && !script.empty() && WriteAtomic(executable, script) && chmod(executable.c_str(), 0700) == 0;
}

static constexpr auto installTimeout = 600s;

struct RuntimePackage {
    std::string_view executable, formula, title;
};

static RuntimePackage InstallRuntime(InstallKind kind)
{
    switch (kind) {
    case InstallKind::Python: return {"python3", "python", "Python 3"};
    case InstallKind::Npm: return {"npm", "node", "Node.js"};
    case InstallKind::Go: return {"go", "go", "Go"};
    case InstallKind::Roswell: return {"ros", "roswell", "Roswell"};
    case InstallKind::DotNet: return {"dotnet", "dotnet@10", ".NET 10 SDK"};
    default: return {};
    }
}

static void SetBrewInstallOptions(Environment &environment)
{
    SetEnvironment(environment, "HOMEBREW_NO_AUTO_UPDATE", "1");
    SetEnvironment(environment, "HOMEBREW_CURL_RETRIES", "0");
}

static std::string DotNetSDKRoot(std::string_view program, const ToolPaths &paths, const Environment &environment,
                                const std::atomic_bool &cancelled)
{
    auto result = RunCommand(program, {"--list-sdks"}, paths.home, environment, 12s, &cancelled);
    if (!result.succeeded)
        return {};

    std::string_view lines = result.output;
    while (!lines.empty()) {
        size_t end = lines.find('\n');
        auto line = lines.substr(0, end);
        lines.remove_prefix(end == lines.npos ? lines.size() : end + 1);
        size_t start = line.find(" [");
        if (line.starts_with("10.") && start != line.npos && line.ends_with("/sdk]")) {
            auto root = line.substr(start + 2, line.size() - start - 7);
            if (root.starts_with('/') && IsExecutable((std::string(root) + "/dotnet").c_str()))
                return std::string(root);
        }
    }
    return {};
}

static std::string EnsureRuntime(const ToolPaths &paths, Language language, RuntimePackage package, Environment &environment,
                                 const std::atomic_bool &cancelled, Progress progress, std::string &program, std::string &dotnetRoot)
{
    // A second language can need the same runtime while Homebrew is installing it.
    static std::timed_mutex installing;
    std::unique_lock lock(installing, std::defer_lock);
    while (!cancelled.load() && !lock.try_lock_for(150ms)) {}
    if (cancelled.load())
        return "Installation cancelled.";

    bool dotnet = package.executable == "dotnet";
    auto resolveProgram = [&] {
        program = FindTool(paths, package.executable, language);
        if (package.executable == "npm" && FindTool(paths, "node", language).empty())
            program.clear();
        if (program == "/usr/bin/python3")
            program = Executable(Probe("/usr/bin/xcrun", {"--find", "python3"}, paths.home, environment));
    };
    resolveProgram();
    if (!program.empty()) {
        if (!dotnet)
            return {};

        dotnetRoot = DotNetSDKRoot(program, paths, environment, cancelled);
        if (!dotnetRoot.empty())
            return {};
    }

    if (cancelled.load())
        return "Installation cancelled.";

    auto brew = FindTool(paths, "brew", Language::Plain);
    if (brew.empty())
        return "Install Homebrew to set up " + std::string(package.title) + " automatically.";

    SetBrewInstallOptions(environment);
    auto findDotNet = [&] {
        // The versioned formula is keg-only. Use its SDK without changing Homebrew links.
        auto prefix = Probe(brew, {"--prefix", package.formula}, paths.home, environment);
        if (prefix.starts_with('/') && prefix.find_first_of("\r\n") == prefix.npos) {
            dotnetRoot = prefix + "/libexec";
            program = Executable(dotnetRoot + "/dotnet");
            return !program.empty();
        }
        return false;
    };
    if (dotnet && findDotNet())
        return {};

    if (progress.notify)
        progress.notify(progress.context, "Installing " + std::string(package.title) + "…");
    auto result = RunCommand(brew, {"install", "--formula", package.formula}, paths.home, environment, installTimeout, &cancelled, progress);
    if (!result.succeeded)
        return result.output.empty() ? "Homebrew couldn’t install " + std::string(package.title) + "." : result.output;

    if (dotnet) {
        if (findDotNet())
            return {};
    } else {
        resolveProgram();
        if (!program.empty())
            return {};
    }
    return "Homebrew finished, but " + std::string(package.title) + " could not be found.";
}

static std::string InstallAlive(std::string_view ros, const ToolPaths &paths, const Tool &tool, const std::string &folder, Environment &environment,
                                const std::atomic_bool &cancelled, Progress progress)
{
    // Roswell's bootstrap splits paths containing spaces. Prepare the profile before moving it into place.
    char temporary[] = "/tmp/RetinaCode-Lisp-XXXXXX";
    if (!mkdtemp(temporary))
        return "Couldn’t create the Roswell setup directory.";

    SetEnvironment(environment, "ROSWELL_HOME", temporary);
    SetEnvironment(environment, "XDG_CACHE_HOME", std::string(temporary) + "/cache");
    if (progress.notify)
        progress.notify(progress.context, "Downloading Alive…");

    auto result = RunCommand(ros, {"install", tool.package}, temporary, environment, installTimeout, &cancelled, progress);
    std::error_code error;
    if (result.succeeded) {
        fs::rename(temporary, folder, error);
        if (error) {
            error.clear();
            fs::copy(temporary, folder, fs::copy_options::recursive | fs::copy_options::overwrite_existing, error);
        }
    }

    std::error_code cleanup;
    fs::remove_all(temporary, cleanup);
    if (!result.succeeded)
        return result.output.empty() ? "Couldn’t install Alive." : result.output;

    if (error || !InstallAliveLauncher(PrivateExecutable(paths, tool)) || !WriteAtomic(folder + "/.installed", {}))
        return "Couldn’t install the Alive language server launcher.";

    return {};
}

static bool WriteReceipts(const ToolPaths &paths, const Tool &tool, const std::vector<Receipt> &receipts)
{
    auto folder = ManagedFolder(paths, tool);
    std::error_code error;
    fs::create_directories(folder, error);
    if (error)
        return false;
    auto list = CFArrayCreateMutable(nullptr, receipts.size(), &kCFTypeArrayCallBacks);
    for (const auto &receipt : receipts) {
        auto fields = CFDictionaryCreateMutable(nullptr, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto add = [&](CFStringRef key, const std::string &value) {
            if (value.empty())
                return;
            auto text = CFStringCreateWithCString(nullptr, value.c_str(), kCFStringEncodingUTF8);
            if (text) {
                CFDictionarySetValue(fields, key, text);
                CFRelease(text);
            }
        };
        add(CFSTR("manager"), receipt.manager);
        add(CFSTR("file"), receipt.file);
        add(CFSTR("toolchain"), receipt.toolchain);
        auto numbers = CFArrayCreateMutable(nullptr, receipt.stamp.size(), &kCFTypeArrayCallBacks);
        for (int64_t value : receipt.stamp) {
            auto number = CFNumberCreate(nullptr, kCFNumberSInt64Type, &value);
            CFArrayAppendValue(numbers, number);
            CFRelease(number);
        }
        CFDictionarySetValue(fields, CFSTR("stamp"), numbers);
        CFArrayAppendValue(list, fields);
        CFRelease(numbers);
        CFRelease(fields);
    }
    auto data = CFPropertyListCreateData(nullptr, list, kCFPropertyListXMLFormat_v1_0, 0, nullptr);
    CFRelease(list);
    if (!data)
        return false;
    bool saved = WriteAtomic(folder + "/receipts.plist", {reinterpret_cast<const char *>(CFDataGetBytePtr(data)), size_t(CFDataGetLength(data))});
    CFRelease(data);
    return saved;
}

bool HasOwnedTools(const ToolPaths &paths, const Tool *tool)
{
    return tool && (HasPrivateInstall(paths, *tool) || !ReadReceipts(paths, *tool).empty());
}

std::string RemoveOwnedTools(const ToolPaths &paths, const Tool *tool)
{
    if (tool && HasPrivateInstall(paths, *tool)) {
        std::error_code error;
        fs::remove_all(ManagedFolder(paths, *tool), error);
        return error ? error.message() : std::string{};
    }
    auto receipts = tool ? ReadReceipts(paths, *tool) : std::vector<Receipt>{};
    if (receipts.empty())
        return "Retina Code could not verify ownership of these language tools.";
    auto environment = LanguageEnvironment(paths);
    SetEnvironment(environment, "HOMEBREW_NO_AUTO_UPDATE", "1");
    SetEnvironment(environment, "HOMEBREW_NO_AUTOREMOVE", "1");
    RemoveEnvironment(environment, "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK");
    SetEnvironment(environment, "RUSTUP_AUTO_INSTALL", "0");
    std::string_view package = tool->package;
    for (const auto &receipt : receipts) {
        bool rustup = !receipt.toolchain.empty();
        auto manager = FindTool(paths, rustup ? "rustup" : "brew", rustup ? Language::Rust : Language::Plain);
        if (manager.empty() || manager != receipt.manager)
            return "The package manager that installed these tools could not be found.";
        auto file = rustup ? RustToolFile(manager, receipt.toolchain, paths.home, environment) :
                            BrewReceipt(BrewCellar(manager, package, paths.home, environment));
        if (file != receipt.file || FileStamp(file) != receipt.stamp)
            return "The installed tools have changed since Retina Code installed them.";
        auto result = rustup ? RunCommand(manager, {"component", "remove", "--toolchain", receipt.toolchain, package}, paths.home, environment, 45s) :
                               RunCommand(manager, {"uninstall", "--formula", package}, paths.home, environment, 45s);
        if (!result.succeeded)
            return result.output.empty() ? "The package manager could not remove the language tools." : result.output;
        if (FileStamp(file) == receipt.stamp)
            return "The package manager reported success, but the language tools are still installed.";
    }
    unlink((ManagedFolder(paths, *tool) + "/receipts.plist").c_str());
    return {};
}

std::string InstallTool(const ToolPaths &paths, const Tool &tool, Language language, std::string_view root,
                        const std::atomic_bool &cancelled, Progress progress)
{
    if (cancelled.load())
        return "Installation cancelled.";

    auto environment = LanguageEnvironment(paths);
    std::string_view package = tool.package ? tool.package : "";
    auto folder = ManagedFolder(paths, tool);
    bool local = PrivateInstall(tool);
    std::string_view directory = local ? std::string_view(folder) : root;
    if (local) {
        std::error_code error;
        fs::create_directories(folder, error);
        struct stat info;
        if (error || lstat(folder.c_str(), &info) || !S_ISDIR(info.st_mode))
            return "The language tools folder is unavailable.";
    }
    std::string program, toolchain, cellar, rustFile, bin, dotnetRoot;
    auto runtime = InstallRuntime(tool.install);
    if (!runtime.executable.empty()) {
        auto error = EnsureRuntime(paths, language, runtime, environment, cancelled, progress, program, dotnetRoot);
        if (!error.empty())
            return error;
    }

    std::array<std::string_view, 10> arguments{};
    bool newlyInstalled = false;
    switch (tool.install) {
    case InstallKind::Rust:
        program = FindTool(paths, "rustup", language);
        if (!program.empty()) {
            SetEnvironment(environment, "RUSTUP_AUTO_INSTALL", "0");
            SetEnvironment(environment, "RUSTUP_MAX_RETRIES", "0");
            auto active = RunCommand(program, {"show", "active-toolchain"}, root, environment, 12s, &cancelled);
            if (!active.succeeded) {
                bool noDefault = active.output.find("no active toolchain") != active.output.npos;
                if (!noDefault && active.output.find("not installed") == active.output.npos)
                    return active.output.empty() ? "The active Rust toolchain could not be found." : active.output;

                if (progress.notify)
                    progress.notify(progress.context, "Installing Rust toolchain…");
                auto result = noDefault ? RunCommand(program, {"default", "stable"}, root, environment, installTimeout, &cancelled, progress) :
                    RunCommand(program, {"toolchain", "install", "--profile", "minimal", "--no-self-update"}, root, environment,
                               installTimeout, &cancelled, progress);
                if (!result.succeeded)
                    return result.output.empty() ? "Couldn’t install the Rust toolchain." : result.output;

                active = RunCommand(program, {"show", "active-toolchain"}, root, environment, 12s, &cancelled);
            }
            if (!active.succeeded)
                return active.output.empty() ? "The active Rust toolchain could not be found." : active.output;
            toolchain = active.output.substr(0, active.output.find_first_of(" \t\r\n"));
            if (toolchain.empty())
                return "The active Rust toolchain could not be found.";
            rustFile = RustToolFile(program, toolchain, root, environment);
            if (rustFile.empty())
                return "The active Rust toolchain could not be found.";
            newlyInstalled = MissingPath(rustFile);
            arguments = {"component", "add", "--toolchain", toolchain, package};
            break;
        }
        [[fallthrough]];
    case InstallKind::Brew:
        program = FindTool(paths, "brew", language);
        if (program.empty())
            return tool.install == InstallKind::Rust ? "Install rustup or Homebrew to install rust-analyzer." :
                                                       "Install Homebrew or choose a language server executable.";
        SetBrewInstallOptions(environment);
        cellar = BrewCellar(program, package, root, environment);
        if (cellar.empty())
            return "The Homebrew installation folder could not be found.";
        newlyInstalled = MissingPath(cellar);
        arguments = {"install", package};
        break;
    case InstallKind::Python: {
        if (progress.notify)
            progress.notify(progress.context, "Creating Python environment…");
        auto result = RunCommand(program, {"-m", "venv", folder}, directory, environment, installTimeout, &cancelled, progress);
        if (!result.succeeded)
            return result.output.empty() ? "Couldn’t create the Python environment." : result.output;
        program = folder + "/bin/python";
        arguments = {"-m", "pip", "--disable-pip-version-check", "--no-input", "--retries", "1", "--timeout", "15", "install", package};
        break;
    }
    case InstallKind::Npm:
        arguments = {"install", "--prefix", folder, "--no-audit", "--no-fund", "--fetch-retries=0", "--fetch-timeout=15000", package};
        if (package == "typescript-language-server")
            arguments[8] = "typescript";
        break;
    case InstallKind::Go:
        SetEnvironment(environment, "GOBIN", folder + "/bin");
        SetEnvironment(environment, "GOWORK", "off");
        arguments = {"install", package};
        break;
    case InstallKind::Roswell:
        return InstallAlive(program, paths, tool, folder, environment, cancelled, progress);
    case InstallKind::DotNet:
        bin = folder + "/bin";
        UseDotNetRoot(environment, dotnetRoot);
        SetEnvironment(environment, "DOTNET_CLI_TELEMETRY_OPTOUT", "1");
        arguments = {"tool", "install", package, "--tool-path", bin};
        break;
    case InstallKind::None:
        return "Choose an installed language server executable.";
    }
    if (progress.notify)
        progress.notify(progress.context, std::string("Downloading ") + tool.executable + "…");
    auto end = std::ranges::find(arguments, std::string_view{});
    auto result = RunCommand(program, std::span(arguments.begin(), end), directory, environment, installTimeout, &cancelled, progress);
    if (!result.succeeded)
        return result.output.empty() ? "The installer exited with an error." : result.output;
    if (local) {
        auto executable = PrivateExecutable(paths, tool);
        if (!IsExecutable(executable.c_str()))
            return "The installer finished, but the server executable couldn’t be found.";
        if (!dotnetRoot.empty() && !WriteAtomic(folder + "/.dotnet-root", dotnetRoot))
            return "The .NET SDK location could not be saved.";
        if (!WriteAtomic(folder + "/.installed", {}))
            return "The installation receipt could not be saved.";
    } else if (newlyInstalled) {
        auto file = toolchain.empty() ? BrewReceipt(cellar) : rustFile;
        auto stamp = FileStamp(file);
        if (!stamp)
            return "The installer finished, but its installation could not be verified.";
        auto receipts = ReadReceipts(paths, tool);
        receipts.push_back({program, file, toolchain, *stamp});
        if (!WriteReceipts(paths, tool, receipts))
            return "The installation receipt could not be saved.";
    }
    return FindExecutable(paths, &tool, language, root).empty() ? "The installer finished, but the server executable couldn’t be found." : "";
}

} // namespace lsp