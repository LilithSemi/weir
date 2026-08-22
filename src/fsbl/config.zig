//! FSBL configuration. Hardware addresses come from the `soc` module at
//! comptime. The flash layout (where the main image sits) comes from the
//! `river-firmware` device-tree partition. One source targets different SoC
//! families via -Ddtb with no build flags.

const soc = @import("soc");

/// UART base for early FSBL logging (no DTB parsed at runtime yet at this stage).
pub const uart_base: usize = soc.uart_base;

/// Baud divisor for 115200: River/Harbor's UART gates TX on a nonzero divisor
/// (baud = clock/divisor), so the FSBL must program it before its first print.
pub const uart_divisor: u16 = @intCast(soc.uart_clock / 115200);

/// Where the main Weir image runs from once DRAM is up (its link base).
pub const dram_base: usize = soc.ram_base;

/// Memory-mapped (XIP) base of the SPI flash holding the main image.
pub const flash_base: usize = soc.flash_base;

/// Whether this SoC has a TPM the FSBL should measure into, and its base.
pub const tpm_present: bool = soc.tpm_present;
pub const tpm_base: usize = soc.tpm_base;

/// Offset + max size of the main Weir image within flash, from the
/// `river-firmware` device-tree partition. tools/fdt_ld.zig lowers the
/// partition's reg into these absolute linker symbols, so the symbol VALUE is
/// the offset/size and it is read via the symbol's address (same trick as
/// _data_lma in start.zig). No build flag.
extern const _fsbl_main_offset: u8;
extern const _fsbl_main_max: u8;

pub inline fn mainOffset() usize {
    return @intFromPtr(&_fsbl_main_offset);
}

pub inline fn mainMax() usize {
    return @intFromPtr(&_fsbl_main_max);
}
