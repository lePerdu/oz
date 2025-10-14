.section .ap_trampoline, "a", @progbits

.set CR0_PE, 1
.set CR0_MP, 1 << 1
.set CR0_NE, 1 << 5
.set CR0_WP, 1 << 16
.set CR0_NW, 1 << 29
.set CR0_CD, 1 << 30
.set CR0_PG, 1 << 31

.set CR4_PAE, 1 << 5
.set CR4_OSFXSR, 1 << 9
.set CR4_OSXMMEXCPT, 1<<10

.set IA32_EFER, 0xC0000080
.set EFER_LME, 1 << 8
.set EFER_NXE, 1 << 11

ap_trampoline:
    .code16
    cli
    xor %ax, %ax
    mov %ax, %ds
    lgdt _gdtr
    mov %cr0, %eax
    or $CR0_PE, %eax
    mov %eax, %cr0
    ljmp $0x08, $_protected_mode

_protected_mode:
    .code32
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %ss
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs

    # TODO: Check cpuid before enabling SSE
    # TODO: More thorough setting of CR* registers so they are the same between BSP and APs
    mov %cr4, %eax
    or $(CR4_PAE | CR4_OSFXSR | CR4_OSXMMEXCPT), %eax
    mov %eax, %cr4

    mov _ap_arg_cr3, %eax
    mov %eax, %cr3

    mov $IA32_EFER, %ecx
    rdmsr
    or $(EFER_LME | EFER_NXE), %eax
    wrmsr

    mov %cr0, %eax
    or $(CR0_PG | CR0_MP | CR0_WP | CR0_NE), %eax
    and $(~CR0_CD & ~CR0_NW), %eax
    mov %eax, %cr0

    # Set CS
    ljmpl $0x18, $_long_mode

_long_mode:
    .code64
    mov $0x20, %ax
    mov %ax, %ds
    mov %ax, %ss
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs

    mov _ap_arg_sp, %rsp
    # TODO: jmp apMain assemblers, but does it compile "correctly"
    jmp apMain

_gdtr:
    .short _gdt_end - _gdt - 1
    .long _gdt

.align 16
_gdt:
.quad 0 /* Null */
.quad 0x00cf9a000000ffff /* 4GB kernel code segment */
.quad 0x00cf92000000ffff /* 4GB kernel data segment */
.quad 0x00209a0000000000 /* 64-bit kernel code segment */
.quad 0x0000920000000000 /* 64-bit kernel data segment */
/* TODO: TSS? */
_gdt_end:

# "arguments" that need to be set by the BSP

.align 8
.global _ap_arg_sp
_ap_arg_sp:
    .quad 0

.align 4
.global _ap_arg_cr3
_ap_arg_cr3:
    .long 0

.global _ap_arg_gdtr
_ap_arg_gdtr:
    .short 0
    .quad 0
