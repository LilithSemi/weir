//! Platform peripheral map.
//!
//! Every device address bakes in at comptime from the embedded device tree. See
//! soc.zig and conduit's Builder. There is no runtime device lookup. The
//! addresses are known at compile time, so boot pays zero discovery cost. This
//! module is a thin typed accessor over those comptime constants.

const console = @import("console/console.zig");
const soc = @import("soc");

/// Discovery is comptime through soc.zig and conduit, so there is nothing to do
/// at runtime. This stub stays so call sites need not change.
pub fn discover(dtb: usize) void {
    _ = dtb;
}

/// Print the resolved peripheral map. The console must be up first.
pub fn report() void {
    console.out.print("[plat] uart @ {x}, clint @ {x}, ram @ {x} (+{x}), flash @ {x}\n", .{
        soc.uart_base, soc.clint_base, soc.ram_base, soc.ram_size, soc.flash_base,
    }) catch {};
    console.out.print("[plat] timebase {d} Hz\n", .{soc.timebase_hz}) catch {};
    // A guessed timebase scales every delay Weir computes and the rate it
    // reports to the OS, so it never passes silently.
    if (!soc.timebase_known) console.out.writeAll(
        "[plat] WARNING: no timebase-frequency in the platform description. " ++
            "Using the QEMU virt rate, which is wrong on real hardware.\n",
    ) catch {};
}

pub fn uartBase() usize {
    return soc.uart_base;
}
pub fn clintBase() usize {
    return soc.clint_base;
}
pub fn tpmPresent() bool {
    return soc.tpm_present;
}
pub fn tpmBase() usize {
    return soc.tpm_base;
}
pub fn fwcfgBase() usize {
    return soc.fwcfg_base;
}
pub fn sdhciBase() usize {
    return soc.sdhci_base;
}
pub fn sdhciFreq() u32 {
    return soc.sdhci_freq;
}
/// Every native SD/MMC host the platform declares, in device-tree order.
pub fn sdhciControllers() []const soc.SdhciController {
    return soc.sdhci_controllers;
}
/// Every SPI master the platform declares, in device-tree order.
pub fn spiControllers() []const soc.SpiController {
    return soc.spi_controllers;
}
