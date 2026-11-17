//! The UART transport for the serial update engine. It reads time from the
//! CLINT.

const console = @import("../console/console.zig");
const clint = @import("../arch/riscv/clint.zig");
const soc = @import("soc");

// A transmitter that never reports empty must not stop the update.
const drain_limit_ms = 100;
const polls_per_clock_read = 64;

pub const Transport = struct {
    pub fn readByte(self: *Transport, ms: u32) ?u8 {
        // The UART holds one byte, so most polls must not read the clock.
        if (console.readByte()) |b| return b;
        const end = self.now() + ms;
        while (true) {
            for (0..polls_per_clock_read) |_| {
                if (console.readByte()) |b| return b;
            }
            if (self.now() >= end) return null;
        }
    }

    pub fn write(_: *Transport, bytes: []const u8) void {
        console.writeRaw(bytes);
    }

    pub fn drain(self: *Transport) void {
        const end = self.now() + drain_limit_ms;
        while (!console.txEmpty() and self.now() < end) {}
    }

    pub fn now(_: *Transport) u64 {
        const ticks_per_ms = comptime @max(1, soc.timebase_hz / 1000);
        return clint.time() / ticks_per_ms;
    }

    pub fn baudValid(_: *Transport, baud: u32) bool {
        return console.divisorFor(baud) != null;
    }

    pub fn setBaud(_: *Transport, baud: u32) bool {
        return console.setBaud(baud);
    }
};
