//! Global firmware console over the platform UART.

const std = @import("std");
const uart = @import("uart.zig");
const platform = @import("../platform.zig");

// Defaults to the common location; main() runs platform.discover() before
// console.init(), so init() picks up a device-tree-provided UART address.
var dev = uart.Ns16550a{ .base = 0x10000000 };

pub fn init() void {
    dev.base = platform.uartBase();
    dev.init();
}

pub fn writeStr(s: []const u8) void {
    dev.writeStr(s);
}

pub fn putc(c: u8) void {
    dev.putc(c);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        dev.writeStr("[weir: console format overflow]\n");
        return;
    };
    dev.writeStr(s);
}
