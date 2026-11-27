//! Second Zig sample: a toy tokenizer. Zig has no block comments, so this file
//! instead ends inside a multiline string literal and an unterminated char.

const std = @import("std");
const testing = std.testing;

pub const Tag = enum {
    identifier,
    number,
    string,
    char,
    l_paren,
    r_paren,
    plus,
    minus,
    slash,
    comment,
    eof,
    invalid,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub fn slice(self: Token, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

pub const Tokenizer = struct {
    src: [:0]const u8,
    index: usize = 0,

    const State = enum { start, ident, number, string, string_escape, char, slash, comment };

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result = Token{ .tag = .eof, .start = self.index, .end = undefined };
        while (true) : (self.index += 1) {
            const c = self.src[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => break,
                    ' ', '\t', '\r', '\n' => result.start = self.index + 1,
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .ident;
                        result.tag = .identifier;
                    },
                    '0'...'9' => {
                        state = .number;
                        result.tag = .number;
                    },
                    '"' => {
                        state = .string;
                        result.tag = .string;
                    },
                    '\'' => {
                        state = .char;
                        result.tag = .char;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    '+' => {
                        result.tag = .plus;
                        self.index += 1;
                        break;
                    },
                    '-' => {
                        result.tag = .minus;
                        self.index += 1;
                        break;
                    },
                    '/' => state = .slash,
                    else => {
                        result.tag = .invalid;
                        self.index += 1;
                        break;
                    },
                },
                .ident => switch (c) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => break,
                },
                .number => switch (c) {
                    '0'...'9', '_', '.', 'x', 'o', 'b', 'e', 'p', 'a'...'d', 'f', 'A'...'F' => {},
                    else => break,
                },
                .string => switch (c) {
                    '"' => {
                        self.index += 1;
                        break;
                    },
                    '\\' => state = .string_escape,
                    '\n', 0 => {
                        result.tag = .invalid;
                        break;
                    },
                    else => {},
                },
                .string_escape => state = .string,
                .char => switch (c) {
                    '\'' => {
                        self.index += 1;
                        break;
                    },
                    else => {},
                },
                .slash => switch (c) {
                    '/' => state = .comment,
                    else => {
                        result.tag = .slash;
                        break;
                    },
                },
                .comment => switch (c) {
                    '\n', 0 => {
                        result.tag = .comment;
                        break;
                    },
                    else => {},
                },
            }
        }
        result.end = self.index;
        return result;
    }
};

fn expectTokens(src: [:0]const u8, expected: []const Tag) !void {
    var t = Tokenizer{ .src = src };
    for (expected) |tag| {
        const tok = t.next();
        try testing.expectEqual(tag, tok.tag);
    }
    try testing.expectEqual(Tag.eof, t.next().tag);
}

test "identifiers and numbers" {
    try expectTokens("foo 0x1F 1_000 3.14e-2", &.{ .identifier, .number, .number, .number });
}

test "strings with escapes" {
    try expectTokens("\"a\\\"b\" 'c'", &.{ .string, .char });
}

test "comments and slashes" {
    try expectTokens("a / b // trailing comment\n", &.{ .identifier, .slash, .identifier, .comment });
}

test "multiline input" {
    const src: [:0]const u8 =
        \\(foo + bar)
        \\- "str" // c
    ;
    try expectTokens(src, &.{ .l_paren, .identifier, .plus, .identifier, .r_paren, .minus, .string, .comment });
}

const Fmt = struct {
    pub fn format(self: Fmt, comptime fmt: []const u8, opts: std.fmt.FormatOptions, w: anytype) !void {
        _ = .{ self, fmt, opts };
        try w.writeAll("Fmt{}");
    }
};

inline fn square(comptime T: type, x: T) T {
    return x *% x;
}

const wrapping = @as(u8, 200) +% 100;
const saturating = @as(u8, 200) +| 100;
const shifted = @as(u32, 1) << 31 >> 3;
const lt = 1 < 2 and 3 > 2 or !true;
const ptrCast: *u32 = @ptrCast(@alignCast(undefined));
const nums = .{ 0b1, 0o7, 0xF, 1.0, 1e9, 0x1p-4, 1_0 };

const help_text =
    \\Usage: tokenizer [options] <file>
    \\
    \\Options:
    \\  -h, --help     Show this "help" text
    \\  -v             Verbose \\ output
    \\
    \\This multiline string runs to the end of the file because the
    \\terminating line with a semicolon is missing.
    \\const not_code = 'x';
    \\pub fn notAFunction() void {}
