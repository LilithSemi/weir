//! Runtime platform discovery.
//!
//! Peripherals are found by what they ARE (device-tree `compatible`), reading
//! base addresses from the DTB the platform hands us, so one binary works on
//! QEMU virt and any Harbor-generated River SoC. The defaults below are only a
//! fallback for a platform that gives no usable device tree.

const std = @import("std");
const conduit = @import("conduit");
const fdt = @import("fdt/fdt.zig");
const console = @import("console/console.zig");
const soc = @import("soc");

// Device-class peripherals go through conduit's Registry. Non-device bits (reset
// controller, TPM presence) stay on raw FDT lookups since conduit models device
// classes, not arbitrary SoC params.
const matchers = [_]conduit.Matcher{
    .{ .class = .uart, .dt_compatible = &.{ "ns16550a", "ns16550", "snps,dw-apb-uart" } },
    .{ .class = .timer, .dt_compatible = &.{ "riscv,clint0", "sifive,clint0", "thead,c900-clint" } },
    .{ .class = .block, .dt_compatible = &.{ "harbor,sdhci", "harbor,sdio" } },
};

// Defaults from the embedded SoC tree (soc.zig, comptime); discover() overrides
// them from a runtime DTB. `*_found` records whether the live tree described it.
var uart_base_v: usize = soc.uart_base;
var clint_base_v: usize = soc.clint_base;
var reset_base_v: usize = 0x100000;

var uart_found = false;
var clint_found = false;
var reset_found = false;

// Probe a TPM only if the platform advertises one; probing a fixed address blind
// faults on a bus with no device mapped. Base is the QEMU virt platform-bus TIS;
// River/Albion's secure element reports its own.
// TODO: proper bus-ranges translation once that interface is known.
var tpm_present_v = false;
var tpm_base_v: usize = 0x04000000;

// Harbor SDHCI SD/MMC host, discovered from the DTB. Used as the block device on
// River, where QEMU would have virtio-blk.
var sdhci_base_v: usize = 0;
var sdhci_freq_v: u32 = 50_000_000;

/// Populate peripheral addresses from the device tree at `dtb`. Safe to call
/// with dtb == 0 (keeps the defaults). Idempotent.
pub fn discover(dtb: usize) void {
    if (dtb == 0) return;

    // Device-class peripherals via conduit. The FDT header's totalsize
    // (big-endian u32 at offset 4) bounds the blob.
    const p: [*]const u8 = @ptrFromInt(dtb);
    const total = std.mem.readInt(u32, p[4..8], .big);
    if (conduit.dtree.Reader.initBuffer(p[0..total])) |reader| {
        var rd = reader;
        var be = conduit.backend.dtree.DtBackend.init(&rd);
        const registry = conduit.Registry.init(be.any(), &matchers);
        if (registry.find(.uart) catch null) |m| if (m.mmio()) |r| {
            uart_base_v = @intCast(r.base);
            uart_found = true;
        };
        if (registry.find(.timer) catch null) |m| if (m.mmio()) |r| {
            clint_base_v = @intCast(r.base);
            clint_found = true;
        };
        if (registry.find(.block) catch null) |m| if (m.mmio()) |r| {
            sdhci_base_v = @intCast(r.base);
        };
    } else |_| {}

    // Reset controller and TPM presence aren't device classes, so raw FDT lookups.
    // The TIS reg under QEMU's platform bus is bus-relative, so TPM is
    // presence-only here and uses the known base.
    if (fdt.findCompatibleReg(dtb, &.{ "sifive,test0", "sifive,test1", "syscon" })) |a| {
        reset_base_v = @intCast(a);
        reset_found = true;
    }
    if (fdt.findCompatibleReg(dtb, &.{ "tcg,tpm-tis-mmio", "tcg,tpm-tis" })) |_| {
        tpm_present_v = true;
    }
    if (sdhci_base_v != 0) {
        if (fdt.findCompatibleProp(dtb, &.{ "harbor,sdhci", "harbor,sdio" }, "clock-frequency")) |f| sdhci_freq_v = f;
    }
}

pub fn sdhciBase() usize {
    return sdhci_base_v;
}

pub fn sdhciFreq() u32 {
    return sdhci_freq_v;
}

pub fn tpmPresent() bool {
    return tpm_present_v;
}

pub fn tpmBase() usize {
    return tpm_base_v;
}

fn src(found: bool) []const u8 {
    return if (found) "dtb" else "default";
}

/// Print the resolved peripheral map (needs the console up).
pub fn report() void {
    console.printf("[plat] uart @ {x} ({s}), clint @ {x} ({s}), reset @ {x} ({s})\n", .{
        uart_base_v,  src(uart_found),
        clint_base_v, src(clint_found),
        reset_base_v, src(reset_found),
    });
}

pub fn uartBase() usize {
    return uart_base_v;
}

pub fn clintBase() usize {
    return clint_base_v;
}

pub fn resetBase() usize {
    return reset_base_v;
}
