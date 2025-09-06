ENTRY(_start)

fb = 0xFFFFFFFFFC000000;
bootboot = 0xFFFFFFFFFFE00000;

SECTIONS {
    . = 0xFFFFFFFFFFE02000;
    _kernel_start = .;

    .text.start : {
        _kernel_startup_start = .;
        *(.text.start);
        _kernel_startup_end = .;
    }
    .text : {
        _kernel_text_start = .;
        *(.text*);
        _kernel_text_end = .;
    }

    .rodata : {
        _kernel_rodata_start = .;
        *(.rodata*);
        _kernel_rodata_end = .;
    }
    .eh_frame : {
        _kernel_eh_frame_start = .;
        *(.eh_frame);
        _kernel_eh_frame_end = .;
    }
    .eh_frame_hdr : {
        _kernel_eh_frame_hdr_start = .;
        *(.eh_frame_hdr);
        _kernel_eh_frame_hdr_end = .;
    }

    .data : {
        _kernel_data_start = .;
        *(.data*);
        _kernel_data_end = .;
    }
    .bss : {
        _kernel_bss_start = .;
        *(COMMON);
        *(.bss*);
        _kernel_bss_end = .;
    }

    _kernel_end = .;
}
