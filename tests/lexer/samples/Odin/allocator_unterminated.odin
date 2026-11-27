// Second Odin sample: an arena allocator, ends inside an unterminated nested comment.
package arena

import "core:mem"
import "core:fmt"
import "core:testing"

DEFAULT_ALIGNMENT :: 2 * align_of(rawptr)
DEFAULT_BLOCK     :: 64 * mem.Kilobyte

Block :: struct {
	prev:   ^Block,
	data:   []byte,
	offset: int,
}

Arena :: struct {
	backing:    mem.Allocator,
	current:    ^Block,
	block_size: int,
	total_used: int,
	peak:       int,
}

Arena_Error :: enum {
	None,
	Out_Of_Memory,
	Invalid_Alignment,
}

init :: proc(a: ^Arena, block_size := DEFAULT_BLOCK, backing := context.allocator) {
	a^ = {}
	a.backing = backing
	a.block_size = block_size
}

@(private)
new_block :: proc(a: ^Arena, min_size: int) -> (b: ^Block, err: mem.Allocator_Error) {
	size := max(a.block_size, min_size + size_of(Block))
	raw := mem.alloc_bytes(size, DEFAULT_ALIGNMENT, a.backing) or_return
	b = (^Block)(raw_data(raw))
	b.data = raw[size_of(Block):]
	b.offset = 0
	b.prev = a.current
	a.current = b
	return
}

align_forward :: #force_inline proc "contextless" (ptr: uintptr, align: uintptr) -> uintptr {
	assert_contextless(mem.is_power_of_two(align))
	return (ptr + align - 1) & ~(align - 1)
}

alloc :: proc(a: ^Arena, size: int, align := DEFAULT_ALIGNMENT) -> ([]byte, mem.Allocator_Error) {
	if a.current == nil {
		new_block(a, size + align) or_return
	}
	for {
		b := a.current
		base := uintptr(raw_data(b.data))
		start := align_forward(base + uintptr(b.offset), uintptr(align)) - base
		end := int(start) + size
		if end <= len(b.data) {
			b.offset = end
			a.total_used += size
			a.peak = max(a.peak, a.total_used)
			return b.data[start:end], nil
		}
		new_block(a, size + align) or_return
	}
}

free_all :: proc(a: ^Arena) {
	for b := a.current; b != nil; {
		prev := b.prev
		total := len(b.data) + size_of(Block)
		mem.free_with_size(b, total, a.backing)
		b = prev
	}
	a.current = nil
	a.total_used = 0
}

arena_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	a := (^Arena)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		bytes, err := alloc(a, size, alignment)
		if err == nil && mode == .Alloc {
			mem.zero_slice(bytes)
		}
		return bytes, err
	case .Free:
		return nil, .Mode_Not_Implemented
	case .Free_All:
		free_all(a)
	case .Resize, .Resize_Non_Zeroed:
		bytes, err := alloc(a, size, alignment)
		if err == nil && old_memory != nil {
			copy(bytes, ([^]byte)(old_memory)[:old_size])
		}
		return bytes, err
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free_All, .Resize, .Query_Features}
		}
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

allocator :: proc(a: ^Arena) -> mem.Allocator {
	return {procedure = arena_allocator_proc, data = a}
}

@(test)
test_basic :: proc(t: ^testing.T) {
	a: Arena
	init(&a, 256)
	defer free_all(&a)
	context.allocator = allocator(&a)

	s := make([]int, 10)
	for &v, i in s do v = i * i
	testing.expect_value(t, s[9], 81)

	str := fmt.aprintf("arena %s %d %.2f %v", "test", 42, 3.14159, s[:3])
	testing.expect(t, len(str) > 0, "string should not be empty")
	testing.expectf(t, a.total_used > 0, "used = %d", a.total_used)
}

@(test)
test_alignment :: proc(t: ^testing.T) {
	a: Arena
	init(&a)
	defer free_all(&a)
	for align in ([]int{1, 2, 4, 8, 16, 32, 64}) {
		bytes, err := alloc(&a, 3, align)
		testing.expect(t, err == nil)
		testing.expect(t, uintptr(raw_data(bytes)) % uintptr(align) == 0)
	}
}

stats_string :: proc(a: ^Arena) -> string {
	return fmt.tprintf(
		`Arena stats:
	used: %v
	peak: %v
	block: %v`,
		a.total_used, a.peak, a.block_size,
	)
}

numbers := [?]f64{0, 1, -1, 1e9, 1.5e-9, 0x10, 0o10, 0b10, 0z10, 1_000.000_1}
masks := [?]u32{0xFFFF_0000, 0x0000_FFFF, ~u32(0), 1 << 31}

/* Notes on the allocator (this comment never closes):
   /* - freeing individual allocations is not supported
      /* - nested three deep, closed */
      - still level two
   */
   - back at level one; the outer comment needs one more closer.
   alloc :: proc() {} // not code
