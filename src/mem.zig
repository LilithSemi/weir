//! Firmware memory layout, derived from `ram_base` and the RAM size.
//!
//! ram_base and the RAM size come from the SoC tree's /memory node at comptime.
//! See soc.zig. layout.zig turns the size into offsets. The linker script
//! generator reads the same tree and uses the same layout.zig, so the link
//! checks and the firmware agree.

const soc = @import("soc");
const layout = @import("layout.zig");

comptime {
    if (soc.ram_size < layout.min_ram)
        @compileError("Weir needs at least 16 MiB of RAM. The /memory node of the device tree gives less.");
}

fn plan() layout.Layout {
    return layout.compute(soc.ram_size, soc.hart_count);
}

/// Start of the RAM the firmware is linked into and runs from.
pub const ram_base: usize = soc.ram_base;
/// True for RAM under 128 MiB. See layout.zig.
pub const small_layout = plan().page_pool == null;

/// End of the reserved firmware window. The firmware stays in M-mode after the
/// OS starts, so the OS must not use this memory.
pub const fw_reserved_end: usize = ram_base + plan().fw_window;
/// PE/COFF load base of the first image.
pub const load_base: usize = ram_base + plan().load_base;
/// The first image must end at or below this address.
pub const load_limit: usize = ram_base + plan().loadLimit();
/// Linked ACPI tables, reclaimable by the OS.
pub const acpi_pool_base: usize = ram_base + plan().acpi_pool;
pub const acpi_pool_size: usize = plan().acpi_pool_size;
/// Start of the EFI page pool. Null when the pool starts after the loaded
/// first image. See uefi.prepare.
pub const page_pool_base: ?usize = if (plan().page_pool) |off| ram_base + off else null;
/// Boot manager file staging buffer.
pub const kernel_read_base: usize = ram_base + plan().staging;
pub const kernel_read_size: usize = plan().staging_size;
/// Staging buffer for `\EFI\BOOT\initrd`. A size of 0 disables it.
pub const initrd_base: usize = ram_base + plan().initrd;
pub const initrd_size: usize = plan().initrd_size;
/// Number of 1 MiB S-mode payload stacks.
pub const payload_stack_count: usize = plan().payload_stacks;

/// End of RAM from the SoC tree's /memory size.
pub const ram_end_default = ram_base + soc.ram_size;
