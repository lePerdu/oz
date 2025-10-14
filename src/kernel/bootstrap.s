.section .text.start

.global _start
_start:
    .code64
    jmp main

.global _setCodeSegmentRegister
_setCodeSegmentRegister:
    .code64
    /* di = segment selector */
    push %rdi
    lea _reload_cs, %rax
    push %rax
    lretq
_reload_cs:
    ret
