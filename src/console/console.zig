//! Global firmware console over the platform UART.
//!
//! The console binds conduit's ns16550a driver and exposes conduit `std.Io`
//! streams over it, like EDK II's ConOut, StdErr, and ConIn: `out` for normal
//! status, `err` for failures, and `input` for serial input. The streams reach
//! the one UART today, but a caller picks a stream by intent, so `err` can
//! divert later. Write through `out`/`err` (`out.print`, `err.writeAll`); read
//! through `input`. The writers are unbuffered, so every byte reaches the UART
//! at once and a message survives a later hang. The reader never blocks: it
//! returns the bytes waiting now, or none.

const std = @import("std");
const conduit = @import("conduit");
const platform = @import("../platform.zig");
const soc = @import("soc");

// The console UART and a conduit std.Io stream for each direction. init() fills
// them before any use, so `undefined` never reaches a read.
// zippy:ignore unsafe_undefined
var dev: conduit.driver.ns16550a.Ns16550a = undefined;
// zippy:ignore unsafe_undefined
var ws_out: conduit.device.Serial.Writer = undefined;
// zippy:ignore unsafe_undefined
var ws_err: conduit.device.Serial.Writer = undefined;
// zippy:ignore unsafe_undefined
var ws_in: conduit.device.Serial.Reader = undefined;

// Empty buffers: the writers send every write at once with no pending tail, and
// the reader reflects the UART state at the instant it is read.
var out_buf: [0]u8 = .{};
var err_buf: [0]u8 = .{};
var in_buf: [0]u8 = .{};

/// Normal status output. Valid only after `init`.
pub const out: *std.Io.Writer = &ws_out.interface;
/// Failure output. Valid only after `init`.
pub const err: *std.Io.Writer = &ws_err.interface;
/// Serial input. Non-blocking: a read returns the waiting bytes, or none. Valid
/// only after `init`.
pub const input: *std.Io.Reader = &ws_in.interface;

const default_divisor: u16 = soc.uartDivisor(115200) orelse
    @compileError("the UART clock is too low for 115200 baud");

pub fn init() void {
    // River sends nothing while the divisor is 0. The init also turns on the
    // FIFOs. QEMU virt ignores the divisor.
    dev = conduit.driver.ns16550a.bind(conduit.Mmio.direct(platform.uartBase()), .{
        .divisor = default_divisor,
    });
    ws_out = dev.serial().writer(&out_buf);
    ws_err = dev.serial().writer(&err_buf);
    ws_in = dev.serial().reader(&in_buf);
}

const lsr = 5;
const lsr_temt = 0x40;

/// Returns one received byte, or null when no byte waits. Only the serial
/// update mode reads the UART this way.
pub fn readByte() ?u8 {
    var b: [1]u8 = undefined;
    return if (dev.read(&b) == 1) b[0] else null;
}

/// Sends `bytes` with no LF to CRLF change.
pub fn writeRaw(bytes: []const u8) void {
    for (bytes) |c| dev.putc(c);
}

/// True when the transmitter has sent all of its bytes.
pub fn txEmpty() bool {
    return dev.mmio.read(u8, lsr) & lsr_temt != 0;
}

/// The divisor for `baud`, or null when no divisor fits.
pub fn divisorFor(baud: u32) ?u16 {
    return soc.uartDivisor(baud);
}

/// Programs a new rate. It does not reset the FIFOs, so a byte that the host
/// sent early stays. Returns false and keeps the rate for a bad baud.
pub fn setBaud(baud: u32) bool {
    const div = divisorFor(baud) orelse return false;
    dev = conduit.driver.ns16550a.bind(conduit.Mmio.direct(platform.uartBase()), .{
        .divisor = div,
        .minimal_init = true,
    });
    return true;
}
