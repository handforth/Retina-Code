; NASM syntax lexer stress sample: x86 boot sector plus 64-bit long mode code
; Semicolon comments, %macros, local labels, strings with three quote kinds

%define SECTOR_SIZE 512
%define VIDEO_MEM   0xB800
%define NEWLINE     13, 10
%assign COUNTER     0
%xdefine LATER      SECTOR_SIZE * 2
%undef  SOMETHING
%include "constants.inc"

%macro PRINT 1
    mov si, %1
    call print_string
%endmacro

%macro PUSHALL 0-*
  %rep %0
    push %1
    %rotate 1
  %endrep
%endmacro

%macro DEBUG_ONLY 1+
%ifdef DEBUG
    %1
%endif
%endmacro

%imacro outb 2
    mov dx, %1
    mov al, %2
    out dx, al
%endmacro

    bits 16
    org 0x7C00
    cpu 686

section .text
global start
extern kernel_main

start:
    cli                         ; disable interrupts
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [boot_drive], dl
    PRINT msg_hello
    PRINT msg_quotes
    call .load_kernel
    jmp switch_to_pm

.load_kernel:                   ; local label belongs to 'start'
    mov ah, 0x02
    mov al, 15
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [boot_drive]
    mov bx, 0x1000
    int 0x13
    jc .disk_error
    ret
.disk_error:
    PRINT msg_error
    hlt
    jmp $                       ; infinite loop at current address

print_string:
    pusha
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp short .loop
.done:
    popa
    ret

; Numbers in NASM's many formats
numbers:
    mov ax, 200                 ; decimal
    mov ax, 0200                ; still decimal
    mov ax, 0200d               ; explicitly decimal
    mov ax, 0d200               ; also decimal
    mov ax, 0c8h                ; hex with suffix (leading 0 required)
    mov ax, $0c8                ; hex with $ prefix
    mov ax, 0xc8                ; hex with 0x
    mov ax, 0hc8                ; hex with 0h
    mov ax, 310q                ; octal
    mov ax, 310o                ; octal
    mov ax, 0o310               ; octal
    mov ax, 0q310               ; octal
    mov ax, 11001000b           ; binary
    mov ax, 1100_1000y          ; binary with separator
    mov ax, 0b1100_1000         ; binary
    mov ax, 0y1100_1000         ; binary
    mov ax, 'AB'                ; character constant
    mov eax, "ABCD"             ; four-char constant
    mov eax, `\n\t\0`           ; backquoted with escapes
    dd 1.5, -3.25e+2, 1.e10, 0x1.8p+1, __float32__(2.5)
    dq 3.141592653589793, __Infinity__, __QNaN__

; Protected mode switch
gdt_start:
    dq 0x0
gdt_code:
    dw 0xFFFF, 0x0
    db 0x0, 10011010b, 11001111b, 0x0
gdt_data:
    dw 0xFFFF, 0x0
    db 0x0, 10010010b, 11001111b, 0x0
gdt_end:
gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start
CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

switch_to_pm:
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 0x1
    mov cr0, eax
    jmp CODE_SEG:init_pm

    bits 32
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov ebp, 0x90000
    mov esp, ebp
    mov byte [VIDEO_MEM * 16 + 0], 'X'
    mov dword [ebx + ecx*4 + 0x10], 0xDEADBEEF
    lea esi, [rel_data + eax*2]
    call kernel_main
    jmp $

    bits 64
long_mode:
    mov rax, qword [rel counter]
    mov rcx, 0x7FFF_FFFF_FFFF_FFFF
    vmovdqu ymm0, [rsi]
    vpaddd ymm1, ymm0, ymm0
    rep movsb
    lock cmpxchg [rdi], rdx
    syscall

%assign i 0
%rep 4
    db i
  %assign i i+1
%endrep

%if LATER > 1000
    times 2 nop
%elif LATER == 0
    %error "LATER must be non-zero"
%else
    nop
%endif

struc point
    .x: resd 1
    .y: resd 1
endstruc

origin: istruc point
    at point.x, dd 0
    at point.y, dd 0
iend

section .data
boot_drive  db 0
msg_hello   db "Hello from the boot sector!", NEWLINE, 0
msg_quotes  db 'single "with doubles"', `backquote \x41☺\e`, 0
msg_error   db "Disk read error; code=", '?', 0
msg_semi    db "a ; semicolon inside a string is not a comment", 0
counter     dq 0
rel_data    times 16 db 0xCC

section .bss
buffer      resb 256
stack       resq 128

    times 510 - ($ - $$) db 0
    dw 0xAA55
