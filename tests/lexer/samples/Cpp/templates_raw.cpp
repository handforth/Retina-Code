// C++ lexer stress: templates vs comparisons, raw strings, literals, attributes, preprocessor
#include <algorithm>
#include <array>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include <type_traits>
#include "project/config.hpp"

#define CHECK(expr)                                       \
    do {                                                  \
        if (!(expr)) {                                    \
            std::cerr << "check failed: " #expr << '\n';  \
            std::abort();                                 \
        }                                                 \
    } while (false)
#define TEMPLATE_MACRO(T) std::vector<std::map<int, T>>

#if 0
Disabled: R"( unterminated raw, "string, 'char, /* comment
#endif

using namespace std::literals;

// Raw strings
const char *raw1 = R"(simple raw with "quotes" and \n literal)";
const char *raw2 = R"delim(raw with )" inside that does not close)delim";
const char *raw3 = R"xyz(
multi-line raw string
  with "quotes", 'chars', // not a comment
  /* not a block comment */ and \ backslashes
)xyz";
const wchar_t *raw4 = LR"(wide raw)";
const char8_t *raw5 = u8R"(utf8 raw)";
const char16_t *raw6 = uR"(utf16 raw)";
const char32_t *raw7 = UR"(utf32 raw)";
const char *raw8 = R"()";
const char *raw9 = R"a()a" R"b(adjacent raw)b";

// Ordinary strings and chars
const char *s1 = "double \"quoted\" with \\ and \n and \x41 and \101 and é";
const char *s2 = "trailing backslash \\";
const char *s3 = "unterminated string at end of line
int after_unterminated = 1;
const char *s4 = "continued \
string";
char c1 = 'a', c2 = '\'', c3 = '\\', c4 = '\n', c5 = '\x7f';
char16_t c6 = u'x';
char32_t c7 = U'\U0001F600';
wchar_t c8 = L'w';
char8_t c9 = u8'a';
int mc = 'ABCD';

// Numeric literals and user-defined literals
auto i1 = 1'000'000;
auto i2 = 0xFF'FF;
auto i3 = 0b1010'1010;
auto i4 = 0755;
auto i5 = 42u;
auto i6 = 42ul;
auto i7 = 42ULL;
auto i8 = 42z;   // C++23 size_t literal
auto f1 = 3.0f;
auto f2 = 1.5e-3;
auto f3 = .5L;
auto f4 = 0x1.8p1;
auto f5 = 1e10;
auto str_lit = "hello"s;
auto sv_lit = "view"sv;
auto dur = 100ms;
auto chrono2 = 2h + 30min;
constexpr long double operator""_km(long double v) { return v * 1000.0L; }
auto dist = 1.5_km;

// Templates and contextual angle brackets
template <typename T, typename U = int, int N = 4>
struct Pair {
    T first;
    U second;
    std::array<T, N> extra{};
};

template <class... Ts>
struct Overloaded : Ts... { using Ts::operator()...; };
template <class... Ts> Overloaded(Ts...) -> Overloaded<Ts...>;

template <typename T>
concept Numeric = std::is_arithmetic_v<T> && !std::is_same_v<T, bool>;

template <Numeric T>
constexpr T square(T x) noexcept { return x * x; }

template <typename T>
    requires requires(T t) { { t.size() } -> std::convertible_to<std::size_t>; }
auto size_of(const T &t) { return t.size(); }

template <>
struct Pair<void, void, 0> {};

template <typename T>
class Container {
public:
    template <typename U>
    U convert() const { return static_cast<U>(value_); }

    template <typename F>
    auto apply(F &&f) -> decltype(f(std::declval<T>())) { return std::forward<F>(f)(value_); }

private:
    T value_{};
};

template <typename T>
void uses_template_keyword(Container<T> &c) {
    auto x = c.template convert<double>();
    auto *p = &c;
    auto y = p->template convert<int>();
    typename std::vector<T>::iterator it;
    (void)x; (void)y; (void)it;
}

std::vector<std::map<int, std::vector<std::string>>> nested_closing_brackets;
TEMPLATE_MACRO(double) from_macro;
std::map<std::string, std::unique_ptr<std::vector<std::pair<int, int>>>> deep;

bool comparisons(int a, int b, int c) {
    bool r1 = a < b > c;          // parsed as (a < b) > c
    bool r2 = a < b && b > c;
    bool r3 = (a >> 1) < (b << 2);
    bool r4 = a <= b || b >= c;
    auto r5 = a <=> b;            // spaceship
    return r1 || r2 || r3 || r4 || (r5 < 0);
}

std::ostream &operator<<(std::ostream &os, const Pair<int, int> &p) {
    return os << "(" << p.first << ", " << p.second << ")";
}

struct Matrix {
    double operator()(int r, int c) const { return r * 10.0 + c; }
    double operator[](int i) const { return i; }
    Matrix &operator<<=(int) { return *this; }
    Matrix &operator>>=(int) { return *this; }
    explicit operator bool() const { return true; }
    friend bool operator==(const Matrix &, const Matrix &) = default;
};

// Attributes
[[nodiscard]] int must_use() { return 42; }
[[deprecated("use new_api")]] void old_api() {}
[[noreturn]] void fail() { throw std::runtime_error("fail"); }
[[maybe_unused]] static int unused_var = 0;
struct [[gnu::packed]] Packed { char c; int i; };
alignas(16) static float aligned[4];

namespace outer::inner {
inline namespace v1 {
    enum class Color : unsigned char { Red = 'r', Green = 'g', Blue = 'b' };
}
}

int main() {
    Pair<int, int> p{1, 2};
    std::cout << p << '\n' << raw3 << std::endl;
    auto lambda = [&, x = 5]<typename T>(T v) mutable noexcept -> T { return v + x; };
    auto generic = [](auto &&...args) { return (args + ...); };
    std::vector<int> v{3, 1, 2};
    std::ranges::sort(v, std::greater<>{});
    if (auto it = std::find(v.begin(), v.end(), 2); it != v.end()) {
        std::cout << "found " << *it << '\n';
    }
    switch (auto c = outer::inner::Color::Red; c) {
    case outer::inner::Color::Red: [[fallthrough]];
    case outer::inner::Color::Green: break;
    default: break;
    }
    auto [a, b] = std::pair{1, "two"};
    constexpr auto sq = square(7);
    static_assert(sq == 49, "math is broken");
    CHECK(lambda(1) == 6 && generic(1, 2, 3) == 6);
    co_await_like: ;
    return must_use() - 42;
}
