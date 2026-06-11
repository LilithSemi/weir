//! SMBIOS (DMI) tables, published to the OS through an EFI configuration table.
//!
//! We build a small SMBIOS 3.0 structure table (BIOS, system, baseboard,
//! chassis, processor, memory) and a 64-bit entry point. Linux's DMI scanner
//! reads the entry point from the SMBIOS3 config table and fills
//! /sys/class/dmi/id, so dmidecode and the kernel see real board info.
//!
//! SMBIOS is architecture-neutral, so this works on RISC-V today. We tag the
//! processor with the proposed RV64 "family 2" code, which recent dmidecode
//! understands and older tools ignore. The DMI core needs none of the RISC-V
//! bits the spec is still ratifying.

const std = @import("std");
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

const VERSION_MAJOR = 3;
const VERSION_MINOR = 6;

var table: [2048]u8 align(8) = undefined;
var table_len: usize = 0;
var entry: [24]u8 align(16) = undefined;

// --- structure-table writer -------------------------------------------------

var cur: usize = 0;

fn put8(v: u8) void {
    table[cur] = v;
    cur += 1;
}

fn put16(v: u16) void {
    std.mem.writeInt(u16, table[cur..][0..2], v, .little);
    cur += 2;
}

fn put32(v: u32) void {
    std.mem.writeInt(u32, table[cur..][0..4], v, .little);
    cur += 4;
}

fn put64(v: u64) void {
    std.mem.writeInt(u64, table[cur..][0..8], v, .little);
    cur += 8;
}

fn header(stype: u8, length: u8, handle: u16) void {
    put8(stype);
    put8(length);
    put16(handle);
}

/// Close a structure with its string set. SMBIOS strings follow the formatted
/// area, each NUL-terminated, the set ending with an extra NUL. A set with no
/// strings is two NULs.
fn strings(set: []const []const u8) void {
    if (set.len == 0) {
        put8(0);
        put8(0);
        return;
    }
    for (set) |s| {
        @memcpy(table[cur..][0..s.len], s);
        cur += s.len;
        put8(0);
    }
    put8(0);
}

/// Build the structure table and entry point for a machine with `ram_bytes` of
/// RAM. Idempotent. Call before publishing the config table.
pub fn build(ram_bytes: u64) void {
    cur = 0;

    // Type 0 - BIOS Information.
    header(0, 0x18, 0x0000);
    put8(1); // Vendor -> "Midstall"
    put8(2); // BIOS Version -> "Weir 0.1"
    put16(0); // BIOS starting address segment (n/a)
    put8(3); // BIOS Release Date -> string
    put8(0); // BIOS ROM size (64 KiB * (n+1)); 0 = 64 KiB
    put64(1 << 3); // Characteristics: bit 3 = BIOS Characteristics Not Supported
    put16(0); // characteristics extension bytes 1-2
    put8(VERSION_MAJOR); // System BIOS major release
    put8(1); // System BIOS minor release
    put8(0xff); // EC firmware major (none)
    put8(0xff); // EC firmware minor (none)
    strings(&.{ "Midstall", "Weir 0.1", "01/01/2026" });

    // Type 1 - System Information.
    header(1, 0x1b, 0x0100);
    put8(1); // Manufacturer -> "Midstall"
    put8(2); // Product Name -> "River"
    put8(3); // Version
    put8(4); // Serial Number
    // UUID: a fixed, recognizable value for our virtual board.
    const uuid = [16]u8{ 0x57, 0x65, 0x69, 0x72, 0x00, 0x01, 0x40, 0x00, 0x80, 0x00, 0x52, 0x69, 0x76, 0x65, 0x72, 0x00 };
    @memcpy(table[cur..][0..16], &uuid);
    cur += 16;
    put8(0x06); // Wake-up Type: Power Switch
    put8(5); // SKU Number
    put8(6); // Family
    strings(&.{ "Midstall", "River", "1.0", "0", "0", "River" });

    // Type 2 - Baseboard.
    header(2, 0x0f, 0x0200);
    put8(1); // Manufacturer
    put8(2); // Product
    put8(3); // Version
    put8(4); // Serial Number
    put8(5); // Asset Tag
    put8(0x09); // Feature flags: hosting board | replaceable
    put8(6); // Location in Chassis
    put16(0x0300); // Chassis Handle
    put8(0x0a); // Board Type: Motherboard
    put8(0); // Number of contained object handles
    strings(&.{ "Midstall", "River Mainboard", "1.0", "0", "0", "Onboard" });

    // Type 3 - Chassis.
    header(3, 0x15, 0x0300);
    put8(1); // Manufacturer
    put8(0x03); // Type: Desktop
    put8(2); // Version
    put8(3); // Serial Number
    put8(4); // Asset Tag
    put8(0x03); // Boot-up State: Safe
    put8(0x03); // Power Supply State: Safe
    put8(0x03); // Thermal State: Safe
    put8(0x03); // Security Status: None
    put32(0); // OEM-defined
    put8(0); // Height (U), unspecified
    put8(0); // Number of power cords
    put8(0); // Contained element count
    put8(0); // Contained element record length
    strings(&.{ "Midstall", "1.0", "0", "0" });

    // Type 4 - Processor Information (SMBIOS 2.6 layout, length 0x2a).
    header(4, 0x2a, 0x0400);
    put8(1); // Socket Designation
    put8(0x03); // Processor Type: Central Processor
    put8(0xfe); // Processor Family: use "Processor Family 2" field
    put8(2); // Processor Manufacturer
    put64(0); // Processor ID (vendor/arch/imp not surfaced here)
    put8(3); // Processor Version
    put8(0x80); // Voltage: bit7 set => legacy mode, value n/a
    put16(0); // External Clock (MHz), unknown
    put16(0); // Max Speed (MHz), unknown
    put16(0); // Current Speed (MHz), unknown
    put8(0x41); // Status: populated, enabled
    put8(0x06); // Processor Upgrade: None
    put16(0xffff); // L1 Cache Handle: not provided
    put16(0xffff); // L2 Cache Handle
    put16(0xffff); // L3 Cache Handle
    put8(4); // Serial Number
    put8(5); // Asset Tag
    put8(6); // Part Number
    put8(0); // Core Count: unknown
    put8(0); // Core Enabled: unknown
    put8(0); // Thread Count: unknown
    put16(0x0004); // Processor Characteristics: 64-bit Capable
    put16(0x0201); // Processor Family 2: RISC-V RV64 (proposed code)
    strings(&.{ "CPU0", "Midstall", "River", "0", "0", "River-RV64" });

    // Type 16 - Physical Memory Array.
    header(16, 0x17, 0x1000);
    put8(0x03); // Location: System Board
    put8(0x03); // Use: System Memory
    put8(0x03); // Error Correction: None
    const ram_kb: u64 = ram_bytes / 1024;
    if (ram_kb < 0x80000000) {
        put32(@intCast(ram_kb)); // Maximum Capacity (KB)
        put16(0xfffe); // Memory Error Information Handle: not provided
        put16(1); // Number of Memory Devices
        put64(0); // Extended Maximum Capacity (unused)
    } else {
        put32(0x80000000); // sentinel: use extended field
        put16(0xfffe);
        put16(1);
        put64(ram_bytes); // Extended Maximum Capacity (bytes)
    }
    strings(&.{});

    // Type 17 - Memory Device (SMBIOS 2.3 layout, length 0x1b).
    header(17, 0x1b, 0x1100);
    put16(0x1000); // Physical Memory Array Handle
    put16(0xfffe); // Memory Error Information Handle: not provided
    put16(0xffff); // Total Width: unknown
    put16(0xffff); // Data Width: unknown
    const ram_mb: u64 = ram_bytes / (1024 * 1024);
    if (ram_mb < 0x7fff) put16(@intCast(ram_mb)) else put16(0x7fff); // Size (MB)
    put8(0x09); // Form Factor: DIMM
    put8(0); // Device Set: none
    put8(1); // Device Locator
    put8(2); // Bank Locator
    put8(0x02); // Memory Type: Unknown
    put16(0x0004); // Type Detail: Unknown
    put16(0); // Speed (MT/s), unknown
    put8(3); // Manufacturer
    put8(4); // Serial Number
    put8(5); // Asset Tag
    put8(6); // Part Number
    strings(&.{ "DIMM 0", "BANK 0", "Midstall", "0", "0", "River-RAM" });

    // Type 127 - End-of-Table.
    header(127, 0x04, 0x7f00);
    strings(&.{});

    table_len = cur;
    buildEntry();
}

fn buildEntry() void {
    @memset(&entry, 0);
    @memcpy(entry[0..5], "_SM3_");
    entry[5] = 0; // checksum, filled below
    entry[6] = 0x18; // entry point length
    entry[7] = VERSION_MAJOR;
    entry[8] = VERSION_MINOR;
    entry[9] = 0; // SMBIOS docrev
    entry[10] = 0x01; // entry point revision
    entry[11] = 0; // reserved
    std.mem.writeInt(u32, entry[12..16], @intCast(table_len), .little);
    std.mem.writeInt(u64, entry[16..24], @intFromPtr(&table), .little);

    var sum: u8 = 0;
    for (entry) |b| sum +%= b;
    entry[5] = (0 -% sum);
}

/// Pointer the SMBIOS3 configuration table should carry.
pub fn entryPoint() *anyopaque {
    return @ptrCast(&entry);
}
