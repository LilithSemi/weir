//! Control and status register access. The register name is comptime so the
//! assembler encodes it directly.

pub inline fn read(comptime name: []const u8) usize {
    return asm volatile ("csrr %[v], " ++ name
        : [v] "=r" (-> usize),
    );
}

pub inline fn write(comptime name: []const u8, value: usize) void {
    asm volatile ("csrw " ++ name ++ ", %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn set(comptime name: []const u8, mask: usize) void {
    asm volatile ("csrs " ++ name ++ ", %[v]"
        :
        : [v] "r" (mask),
        : .{ .memory = true });
}

pub inline fn clear(comptime name: []const u8, mask: usize) void {
    asm volatile ("csrc " ++ name ++ ", %[v]"
        :
        : [v] "r" (mask),
        : .{ .memory = true });
}
