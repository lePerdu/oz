pub inline fn inb(port: u16) u8 {
    return asm ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn inbComptimePort(comptime port: u8) u8 {
    return asm ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N" (port),
    );
}

pub inline fn insb(port: u16, buf: []u8) void {
    const buf_ptr = buf.ptr;
    asm (
        \\cld
        \\rep insb
        : // TODO: Figure out syntax for secifying what memory is written
          [data] "=*m" (buf_ptr),
        : [port] "{dx}" (port),
          [buf] "{rdi}" (buf_ptr),
          [count] "{rcx}" (buf.len),
        : .{ .rcx = true, .rdi = true, .cc = true });
}

pub inline fn outb(port: u16, byte: u8) void {
    asm volatile ("outb %[byte], %[port]"
        : // No outputs
        : [port] "{dx}" (port),
          [byte] "{al}" (byte),
    );
}

pub inline fn outbComptimePort(comptime port: u8, byte: u8) void {
    asm volatile ("outb %[byte], %[port]"
        : // No outputs
        : [byte] "{al}" (byte),
          [port] "N" (port),
    );
}

pub inline fn outsb(port: u16, buf: []const u8) void {
    asm volatile (
        \\cld
        \\rep outsb
        : // no outputs
        : [port] "{dx}" (port),
          [buf] "{rsi}" (buf.ptr),
          [count] "{rcx}" (buf.len),
          // TODO: Figure out syntax for specifying what memory is read
          [data] "*m" (buf.ptr),
        : .{ .rcx = true, .rsi = true, .cc = true });
}
