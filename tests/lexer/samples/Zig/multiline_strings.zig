//! Zig lexer stress sample: top-level doc comment.
//! Multiline string literals, char literals, builtins, numbers.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// Doc comment on a declaration.
/// Contains "quotes" and 'chars' and \\ backslashes.
pub const greeting = "Hello, \"world\"!\n";
const escapes = "tab\t cr\r nl\n bs\\ dq\" sq\' hex\x41 uni\u{1F600} \u{41}";
const trailing = "ends with backslash \\";
const commentLike = "// not a comment";
const unterminated = "missing closing quote
const afterUnterminated = 1;

// Multiline string literal: each line starts with \\
const multi =
    \\first line with "quotes" and 'apostrophes'
    \\second line with \n literal (no escapes here)
    \\// not a comment
    \\    indented content
    \\
    \\empty line above
;

const multiInCall = std.fmt.comptimePrint(
    \\value: {d}
    \\name: {s}
, .{ 42, "zig" });

const json =
    \\{
    \\  "key": "value",
    \\  "list": [1, 2, 3]
    \\}
;

const mixedLines =
    \\line one
    // a regular comment interleaved between multiline string lines
    \\line two
;

// Character literals
const chars = [_]u8{ 'a', '\'', '\\', '\n', '\t', '\x7F', '"' };
const uniChar: u21 = '\u{1F600}';
const utf8Char: u21 = 'é';

// Numbers
const dec: u32 = 1_000_000;
const hex: u32 = 0xFF_FF;
const bin: u8 = 0b1010_1010;
const oct: u16 = 0o777;
const flt: f64 = 1.5e-3;
const hexFlt: f64 = 0x1.8p1;
const bigInt: u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
const negative: i64 = -0x80;
const inf = std.math.inf(f32);

pub const Color = enum(u8) {
    red = 1,
    green,
    blue = 0x10,

    pub fn name(self: Color) []const u8 {
        return @tagName(self);
    }
};

pub const Shape = union(enum) {
    circle: f32,
    rect: struct { w: f32, h: f32 },
    none,

    pub fn area(self: Shape) f32 {
        return switch (self) {
            .circle => |r| std.math.pi * r * r,
            .rect => |r| r.w * r.h,
            .none => 0,
        };
    }
};

fn GenericList(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        len: usize = 0,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .items = &[_]T{}, .allocator = allocator };
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.len >= self.items.len) {
                const new_cap = @max(8, self.items.len * 2);
                self.items = try self.allocator.realloc(self.items, new_cap);
            }
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.* = undefined;
        }
    };
}

const Packed = packed struct(u8) {
    a: u3,
    b: u4,
    c: bool,
};

const Extern = extern struct {
    x: c_int,
    y: [*c]const u8,
    z: ?*anyopaque,
};

fn errorful(x: i32) error{ Negative, TooBig }!u32 {
    if (x < 0) return error.Negative;
    if (x > 1000) return error.TooBig;
    return @intCast(x);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var list = GenericList(u32).init(allocator);
    defer list.deinit();
    try list.append(1);
    try list.append(@as(u32, 2) << 3);

    const v = errorful(-1) catch |err| switch (err) {
        error.Negative => 0,
        error.TooBig => 1000,
    };
    const w = errorful(5) catch unreachable;
    const opt: ?u32 = null;
    const unwrapped = opt orelse 7;

    for (list.items[0..list.len], 0..) |item, i| {
        std.debug.print("{d}: {d}\n", .{ i, item });
    }
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (i % 2 == 0) continue;
    }
    outer: for (0..3) |a| {
        inner: for (0..3) |b| {
            if (a == b) continue :outer;
            if (a > b) break :inner;
        }
    }
    const blk = label: {
        break :label @as(u8, 5);
    };
    comptime {
        std.debug.assert(@sizeOf(Packed) == 1);
    }
    const ptr: *const [5:0]u8 = "hello";
    const sentinel: [:0]const u8 = ptr;
    const vec: @Vector(4, f32) = .{ 1, 2, 3, 4 };
    _ = .{ v, w, unwrapped, blk, sentinel, vec, multi, json, mixedLines, multiInCall };
    if (builtin.os.tag == .linux and builtin.mode != .Debug) {
        asm volatile ("nop" ::: "memory");
    }
}

test "basic test with string name" {
    try std.testing.expectEqual(@as(u32, 3), 1 + 2);
    try std.testing.expectEqualStrings("a", "a");
}

test @"quoted identifier test" {}
const @"weird identifier with spaces" = 1;
const @"while" = 2;
