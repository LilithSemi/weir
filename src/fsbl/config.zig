//! FSBL configuration. Hardware addresses come from the `soc` module at
//! comptime; only the flash layout (where the main image sits) is a build
//! option, so one source targets different SoC families via -Ddtb.

const options = @import("fsbl_options");
const soc = @import("soc");

/// UART base for early FSBL logging (no DTB parsed at runtime yet at this stage).
pub const uart_base: usize = soc.uart_base;

/// Where the main Weir image runs from once DRAM is up (its link base).
pub const dram_base: usize = soc.ram_base;

/// Memory-mapped (XIP) base of the SPI flash holding the main image.
pub const flash_base: usize = soc.flash_base;

/// Whether this SoC has a TPM the FSBL should measure into, and its base.
pub const tpm_present: bool = soc.tpm_present;
pub const tpm_base: usize = soc.tpm_base;

/// DDR read-training control window (0 = the controller needs no CPU training).
pub const ddr_train_base: usize = soc.ddr_train_base;

/// Offset of the main Weir image within flash (layout policy, not hardware).
pub const main_offset: usize = options.main_offset;

/// Upper bound on the main image size to copy out of flash.
pub const main_max: usize = options.main_max;
