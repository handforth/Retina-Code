// coroutines_unterminated.cpp — second C++ sample.
// Modules-ish preamble, coroutines, CRTP, variadic templates, and an unterminated
// raw string literal at EOF (spanning many lines with a close-looking delimiter).

#include <coroutine>
#include <cstdint>
#include <exception>
#include <format>
#include <functional>
#include <optional>
#include <ranges>
#include <span>
#include <utility>
#include <variant>

#ifndef GENERATOR_HPP
#define GENERATOR_HPP

#define FWD(x) std::forward<decltype(x)>(x)
#define UNUSED(...) (void)sizeof...(__VA_ARGS__)
// Line comment ending with backslash: continues \
#define THIS_IS_STILL_A_COMMENT 1

template <typename T>
class Generator {
public:
    struct promise_type {
        std::optional<T> current;
        std::exception_ptr error;

        Generator get_return_object() { return Generator{handle::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        std::suspend_always yield_value(T v) noexcept(std::is_nothrow_move_constructible_v<T>) {
            current = std::move(v);
            return {};
        }
        void return_void() noexcept {}
        void unhandled_exception() { error = std::current_exception(); }
    };

    using handle = std::coroutine_handle<promise_type>;

    explicit Generator(handle h) : h_{h} {}
    Generator(Generator &&o) noexcept : h_{std::exchange(o.h_, {})} {}
    Generator &operator=(Generator &&o) noexcept {
        if (this != &o) { if (h_) h_.destroy(); h_ = std::exchange(o.h_, {}); }
        return *this;
    }
    ~Generator() { if (h_) h_.destroy(); }

    struct sentinel {};
    struct iterator {
        handle h;
        iterator &operator++() { h.resume(); return *this; }
        const T &operator*() const { return *h.promise().current; }
        bool operator==(sentinel) const { return !h || h.done(); }
    };

    iterator begin() {
        if (h_) h_.resume();
        return iterator{h_};
    }
    sentinel end() { return {}; }

private:
    handle h_;
};

#endif // GENERATOR_HPP

Generator<std::uint64_t> fibonacci(std::size_t n) {
    std::uint64_t a = 0, b = 1;
    for (std::size_t i = 0; i < n; ++i) {
        co_yield a;
        a = std::exchange(b, a + b);
    }
}

Generator<std::string> lines(std::string_view text) {
    while (!text.empty()) {
        auto pos = text.find('\n');
        co_yield std::string{text.substr(0, pos)};
        if (pos == std::string_view::npos) co_return;
        text.remove_prefix(pos + 1);
    }
}

// CRTP
template <typename Derived>
struct Shape {
    double area() const { return static_cast<const Derived &>(*this).area_impl(); }
    std::string describe() const { return std::format("{} with area {:.2f}", Derived::name, area()); }
};

struct Circle : Shape<Circle> {
    static constexpr const char *name = "circle";
    double r;
    explicit Circle(double r_) : r{r_} {}
    double area_impl() const { return 3.14159265358979 * r * r; }
};

struct Square : Shape<Square> {
    static constexpr auto name = "square";
    double s;
    double area_impl() const { return s * s; }
};

// Variadic templates and fold expressions
template <typename... Args>
auto sum(Args &&...args) { return (FWD(args) + ... + 0); }

template <typename... Args>
void print_all(std::format_string<Args...> fmt, Args &&...args) {
    std::puts(std::format(fmt, FWD(args)...).c_str());
}

template <typename T, typename... Rest>
constexpr bool all_same_v = (std::is_same_v<T, Rest> && ...);

template <std::size_t... Is>
constexpr auto make_indices(std::index_sequence<Is...>) { return std::array{Is...}; }

// std::visit with overloaded lambdas
template <class... Fs> struct overload : Fs... { using Fs::operator()...; };

std::string visit_demo(const std::variant<int, double, std::string> &v) {
    return std::visit(overload{
        [](int i) { return std::format("int {}", i); },
        [](double d) { return std::format("double {:.3}", d); },
        [](const std::string &s) { return std::format("string \"{}\"", s); },
    }, v);
}

// Ranges pipelines
auto evens_squared(std::span<const int> xs) {
    return xs | std::views::filter([](int x) { return x % 2 == 0; })
              | std::views::transform([](int x) { return x * x; })
              | std::views::take(5);
}

// Odd tokens
int digraphs() <% int arr<:3:> = <% 1, 2, 3 %>; return arr<:0:>; %>
int alternative_tokens(int a, int b) { return a and b or not a xor b bitand compl a; }
auto pointer_to_member = &Circle::r;
auto scope = ::std::size_t{0};
auto destructor_call = [](Circle *c) { c->~Circle(); };
auto ellipsis_in_catch = [] { try { throw 1; } catch (...) { return -1; } };
auto ternary_template = sizeof(int) > 2 ? std::vector<int>{} : std::vector<int>{1};
auto shift_vs_template = std::vector<std::vector<int>>{} ; auto shifted = 1 >> 2 > 0;

int main() {
    for (auto f : fibonacci(10)) print_all("fib {}", f);
    for (const auto &l : lines("one\ntwo\nthree")) print_all("line '{}'", l);
    Circle c{2.0};
    Square s{};
    s.s = 3.0;
    print_all("{} | {}", c.describe(), s.describe());
    print_all("sum={} same={}", sum(1, 2.5, 3u), all_same_v<int, int, int>);
    print_all("{}", visit_demo(std::string{"hi"}));
    int data[] = {1, 2, 3, 4, 5, 6, 7, 8};
    for (int v : evens_squared(data)) print_all("{}", v);
    return digraphs() + alternative_tokens(1, 0);
}

// The raw string below never closes: ")sql" appears but the delimiter is "end".
const char *unterminated_raw = R"end(
SELECT * FROM t WHERE name = 'x' -- )sql
)en
)endd  <- not the closer either (extra character before quote check)
int not_code() { return 0; }
/* not a comment */ // not a line comment
