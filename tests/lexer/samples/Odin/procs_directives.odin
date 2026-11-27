// Odin lexer stress: procs, #directives, nested comments, raw strings, numbers
package stress

import "core:fmt"
import "core:mem"
import "core:strings"
import os "core:os"
import "base:runtime"

/* Odin block comments nest: /* inner /* deeper */ */ still outer
   and this line is still a comment */
after_nested :: "visible"

// Strings
simple     :: "double \"quoted\" with \\ and \n and \t"
escapes    :: "hex \x41 octal \101 unicode é \U0001F600 bell \a esc \e"
trailing   :: "ends with backslash \\"
raw        :: `raw string: no \n escapes, "quotes" fine`
raw_multi  :: `first line
second line with 'single' and "double"
/* not a comment */ // nor this
last line`
comment_in :: "// not a comment /* nor this */"
unterminated :: "missing the closing quote
after_unterminated :: 1

// Runes
r1 :: 'a'
r2 :: '\''
r3 :: '\\'
r4 :: '\n'
r5 :: 'é'
r6 :: '😀'
r7 :: '\x41'

// Numbers
dec     :: 1_000_000
hex     :: 0xFF_FF
oct     :: 0o17
bin     :: 0b1010_1010
dozenal :: 0z1B
flt     :: 1.5e-3
flt2    :: .5
hexflt  :: 0h3F80_0000
imag    :: 2i
quat    :: 1 + 2i + 3j + 4k
big     :: 0xFFFF_FFFF_FFFF_FFFF

Vector3 :: [3]f32
Matrix4 :: matrix[4, 4]f32

Color :: enum u8 {
	Red = 1,
	Green,
	Blue = 0x10,
}

Color_Set :: bit_set[Color; u8]

Shape :: union {
	Circle,
	Rect,
}

Circle :: struct {
	center: [2]f32,
	radius: f32,
}

Rect :: struct #packed {
	min, max: [2]f32,
}

Entity :: struct($T: typeid) where size_of(T) <= 64 {
	using base: Base,
	data:       T,
	tags:       [dynamic]string,
	lookup:     map[string]int,
	next:       ^Entity(T),
	raw_ptr:    rawptr,
	slice:      []u8,
	multi:      [^]u8,
	soa:        #soa[8]Vector3,
}

Base :: struct {
	id:   u64 `json:"id"`,
	name: string `json:"name,omitempty"`,
}

Flags :: bit_field u16 {
	a: bool | 1,
	b: u8   | 4,
	c: u8   | 3,
}

area :: proc(s: Shape) -> f32 {
	switch v in s {
	case Circle:
		return 3.14159 * v.radius * v.radius
	case Rect:
		d := v.max - v.min
		return d.x * d.y
	case:
		return 0
	}
}

add :: proc "contextless" (a, b: int) -> int { return a + b }

divmod :: proc(a, b: int) -> (q, r: int, ok: bool) #optional_ok {
	if b == 0 {
		return
	}
	return a / b, a % b, true
}

generic_max :: proc(a, b: $T) -> T where intrinsics.type_is_ordered(T) {
	return a if a > b else b
}

overloaded :: proc{add, generic_max}

@(private = "file")
helper :: proc(x: ^int) {
	x^ += 1
}

@(require_results, deprecated = "use other")
old_proc :: proc() -> bool { return true }

@(export, link_name = "lexer_entry")
entry :: proc "c" () {
	context = runtime.default_context()
	fmt.println("entry")
}

foreign import libc "system:c"
foreign libc {
	@(link_name = "puts")
	c_puts :: proc "c" (s: cstring) -> i32 ---
}

main :: proc() {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	x := 10
	y: f64 = 2.5
	z := x / 3 % 2 << 1 >> 1 &~ 0xF | 0b1 ~ 2
	ptr := &x
	ptr^ = 20
	arr := [?]int{1, 2, 3, 4}
	dyn := make([dynamic]int, 0, 16)
	defer delete(dyn)
	append(&dyn, 1, 2, 3)
	m := map[string]int{"a" = 1, "b" = 2}
	defer delete(m)
	set: Color_Set = {.Red, .Blue}
	cast_val := cast(f32)x
	trans := transmute(u32)f32(1.0)
	auto := auto_cast y

	for i in 0..<10 {
		if i % 2 == 0 do continue
		fmt.printf("%d ", i)
	}
	for v, i in arr {
		fmt.println(i, v)
	}
	for k, v in m {
		fmt.println(k, "=", v)
	}
	outer: for i := 0; i < 3; i += 1 {
		for j in 0..=2 {
			if j > i do continue outer
			if i * j > 2 do break outer
		}
	}
	#partial switch c := Color.Red; c {
	case .Red: fmt.println("red")
	}
	when ODIN_OS == .Windows {
		fmt.println("windows")
	} else when ODIN_OS == .Linux {
		fmt.println("linux")
	}
	assert(x > 0, "x must be positive")
	#assert(size_of(int) == 8)
	loc := #location()
	file := #file
	line := #line
	proc_name := #procedure
	cfg := #config(DEBUG, false)
	data := #load("data.bin")
	exists := #exists("data.bin")
	defer if x > 0 { fmt.println("deferred") }
	_ = #force_inline add(1, 2)
	_ = #no_bounds_check arr[0]
	_ = (^int)(nil)
	_ = ternary := x > 5 ? "big" : "small"
	fmt.println(z, ptr, set, cast_val, trans, auto, loc, file, line, proc_name, cfg, data, exists)
}

/* nested /* comment */ closes */ final_value :: 'z'
