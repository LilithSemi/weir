//! Platform peripheral map.
//!
//! Every device address is baked at COMPTIME from the embedded device tree
//! (soc.zig, via conduit's Builder). There is NO runtime device lookup - the
//! addresses are known at compile time, so boot pays zero discovery cost. This
//! module is a thin typed accessor over those comptime constants.

const console = @import("console/console.zig");
const soc = @import("soc");

// Peripherals conduit does not surface for this SoC keep fixed defaults (absent
// on a Harbor SoC like creek; QEMU's fw-cfg/CFI/reset are the runtime-DT world we
// no longer walk).
const reset_base_v: usize = 0x100000;
const fwcfg_base_v: usize = 0;
const cfi_flash_base_v: usize = 0;

/// Discovery is comptime (soc.zig via conduit); nothing to do at runtime. Kept so
/// call sites need not change.
pub fn discover(dtb: usize) void {
    _ = dtb;
}

/// Print the resolved peripheral map (needs the console up).
pub fn report() void {
    console.printf("[plat] uart @ {x}, clint @ {x}, ram @ {x} (+{x}), flash @ {x}\n", .{
        soc.uart_base, soc.clint_base, soc.ram_base, soc.ram_size, soc.flash_base,
    });
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
    return fwcfg_base_v;
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
