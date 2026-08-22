//! Build-time configuration. build.zig options supply these blobs.
//!
//! The `-Daml=PATH` and `-Ddtb=PATH` options embed an ACPI DSDT or a device
//! tree. Weir then uses a platform-provided description instead of generating one.

const options = @import("build_options");

/// Firmware-provided ACPI DSDT (raw AML), or null if none was supplied.
pub const aml: ?[]const u8 = if (options.has_aml) @embedFile("weir_aml")[0..] else null;

/// Firmware-provided device tree blob, or null to use the platform's DTB.
pub const dtb: ?[]const u8 = if (options.has_dtb) @embedFile("weir_dtb")[0..] else null;

/// S-mode ELF payload to load and jump to, or null.
pub const payload: ?[]const u8 = if (options.has_payload) @embedFile("weir_payload")[0..] else null;

/// Real PE32+ EFI application to load via the PE/COFF loader, or null.
pub const pe_app: ?[]const u8 = if (options.has_pe_app) @embedFile("weir_pe_app")[0..] else null;

/// When true, load the boot PE as a bare image at sector 0 of a disk (any block
/// device the tree declares), instead of an embedded blob.
pub const disk_boot: bool = options.disk_boot;

/// When true, boot via the ESP boot manager (GPT + FAT + BootOrder/fallback).
pub const boot_manager: bool = options.boot_manager;

/// Initramfs to serve the Linux kernel via LoadFile2, or null.
pub const initrd: ?[]const u8 = if (options.has_initrd) @embedFile("weir_initrd")[0..] else null;
