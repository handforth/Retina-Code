// GNU assembler (AArch64 + some x86 AT&T) lexer stress sample
/* Block comment in GNU as syntax
   with "strings" and 'chars' and ; semicolons */
# Hash line comment (valid on x86 GNU as; on AArch64 '#' prefixes immediates)
@ At-sign comment (ARM32 style)

    .arch armv8.2-a+crypto
    .text
    .section .text.startup, "ax", %progbits
    .align 4
    .p2align 3, 0x90
    .globl _start
    .global main
    .type main, %function
    .hidden helper
    .weak weak_symbol
    .file "arm64_gnu.s"
    .ident "lexer corpus"

    .equ STACK_SIZE, 0x1000
    .set BUFFER_LEN, 256
    STDOUT = 1
    SYS_WRITE = 64
    SYS_EXIT = 93

    .macro PUSH2 a, b
        stp \a, \b, [sp, #-16]!
    .endm

    .macro POP2 a, b
        ldp \a, \b, [sp], #16
    .endm

    .macro SYSCALL num
        mov x8, #\num
        svc #0
    .endm

_start:
    mov x29, #0
    mov x30, #0
    bl main
    SYSCALL SYS_EXIT

main:
    PUSH2 x29, x30
    mov x29, sp
    sub sp, sp, #STACK_SIZE         // reserve stack
    adrp x1, message                // page address
    add x1, x1, :lo12:message       // low 12 bits relocation
    mov x0, #STDOUT
    ldr x2, =message_len
    SYSCALL SYS_WRITE

    // Numbers in many forms
    mov x3, #42
    mov x4, #0x2A
    mov x5, #0b101010
    mov x6, #052
    mov x7, #-1
    movz x9, #0xFFFF, lsl #16
    movk x9, #0xBEEF
    fmov d0, #1.5
    fmov s1, #-0.125
    ldr x10, =0xDEADBEEFCAFEBABE

    // Addressing modes
    ldr x11, [x1]
    ldr x12, [x1, #8]
    ldr x13, [x1, #16]!
    ldr x14, [x1], #8
    ldr x15, [x1, x2, lsl #3]
    ldrb w16, [x1, w2, uxtw]
    str q0, [sp, #-32]!

1:  // numeric local label
    subs x3, x3, #1
    b.ne 1b                         // backward reference
    cbz x3, 2f                      // forward reference
    nop
2:
    cmp x4, #0x10
    b.ge .Lbig
    b.lt .Lsmall
.Lbig:
    csel x0, x4, x5, gt
    b .Ldone
.Lsmall:
    csinc x0, xzr, xzr, eq
.Ldone:
    add sp, sp, #STACK_SIZE
    POP2 x29, x30
    mov w0, #0
    ret
    .size main, .-main

helper:
    eor v0.16b, v0.16b, v0.16b
    ld1 {v1.4s, v2.4s}, [x0], #32
    fmla v0.4s, v1.4s, v2.s[0]
    aese v3.16b, v4.16b
    mrs x0, CNTVCT_EL0
    msr DAIFSet, #0xF
    dmb ish
    isb
    ret

    .section .rodata
    .balign 8
message:
    .ascii "Hello, \"world\"!\n"
    .asciz "null-terminated with escapes: \t \\ \101 \x41"
    .string "another string with 'single' quotes and a # hash and // slashes"
message_len = . - message
chars:
    .byte 'A', 'b', '\n', '\\', '\'', 0x7F, 0b11, 077, -1
    .hword 0xFFFF, 65535
    .word 0xDEADBEEF, label_ref - ., (1 << 4) | 3
    .quad 0x0123456789ABCDEF, main
    .float 3.14159, -1.0e-3
    .double 2.718281828, 0e0
    .fill 4, 1, 0xCC
    .space 16, 0
    .zero 8
    .incbin "blob.bin", 0, 64

    .data
    .align 3
counter:
    .quad 0
table:
    .rept 4
    .word 0
    .endr
    .irp reg, x0, x1, x2
    .quad \reg
    .endr

    .bss
    .lcomm buffer, BUFFER_LEN
    .comm shared, 64, 8

// x86-64 AT&T-syntax fragment (GNU as accepts per-target syntax)
    .code64
    .intel_syntax noprefix
    mov rax, qword ptr [rip + counter]
    .att_syntax prefix
    movq $60, %rax          # exit syscall number
    movq $0, %rdi
    leaq message(%rip), %rsi
    movl $0x10, -8(%rbp,%rcx,4)
    syscall
    jmp *%rax
    call *8(%rbx)

    .if STACK_SIZE > 0x800
    .warning "large stack"
    .elseif STACK_SIZE == 0
    .error "zero stack"
    .else
    nop
    .endif

    .ifdef DEBUG
    .print "debug build"
    .endif

    .section .note.GNU-stack, "", %progbits
label_ref:
    .end
