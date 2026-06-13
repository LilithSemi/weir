//! SoC parameters read from an embedded device tree at comptime (via dtree).
//!
//! For River, Harbor emits the SoC tree; pass it with -Ddtb and Weir reads
//! peripheral addresses here at comptime, avoiding a pile of -D address options.
//! The same tree drives the linker base (build.zig), so layout and link address
//! stay in sync. With no -Ddtb (QEMU virt default) these fall back to the common
//! addresses; runtime discovery (platform.zig) still adapts to QEMU's live DTB.

const std = @import("std");
const dtree = @import("conduit").dtree;
const has_dt = @import("build_options").has_dtb;

const QUOTA = 2_000_000;

fn reader() dtree.Reader {
    @setEvalBranchQuota(QUOTA);
    return dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch @compileError("soc_dtb: invalid device tree");
}

/// Is `want` one of the NUL-separated strings in a `compatible` value?
fn hasCompatible(value: []const u8, want: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        const s = std.mem.sliceTo(value[i..], 0);
        if (std.mem.eql(u8, s, want)) return true;
        i += s.len + 1;
    }
    return false;
}

const Match = struct {
    /// Match a node whose name starts with this (e.g. "memory" for memory@...).
    name: ?[]const u8 = null,
    /// Match a node carrying this `compatible` string.
    compatible: ?[]const u8 = null,
};

/// Read a `reg` cell from the first node matching `m`: cell 0 is the base, cell 1
/// the size. Comptime. Only ever called when a tree is embedded.
fn regCell(comptime m: Match, comptime want_size: bool) ?usize {
    @setEvalBranchQuota(QUOTA);
    var iter = reader().nodeIterator();
    var matched = false;
    var value: ?usize = null;
    while (iter.next() catch return null) |node| {
        switch (node) {
            .begin => |b| {
                matched = if (m.name) |nm| std.mem.startsWith(u8, b.name, nm) else false;
                value = null;
            },
            .prop => |pr| {
                if (m.compatible) |c| {
                    if (std.mem.eql(u8, pr.name, "compatible") and hasCompatible(pr.value, c)) matched = true;
                }
                if (std.mem.eql(u8, pr.name, "reg")) {
                    if (want_size) {
                        if (pr.value.len >= 16) value = std.mem.readInt(u64, pr.value[8..16], .big);
                    } else {
                        if (pr.value.len >= 8) value = std.mem.readInt(u64, pr.value[0..8], .big);
                    }
                }
            },
            .end => {},
        }
        if (matched) if (value) |v| return v;
    }
    return null;
}

// Comptime-pruned when no tree is embedded, so @embedFile is never required then.
fn regBase(comptime m: Match) ?usize {
    return if (has_dt) regCell(m, false) else null;
}
fn regSize(comptime m: Match) ?usize {
    return if (has_dt) regCell(m, true) else null;
}

/// Read a named big-endian u32 property (e.g. clock-frequency) from the first
/// node matching `m`. Comptime.
fn propU32(comptime m: Match, comptime pname: []const u8) ?u32 {
    @setEvalBranchQuota(QUOTA);
    var iter = reader().nodeIterator();
    var matched = false;
    var value: ?u32 = null;
    while (iter.next() catch return null) |node| {
        switch (node) {
            .begin => |b| {
                matched = if (m.name) |nm| std.mem.startsWith(u8, b.name, nm) else false;
                value = null;
            },
            .prop => |pr| {
                if (m.compatible) |c| {
                    if (std.mem.eql(u8, pr.name, "compatible") and hasCompatible(pr.value, c)) matched = true;
                }
                if (std.mem.eql(u8, pr.name, pname)) {
                    if (pr.value.len >= 4) value = std.mem.readInt(u32, pr.value[0..4], .big);
                }
            },
            .end => {},
        }
        if (matched) if (value) |v| return v;
    }
    return null;
}

// Peripheral addresses, read once at comptime. Fall back to QEMU virt / common
// values when no tree is embedded or it omits a node.
pub const ram_base: usize = regBase(.{ .name = "memory" }) orelse 0x80000000;
pub const ram_size: usize = regSize(.{ .name = "memory" }) orelse 0x10000000;
pub const uart_base: usize = regBase(.{ .compatible = "ns16550a" }) orelse 0x10000000;
/// UART input clock (Hz). River/Harbor's UART gates TX on a nonzero divisor
/// (baud = clock/divisor), so the driver must program it; QEMU virt ignores it.
pub const uart_clock: usize =
    (if (has_dt) propU32(.{ .compatible = "ns16550a" }, "clock-frequency") else null) orelse 12000000;
pub const clint_base: usize = regBase(.{ .compatible = "riscv,clint0" }) orelse 0x2000000;

// On-chip SRAM the FSBL runs from, and the XIP SPI flash holding the main image.
// Defaults match the River OrangeCrab target.
pub const sram_base: usize = regBase(.{ .name = "sram", .compatible = "mmio-sram" }) orelse 0x80000000;
pub const flash_base: usize = regBase(.{ .name = "flash", .compatible = "jedec,spi-nor" }) orelse 0x20000000;

// TPM (Albion's secure element): presence and base from the tree.
const tpm_reg = regBase(.{ .compatible = "tcg,tpm-tis-mmio" });
pub const tpm_present: bool = tpm_reg != null;
pub const tpm_base: usize = tpm_reg orelse 0x04000000;

// DDR read-training control window: it sits just above the controller's array,
// so it is the DDR controller node's base + size. Zero means no CPU training.
const ddr_base = regBase(.{ .compatible = "harbor,ddr3-sdram" });
const ddr_size = regSize(.{ .compatible = "harbor,ddr3-sdram" });
pub const ddr_train_base: usize = if (ddr_base != null and ddr_size != null) ddr_base.? + ddr_size.? else 0;
