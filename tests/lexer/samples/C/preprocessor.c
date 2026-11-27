/*
 * C lexer stress sample: preprocessor, continuations, #if 0, literals, comments.
 * Block comments do not nest: /* this inner opener is just text
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "local_header.h"
#include MACRO_INCLUDE_PATH

#define VERSION "1.2.3"
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) \
    ((a) < (b) ? \
     (a) : (b))
#define STRINGIFY(x) #x
#define TOSTRING(x) STRINGIFY(x)
#define CONCAT(a, b) a ## b
#define LOG(fmt, ...) fprintf(stderr, "[%s:%d] " fmt "\n", __FILE__, __LINE__, ##__VA_ARGS__)
#define VARIADIC(...) __VA_OPT__(call(__VA_ARGS__))
#define MULTI_LINE_STRING_MACRO "first part " \
                                "second part"
#define EMPTY
#define COMMENT_IN_MACRO 42 /* block comment after value */ // and a line comment
#define DO_TWICE(stmt) do { stmt; stmt; } while (0)
#undef EMPTY

#if 0
This region is disabled. It may contain anything:
  "an unterminated string
  'an unterminated char
  /* an unterminated comment
  #define NOT_DEFINED 1
#endif

#if defined(_WIN32) || defined(_WIN64)
#  define PLATFORM "windows"
#elif defined(__APPLE__) && __APPLE__
#  define PLATFORM "macos"
#elif __linux__ + 0 > 0
#  define PLATFORM "linux"
#else
#  error "Unsupported platform: " TOSTRING(__STDC_VERSION__)
#endif

#ifdef DEBUG
#  warning "Debug build"
#endif

#ifndef NDEBUG
#  define ASSERT(c) do { if (!(c)) { LOG("assert failed: %s", #c); abort(); } } while (0)
#else
#  define ASSERT(c) ((void)0)
#endif

#pragma once
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-variable"
#line 100 "renamed.c"
_Pragma("message(\"pragma operator\")")

// Line comment ending with a backslash continues onto the next line \
   so this line is still part of the comment
static int after_continued_comment = 1;

/* Block comment */ static int after_block = 2; /* another */

// Strings
static const char *s1 = "double \"quoted\" with \\ and \n and \t";
static const char *s2 = "hex \x41\x42 octal \101\7 and \0 and \e (GNU) and é \U0001F600";
static const char *s3 = "string with line continuation \
on the next physical line";
static const char *s4 = "adjacent " "literal " "concatenation";
static const char *s5 = "trailing backslash \\";
static const char *s6 = "// not a comment /* nor this */";
static const char *s7 = "unterminated string at end of line
static int after_unterminated = 3;
static const char *s8 = u8"UTF-8 literal";
static const wchar_t *s9 = L"wide literal";
static const char16_t *s10 = u"UTF-16 literal";
static const char32_t *s11 = U"UTF-32 literal";
static const char *s12 = "??=trigraph??/";

// Characters
static const char c1 = 'a';
static const char c2 = '\'';
static const char c3 = '\\';
static const char c4 = '\n';
static const char c5 = '\x7F';
static const char c6 = '\0';
static const char c7 = '"';
static const int multi = 'ABCD';
static const wchar_t wc = L'w';
static const char32_t uc = U'\U0001F600';

// Numbers
static const int n_dec = 42;
static const int n_hex = 0xFF;
static const int n_HEX = 0XDEADBEEF;
static const int n_oct = 0755;
static const int n_bin = 0b1010;  /* C23 / GNU */
static const unsigned n_u = 42u;
static const long n_l = 42L;
static const unsigned long long n_ull = 42ULL;
static const long long n_ll = 42ll;
static const float f1 = 3.0f;
static const double d1 = 1.5e-3;
static const double d2 = .5;
static const double d3 = 5.;
static const long double ld = 1.0L;
static const double hexflt = 0x1.8p1;
static const int sep = 1'000'000;  /* C23 digit separators */
static const size_t sz = sizeof(int) * 8;

typedef struct Node {
    int value;
    struct Node *next;
    union {
        int i;
        float f;
    } data;
    unsigned flags : 4;
    unsigned       : 0;
    char name[32];
} Node;

typedef enum { RED = 1, GREEN = 1 << 1, BLUE = 0x4 } Color;
typedef int (*BinOp)(int, int);

static inline int add(int a, int b) { return a + b; }

static int apply(BinOp op, int a, int b) {
    return op ? op(a, b) : -1;
}

int main(int argc, char *argv[restrict static 1]) {
    Node *head = calloc(1, sizeof *head);
    if (!head) {
        perror("calloc");
        return EXIT_FAILURE;
    }
    head->value = MAX(argc, 2);
    head->data.f = 1.0f / 3.0f;
    snprintf(head->name, sizeof head->name, "%s-%d", PLATFORM, head->value);

    int arr[] = {1, 2, 3, [9] = 10};
    int *p = &arr[0];
    int x = *p++ + ++*p - p[-1] % 3 / 2;
    x <<= 2; x >>= 1; x &= ~0xF; x |= 1; x ^= 0x55;
    bool ok = x > 0 && x < 100 || !x;
    int ternary = ok ? x : -x;
    Color c = (Color)(RED | BLUE);

    for (int i = 0; i < 3; i++) {
        switch (i) {
        case 0: LOG("zero"); break;
        case 1: { LOG("one %d", i); } /* fallthrough */
        default: LOG("other");
        }
    }

    goto cleanup;
cleanup:
    DO_TWICE(x++);
    printf("%s %s %d %d %d\n", VERSION, head->name, x, ternary, c);
    printf("%s\n", MULTI_LINE_STRING_MACRO);
    free(head);
    return apply(add, 1, 2) == 3 ? 0 : 1;
}

#pragma GCC diagnostic pop
/* final comment, properly closed */
