ENTRY(_start)

fb = 0xFFFFFFFFFC000000;
bootinfo = 0xFFFFFFFFFFE00000;

PHDRS {
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    ap_trampoline PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS {
    . = 0xFFFFFFFFFFE02000;
    _kernel_start = .;

    .text : {
        *(.text.start);
        *(.text*);
    } :text

    .rodata : ALIGN(4096) { *(.rodata*); } :rodata
    .eh_frame : { *(.eh_frame); }
    .eh_frame_hdr : { *(.eh_frame_hdr); }

    .data : ALIGN(4096) {
        *(.data*);
        *(.bss*);
        *(COMMON);
    } :data
    .got : { *(.got); }

    /* TODO: Figure out how to move this next to .rodata (since it's also read-only) */
    _ap_trampoline = .;
    .ap_trampoline 0x8000 : AT(_ap_trampoline) ALIGN(4096) {
        *(.ap_trampoline);
    } :ap_trampoline
    . = _ap_trampoline + SIZEOF(.ap_trampoline);
    _ap_trampoline_end = .;

    _kernel_end = .;
}
