//! Memory bring-up for the first-stage boot loader. The log prefix names the
//! memory type from the controller's compatible ids. A Harbor SDR controller
//! has no calibration, so the boot loader only checks the array.
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

pub const MemoryType = enum { ddr3, sdr, unknown };

/// The memory type that the controller's compatible ids name. A tree that
/// does not name the type gives `unknown`.
pub fn memoryType(ids: []const []const u8) MemoryType {
    for (ids) |id| if (std.mem.eql(u8, id, "harbor,ddr3-sdram")) return .ddr3;
    for (ids) |id| if (std.mem.eql(u8, id, "harbor,sdr-sdram")) return .sdr;
    return .unknown;
}

/// The start of each log line of this module.
pub fn logPrefix(comptime kind: MemoryType) []const u8 {
    return comptime "[fsbl] " ++ switch (kind) {
        .ddr3 => "ddr3",
        .sdr => "sdr",
        .unknown => "ram",
    } ++ ": ";
}

/// The line for a controller that the boot loader does not train.
pub fn readyLine(comptime kind: MemoryType) []const u8 {
    return comptime logPrefix(kind) ++ switch (kind) {
        // The controller calibrates itself and holds the first access until
        // calibration is complete.
        .ddr3 => "hardware-calibrated",
        .sdr => "no calibration needed",
        .unknown => "ready",
    } ++ "\n";
}

const memory_type = memoryType(cfg.sdram_ids);
const prefix = logPrefix(memory_type);

test "the ulx3s controller is sdr sdram" {
    const ids = [_][]const u8{ "harbor,sdram-controller", "harbor,sdr-sdram" };
    try std.testing.expectEqual(MemoryType.sdr, memoryType(&ids));
    try std.testing.expectEqualStrings("[fsbl] sdr: no calibration needed\n", readyLine(.sdr));
    try std.testing.expectEqualStrings("[fsbl] sdr: ", logPrefix(.sdr));
}

test "the arty controller is ddr3 sdram" {
    const ids = [_][]const u8{ "harbor,sdram-controller", "harbor,ddr3-sdram" };
    try std.testing.expectEqual(MemoryType.ddr3, memoryType(&ids));
    try std.testing.expectEqualStrings("[fsbl] ddr3: hardware-calibrated\n", readyLine(.ddr3));
    try std.testing.expectEqualStrings("[fsbl] ddr3: ", logPrefix(.ddr3));
}

test "a controller that does not name its type gives a neutral prefix" {
    const generic = [_][]const u8{"harbor,sdram-controller"};
    try std.testing.expectEqual(MemoryType.unknown, memoryType(&generic));
    try std.testing.expectEqual(MemoryType.unknown, memoryType(&.{}));
    try std.testing.expectEqualStrings("[fsbl] ram: ready\n", readyLine(.unknown));
    try std.testing.expectEqualStrings("[fsbl] ram: ", logPrefix(.unknown));
}

test "ddr3 wins when a controller lists both types" {
    const ids = [_][]const u8{ "harbor,sdr-sdram", "harbor,ddr3-sdram" };
    try std.testing.expectEqual(MemoryType.ddr3, memoryType(&ids));
}

/// The middle and top-of-array probe addresses, as a pure function of the
/// usable DRAM range. `size` must already exclude any knob window (the device
/// tree size does, on a `train=runtime` build), so `top` never lands inside it.
fn memtestBounds(base: usize, size: usize) struct { mid: usize, top: usize, near_top: usize } {
    const top = base + size;
    return .{ .mid = base + ((size / 2) & ~@as(usize, 7)), .top = top, .near_top = top - 0x100 };
}

test "memtest probes stay inside a 32 MiB array" {
    const base: usize = 0x80000000;
    const size: usize = 32 * 1024 * 1024;
    const bounds = memtestBounds(base, size);
    for ([_]usize{ bounds.mid, bounds.near_top, bounds.top - 8 }) |a| {
        try std.testing.expect(a >= base and a + 8 <= base + size);
        try std.testing.expect(a % 8 == 0);
    }
}

test "memtest bounds stay clear of a 128 MB OrangeCrab knob window" {
    const base: usize = 0x90000000;
    const full_size: usize = 128 * 1024 * 1024;
    const window_size: usize = 0x1000;
    const window_base = base + full_size - window_size;
    // train=runtime: the device tree's size already excludes the window.
    const bounds = memtestBounds(base, full_size - window_size);
    try std.testing.expect(bounds.top <= window_base);
    try std.testing.expect(bounds.near_top < window_base);
}

/// Write and read back known patterns across the DRAM array. Returns true when
/// every check matches. Three passes cover the ways the boot loader uses DRAM:
/// sequential words at the base, 64-bit read-after-write at the low and high
/// ends of the window, and a nested push/pop near the top (the stack region).
pub fn memtest(con: *std.Io.Writer) bool {
    const b = cfg.dram_base;
    // Top of the usable array. On a `train=runtime` build the device tree's
    // size already excludes the knob window, so this never probes it.
    const bounds = memtestBounds(b, cfg.dram_size);
    const top = bounds.top;
    const near_top = bounds.near_top;
    // (1) sequential 32-bit words at the base
    var e1: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) @as(*volatile u32, @ptrFromInt(b + i * 4)).* = 0xC0DE0000 | i;
    i = 0;
    while (i < 256) : (i += 1) {
        const got = @as(*volatile u32, @ptrFromInt(b + i * 4)).*;
        if (got != (0xC0DE0000 | i)) e1 += 1;
    }
    // (2) 64-bit read-after-write at LOW + HIGH addresses (near the top of
    // the usable array, the stack region)
    var e2: u32 = 0;
    const addrs = [_]usize{ b, b + 0x1000, bounds.mid, near_top, top - 8 };
    for (addrs) |a| {
        const v: u64 = 0xDEADBEEF_00000000 | @as(u64, @intCast(a & 0xFFFFFFFF));
        @as(*volatile u64, @ptrFromInt(a)).* = v;
        if (@as(*volatile u64, @ptrFromInt(a)).* != v) e2 += 1; // read immediately after write
    }
    // (3) nested push/pop (stack pattern) near the top of the window
    var e3: u32 = 0;
    var sp: usize = near_top;
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
    con.writeAll(prefix ++ "memtest seq32=") catch {};
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
        con.writeAll(prefix ++ "runtime training\n") catch {};
        if (!ddr_train.trainController(con, d, cfg.dram_base, memtest)) {
            con.writeAll(prefix ++ "training failed\n") catch {};
            return false;
        }
        con.writeAll(prefix ++ "training complete\n") catch {};
        return true;
    }

    // No runtime training. A DDR3 controller calibrated itself and stalled the
    // first access until it was ready. An SDR controller has no calibration.
    // Only the array check remains.
    con.writeAll(readyLine(memory_type)) catch {};
    return memtest(con);
}
