.section .text.start
.code64

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

.set IA32_PAT, 0x277
.set PAT_UC, 0
.set PAT_WC, 1
.set PAT_WT, 4
.set PAT_WP, 5
.set PAT_WB, 6
.set PAT_UC_, 7

.set PAT_LSB, (PAT_UC << 24) | (PAT_UC_ << 16) | (PAT_WT << 8) | PAT_WB
.set PAT_MSB, (PAT_WC << 24) | (PAT_WC << 16) | (PAT_WP << 8) | PAT_WP

.set CR0_CD, 1 << 30

.global _configurePat
_configurePat:
    mov %cr0, %rbx
    or $CR0_CD, %rbx
    mov %rbx, %cr0

    wbinvd

    mov $PAT_LSB, %eax
    mov $PAT_MSB, %edx
    mov $IA32_PAT, %ecx
    wrmsr

    and $~CR0_CD, %rbx
    mov %rbx, %cr0

    mov %cr3, %rax
    mov %rax, %cr3
    ret
