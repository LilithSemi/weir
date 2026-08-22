//! DDR3 bring-up for the first-stage boot loader.
//!
//! The Harbor DDR3 controller runs the JEDEC power-up and initialisation
//! sequence in hardware. It supports two calibration modes, chosen when genip
//! builds the SoC:
//!
//!   - Hardware calibration (train=hw). The controller calibrates itself in
//!     hardware and holds the first bus access until calibration is complete.
//!     The boot loader does no training. It only checks the array.
//!
//!   - Runtime training (train=runtime). The controller exposes a knob window
//!     and genip adds a `training` node to the device tree. The boot loader
//!     sweeps the knobs at boot to find a working setting. The training module
//!     `ddr_train.zig` holds the knob protocol and does this work.
//!
//! In both modes the array is verified with `memtest`, which writes and reads
//! back known patterns. `init` returns true only when the array is good,
//! because the boot loader must not run code from an unverified DRAM.

const std = @import("std");
const cfg = @import("config.zig");
const ddr_train = @import("ddr_train.zig");

/// Write and read back known patterns across the DRAM array. Returns true when
/// every check matches. Three passes cover the ways the boot loader uses DRAM:
/// sequential words at the base, 64-bit read-after-write at the low and high
/// ends of the window, and a nested push/pop near the top (the stack region).
pub fn memtest(con: *std.Io.Writer) bool {
    const b = cfg.dram_base;
    // (1) sequential 32-bit words at the base
    var e1: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) @as(*volatile u32, @ptrFromInt(b + i * 4)).* = 0xC0DE0000 | i;
    i = 0;
    while (i < 256) : (i += 1) {
        const got = @as(*volatile u32, @ptrFromInt(b + i * 4)).*;
        if (got != (0xC0DE0000 | i)) e1 += 1;
    }
    // (2) 64-bit read-after-write at LOW + HIGH addresses (top of 128MB = stack region)
    var e2: u32 = 0;
    const addrs = [_]usize{ b, b + 0x1000, b + 0x04000000, b + 0x07FF_FF00, b + 0x07FF_FFF8 };
    for (addrs) |a| {
        const v: u64 = 0xDEADBEEF_00000000 | @as(u64, @intCast(a & 0xFFFFFFFF));
        @as(*volatile u64, @ptrFromInt(a)).* = v;
        if (@as(*volatile u64, @ptrFromInt(a)).* != v) e2 += 1; // read immediately after write
    }
    // (3) nested push/pop (stack pattern) near the top of the window
    var e3: u32 = 0;
    var sp: usize = b + 0x07FF_FF00;
    var vals: [16]u64 = undefined;
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        sp -= 8;
        vals[k] = 0xABCD_0000 + k;
        @as(*volatile u64, @ptrFromInt(sp)).* = vals[k];
    }
    k = 16;
    while (k > 0) {
        k -= 1;
        if (@as(*volatile u64, @ptrFromInt(sp)).* != vals[k]) e3 += 1;
        sp += 8;
    }
    con.writeAll("[fsbl] ddr: memtest seq32=") catch {};
    con.print("{X:0>8}", .{e1}) catch {};
    con.writeAll(" rw64=") catch {};
    con.print("{X:0>8}", .{e2}) catch {};
    con.writeAll(" stack=") catch {};
    con.print("{X:0>8}", .{e3}) catch {};
    con.writeByte('\n') catch {};
    return (e1 + e2 + e3) == 0;
}

/// Bring up DRAM and verify it. Dispatches on the calibration mode the SoC was
/// built with, then checks the array. Returns false when the array is bad, so
/// the caller does not run from unusable memory.
pub fn init(con: *std.Io.Writer) bool {
    // Runtime training mode. genip built the controller with train=runtime, so
    // it added a `training` device-tree node that ddr_train reads at comptime.
    // Sweep the knob window (ddr_train verifies each setting with memtest).
    if (ddr_train.desc) |*d| {
        con.writeAll("[fsbl] ddr: runtime training\n") catch {};
        if (!ddr_train.trainController(con, d, cfg.dram_base, memtest)) {
            con.writeAll("[fsbl] ddr: training failed\n") catch {};
            return false;
        }
        con.writeAll("[fsbl] ddr: training complete\n") catch {};
        return true;
    }

    // Hardware calibration mode. The controller calibrated itself and stalled
    // the first access until it was ready, so only the array check remains.
    con.writeAll("[fsbl] ddr: hardware-calibrated\n") catch {};
    return memtest(con);
}
