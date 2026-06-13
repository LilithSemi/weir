//! NS16550A UART. Thin adapter over conduit's ns16550a driver, keeping Weir's
//! `Ns16550a{ .base }` shape so the console and FSBL use it unchanged while the
//! register logic lives once, in conduit.

const conduit = @import("conduit");

pub const Ns16550a = struct {
    base: usize,
    /// Baud divisor (DLL/DLM) to program at init. River/Harbor's UART gates TX on
    /// a nonzero divisor (baud = clock/divisor), so callers set this from
    /// soc.uart_clock; 0 leaves the platform default (QEMU virt ignores it).
    divisor: u16 = 0,

    fn dev(self: Ns16550a) conduit.driver.ns16550a.Ns16550a {
        return .{ .mmio = conduit.Mmio.direct(self.base), .divisor = self.divisor };
    }

    pub fn init(self: Ns16550a) void {
        self.dev().init();
    }

    pub fn putc(self: Ns16550a, c: u8) void {
        self.dev().putc(c);
    }

    pub fn writeStr(self: Ns16550a, s: []const u8) void {
        self.dev().write(s);
    }
};
