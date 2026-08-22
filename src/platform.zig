//! Platform peripheral map.
//!
//! Every device address bakes in at comptime from the embedded device tree. See
//! soc.zig and conduit's Builder. There is no runtime device lookup. The
//! addresses are known at compile time, so boot pays zero discovery cost. This
//! module is a thin typed accessor over those comptime constants.

const console = @import("console/console.zig");
const soc = @import("soc");

// Peripherals that conduit does not surface for this SoC keep fixed defaults. A
// Harbor SoC like creek has no CFI or reset device. Those belong to the
// runtime-DT world that Weir no longer walks. fw-cfg is discovered from the tree
// (soc.fwcfg_base): QEMU's virt machine has it, a real River SoC does not.
const reset_base_v: usize = 0x100000;
const cfi_flash_base_v: usize = 0;

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
}

pub fn uartBase() usize {
    return soc.uart_base;
}
pub fn clintBase() usize {
    return soc.clint_base;
}
pub fn resetBase() usize {
    return reset_base_v;
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
pub fn cfiFlashBase() usize {
    return cfi_flash_base_v;
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
