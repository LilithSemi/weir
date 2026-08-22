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

pub fn init() void {
    // River gates TX on a nonzero divisor, where baud = clock / divisor. It also
    // stalls on FCR/MCR writes, so bind with minimal_init. QEMU virt ignores the
    // divisor and accepts the full init, so this path serves both.
    dev = conduit.driver.ns16550a.bind(conduit.Mmio.direct(platform.uartBase()), .{
        .divisor = @intCast(soc.uart_clock / 115200),
        .minimal_init = true,
    });
    ws_out = dev.serial().writer(&out_buf);
    ws_err = dev.serial().writer(&err_buf);
    ws_in = dev.serial().reader(&in_buf);
}
