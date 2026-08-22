//! Firmware memory layout, derived from a single `ram_base`.
//!
//! This module computes every base-relative address from `ram_base`. ram_base
//! comes from the SoC tree's /memory node at comptime. See soc.zig. So nothing
//! assumes one SoC. build.zig reads the same tree for the linker base. The
//! layout and the link address agree, with no -Dram-base option to keep in sync.

const soc = @import("soc");

/// Start of the RAM the firmware is linked into and runs from.
pub const ram_base: usize = soc.ram_base;

// Offsets from ram_base for the low firmware window and staging areas. Keep in
// sync with the generated linker script's RAM_BASE.
pub const fw_reserved_end = ram_base + 0x0200_0000; // end of reserved firmware region (32 MiB)
pub const load_base = ram_base + 0x0200_0000; // PE/COFF image load base
pub const acpi_pool_base = ram_base + 0x03f0_0000; // linked ACPI tables (just below the page pool)
pub const acpi_pool_size = 0x10_0000; // 1 MiB
pub const page_pool_base = ram_base + 0x0400_0000; // EFI AllocatePool/Pages bump pool (64 MiB)
pub const kernel_read_base = ram_base + 0x0600_0000; // boot-manager kernel staging buffer
pub const initrd_base = ram_base + 0x2000_0000; // initrd staging buffer (512 MiB)

/// Default top-of-RAM from the SoC tree's /memory size. The runtime DTB read in
/// uefi.prepare can still refine it (e.g. for QEMU's -m).
pub const ram_end_default = ram_base + soc.ram_size;
