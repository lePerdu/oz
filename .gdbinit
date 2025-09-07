target remote localhost:1234
add-symbol-file zig-out/bin/ozkernel.debug.elf
break main
break debug.panic
watch *(unsigned long *)0x10000 == 0xDEADBEEF
layout split
continue
