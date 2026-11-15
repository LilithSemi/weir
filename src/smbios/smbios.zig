//! SMBIOS (DMI) tables, published to the OS through an EFI configuration table.
//!
//! The structure table is assembled at compile time from the board identity
//! (see table.zig). At boot, `build` fills the RAM size and seals the 64-bit
//! entry point. Linux's DMI scanner reads the entry point from the SMBIOS3
//! config table and fills /sys/class/dmi/id.
//!
//! SMBIOS is architecture-neutral. The processor carries the proposed RV64
//! "family 2" code, which recent dmidecode understands and older tools ignore.

const std = @import("std");
const soc = @import("soc");
const config = @import("../config.zig");
const board = @import("../board.zig");
const structs = @import("structs.zig");
const tbl = @import("table.zig");
const uefi = std.os.uefi;

// SMBIOS3_TABLE_GUID f2fd1544-9794-4a2c-992e-e5bbcf20e394.
pub const SMBIOS3_GUID = uefi.Guid{
    .time_low = 0xf2fd1544,
    .time_mid = 0x9794,
    .time_high_and_version = 0x4a2c,
    .clock_seq_high_and_reserved = 0x99,
    .clock_seq_low = 0x2e,
    .node = .{ 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94 },
};

const assembled = tbl.assemble(board.info, .{
    .major = @intCast(config.version.major),
    .minor = @intCast(config.version.minor),
    .patch = @intCast(config.version.patch),
    .release_date = config.bios_date,
    .soc_model = soc.model,
    .cpu_model = soc.cpu_model,
});

var table: [assembled.bytes.len]u8 align(8) = assembled.bytes[0..assembled.bytes.len].*;

var entry: structs.EntryPoint align(16) = .{
    .major = 3,
    .minor = 6,
    .table_max_size = assembled.bytes.len,
    .table_address = 0,
};

/// Finish the tables for a machine with `ram_bytes` of RAM. Safe to call again.
/// Call before publishing the config table.
pub fn build(ram_bytes: u64) void {
    tbl.patchRam(assembled, &table, ram_bytes);
    tbl.seal(&entry, @intFromPtr(&table));
}

/// Pointer the SMBIOS3 configuration table should carry.
pub fn entryPoint() *anyopaque {
    return @ptrCast(&entry);
}
