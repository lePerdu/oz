.code64
.section .text.start

.global _start
_start:
    jmp main

.global _setCodeSegmentRegister
_setCodeSegmentRegister:
    /* di = segment selector */
    push %rdi
    lea _reload_cs, %rax
    push %rax
    lretq
_reload_cs:
    ret
