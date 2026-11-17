//! FSBL configuration. Hardware addresses come from the `soc` module at
//! comptime. The flash layout (where the main image sits) comes from the
//! `river-firmware` device-tree partition. One source targets different SoC
//! families via -Ddtb with no build flags.

const soc = @import("soc");

/// UART base for early FSBL logging (no DTB parsed at runtime yet at this stage).
pub const uart_base: usize = soc.uart_base;

/// Access to the UART by register number.
pub const uart_mmio = soc.uartMmio();

/// The shift from a UART register number to its byte offset.
pub const uart_reg_shift = soc.uart_reg_shift;

/// The bytes in one access to a UART register: 1 or 4.
pub const uart_io_width = soc.uart_io_width;

/// Baud divisor for 115200. The Harbor UART sends nothing while the divisor is
/// 0, so the FSBL must program it before its first print.
pub const uart_divisor: u16 = soc.uartDivisor(115200) orelse
    @compileError("the UART clock is too low for 115200 baud");

/// Where the main Weir image runs from once DRAM is up (its link base).
pub const dram_base: usize = soc.ram_base;

/// Usable DRAM size from the device tree. On a `train=runtime` build this
/// already excludes the knob window at the top of the array, so
/// `dram_base + dram_size` is the first byte memtest must not touch.
pub const dram_size: usize = soc.ram_size;

/// The hart count from the device tree. It selects the handoff page.
pub const hart_count: usize = soc.hart_count;

/// The compatible ids of the memory controller. ddr.zig gets the memory type
/// from them.
pub const sdram_ids: []const []const u8 = soc.sdram_ids;

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
