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
        // River/Harbor's minimal ns16550a does NOT ack bus writes to FCR (offset 2)
        // or MCR (offset 4); conduit's init() writes both, which stalls the CPU store
        // forever (the FSBL hung silently inside con.init(), HW-localised 2026-07-02).
        // Program only the registers the core implements: LCR + the DLL/DLM divisor
        // (baud = clock/divisor; River gates TX until a nonzero divisor is latched).
        // Byte-wide regs (reg-shift 0).
        const b = self.base;
        if (self.divisor != 0) {
            @as(*volatile u8, @ptrFromInt(b + 3)).* = 0x83; // LCR: DLAB=1, 8N1
            @as(*volatile u8, @ptrFromInt(b + 0)).* = @truncate(self.divisor & 0xff); // DLL
            @as(*volatile u8, @ptrFromInt(b + 1)).* = @truncate((self.divisor >> 8) & 0xff); // DLM
        }
        @as(*volatile u8, @ptrFromInt(b + 3)).* = 0x03; // LCR: DLAB=0, 8N1 (latch divisor)
    }

    // Direct volatile MMIO (NOT conduit's Mmio abstraction, which stalled River's
    // UART bus - HW 2026-07-02). Poll THRE (LSR bit 0x20) then write THR (offset 0).
    pub fn putc(self: Ns16550a, c: u8) void {
        const b = self.base;
        while ((@as(*volatile u8, @ptrFromInt(b + 5)).* & 0x20) == 0) {}
        @as(*volatile u8, @ptrFromInt(b + 0)).* = c;
    }

    pub fn writeStr(self: Ns16550a, s: []const u8) void {
        for (s) |c| {
            if (c == '\n') self.putc('\r'); // LF -> CRLF (console convention)
            self.putc(c);
        }
    }
};
