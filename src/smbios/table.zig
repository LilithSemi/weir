//! The SMBIOS structure table, assembled at compile time.
//!
//! `assemble` turns a `BoardInfo` into one byte blob. Only the values that
//! depend on the RAM found at boot stay open, and `patchRam` fills them. This
//! file has no platform imports, so its tests run on the host.

const std = @import("std");
const structs = @import("structs.zig");
const board_info = @import("board_info.zig");
const BoardInfo = board_info.BoardInfo;
const Memory = board_info.Memory;

/// Facts about the firmware build and the SoC that the tables carry.
pub const Firmware = struct {
    major: u8,
    minor: u8,
    patch: u8,
    /// BIOS release date, as MM/DD/YYYY.
    release_date: []const u8,
    soc_model: []const u8 = "River",
    cpu_model: []const u8 = "River",
};

pub const Assembled = struct {
    bytes: []const u8,
    /// Offset of the type 16 structure, when its capacity is the RAM size at boot.
    runtime_array: ?usize,
    /// Offset of the type 17 structure whose size is the RAM size at boot.
    runtime_device: ?usize,
};

const handle = struct {
    const bios: u16 = 0x0000;
    const system: u16 = 0x0100;
    const baseboard: u16 = 0x0200;
    const chassis: u16 = 0x0300;
    const processor: u16 = 0x0400;
    const oem_strings: u16 = 0x0b00;
    const memory_array: u16 = 0x1000;
    const memory_device: u16 = 0x1100;
    const end: u16 = 0x7f00;
};

/// A fixed, recognizable UUID. The unit ID replaces it when the board has one.
const default_uuid = [16]u8{
    0x57, 0x65, 0x69, 0x72, 0x00, 0x01, 0x40, 0x00,
    0x80, 0x00, 0x52, 0x69, 0x76, 0x65, 0x72, 0x00,
};

// Fixed-width strings that firmware can overwrite in place at boot.
const system_serial_slot: [16]u8 = @splat('0');
const module_serial_slot: [8]u8 = @splat('0');
const module_part_slot = "Unknown" ++ @as([13]u8, @splat(' '));

const default_memory = [_]Memory{
    .{ .type = .unknown, .form_factor = .dimm, .width_bits = structs.MemoryDevice.width_unknown },
};

/// The string set of one structure. `add` gives each string the next number.
/// An empty string gets 0, the SMBIOS value for no string.
const Strings = struct {
    bytes: []const u8 = "",
    count: u8 = 0,

    fn add(comptime self: *Strings, comptime s: []const u8) structs.String {
        if (s.len == 0) return 0;
        self.bytes = self.bytes ++ s ++ "\x00";
        self.count += 1;
        return self.count;
    }

    /// The bytes after the formatted area. A set with no strings is two NUL bytes.
    fn finish(comptime self: Strings) []const u8 {
        return if (self.count == 0) "\x00\x00" else self.bytes ++ "\x00";
    }
};

const Assembler = struct {
    bytes: []const u8 = "",

    /// Append a structure and its strings. Return the offset of the structure.
    fn add(comptime self: *Assembler, comptime value: anytype, comptime strings: Strings) usize {
        const off = self.bytes.len;
        self.bytes = self.bytes ++ std.mem.toBytes(value) ++ strings.finish();
        return off;
    }
};

const ArrayCapacity = struct { kb: u32, ext: u64 };

fn arrayCapacity(bytes: u64) ArrayCapacity {
    const kb = bytes / 1024;
    if (kb < structs.MemoryArray.use_ext_capacity) return .{ .kb = @intCast(kb), .ext = 0 };
    return .{ .kb = structs.MemoryArray.use_ext_capacity, .ext = bytes };
}

fn deviceSizeMb(bytes: u64) u16 {
    return @intCast(@min(bytes / (1024 * 1024), structs.MemoryDevice.size_mb_max));
}

pub fn assemble(comptime info: BoardInfo, comptime fw: Firmware) Assembled {
    @setEvalBranchQuota(200_000);
    var a: Assembler = .{};
    const product = info.product orelse fw.soc_model;

    {
        var s: Strings = .{};
        const bios: structs.Bios = .{
            .header = .of(structs.Bios, handle.bios),
            .vendor = s.add(info.vendor),
            .version = s.add(std.fmt.comptimePrint("Weir {d}.{d}.{d}", .{ fw.major, fw.minor, fw.patch })),
            .release_date = s.add(fw.release_date),
            .characteristics = structs.Bios.characteristics_not_supported,
            .major_release = fw.major,
            .minor_release = fw.minor,
        };
        _ = a.add(bios, s);
    }
    {
        var s: Strings = .{};
        const system: structs.System = .{
            .header = .of(structs.System, handle.system),
            .manufacturer = s.add(info.vendor),
            .product = s.add(product),
            .version = s.add(info.version),
            .serial = s.add(&system_serial_slot),
            .uuid = default_uuid,
            .sku = s.add(info.sku),
            .family = s.add(info.family),
        };
        _ = a.add(system, s);
    }
    {
        var s: Strings = .{};
        const baseboard: structs.Baseboard = .{
            .header = .of(structs.Baseboard, handle.baseboard),
            .manufacturer = s.add(info.vendor),
            .product = s.add(if (info.board) |b| b.preset else product),
            .version = s.add(info.version),
            .serial = s.add("0"),
            .asset_tag = s.add("0"),
            .location = s.add("Onboard"),
            .chassis_handle = handle.chassis,
        };
        _ = a.add(baseboard, s);
    }
    {
        var s: Strings = .{};
        const chassis: structs.Chassis = .{
            .header = .of(structs.Chassis, handle.chassis),
            .manufacturer = s.add(info.vendor),
            .type = info.chassis_type,
            .version = s.add(info.version),
            .serial = s.add("0"),
            .asset_tag = s.add("0"),
        };
        _ = a.add(chassis, s);
    }
    {
        var s: Strings = .{};
        const cores: u8 = if (info.cpu) |c| @intCast(@min(c.harts, 255)) else 0;
        const mhz: u16 = if (info.cpu) |c| @intCast(@min(c.clock_hz / 1_000_000, 0xffff)) else 0;
        const isa = if (info.cpu) |c| c.isa else "";
        const processor: structs.Processor = .{
            .header = .of(structs.Processor, handle.processor),
            .socket = s.add("CPU0"),
            .manufacturer = s.add(info.vendor),
            .version = s.add(if (info.cpu) |c| c.model else fw.cpu_model),
            .max_speed_mhz = mhz,
            .current_speed_mhz = mhz,
            .serial = s.add("0"),
            .asset_tag = s.add("0"),
            .part_number = s.add(if (isa.len > 0) isa else "River-RV64"),
            .core_count = cores,
            .core_enabled = cores,
            .thread_count = cores,
        };
        _ = a.add(processor, s);
    }
    if (info.board) |b| if (b.fpga_part.len > 0) {
        var s: Strings = .{};
        _ = s.add("fpga=" ++ b.fpga_part);
        const oem: structs.OemStrings = .{
            .header = .of(structs.OemStrings, handle.oem_strings),
            .count = s.count,
        };
        _ = a.add(oem, s);
    };

    const memories: []const Memory = if (info.memory.len == 0) &default_memory else info.memory;

    // The array capacity is known at build time only when every memory gives a size.
    var capacity: ?u64 = 0;
    for (memories) |m| {
        const c: ?u64 = m.max_size_bytes orelse m.size_bytes;
        capacity = if (capacity != null and c != null) capacity.? + c.? else null;
    }
    const fixed: ArrayCapacity = if (capacity) |c| arrayCapacity(c) else .{ .kb = 0, .ext = 0 };
    const array: structs.MemoryArray = .{
        .header = .of(structs.MemoryArray, handle.memory_array),
        .max_capacity_kb = fixed.kb,
        .device_count = @intCast(memories.len),
        .ext_max_capacity = fixed.ext,
    };
    const array_off = a.add(array, Strings{});

    var runtime_device: ?usize = null;
    for (memories, 0..) |m, i| {
        var s: Strings = .{};
        const socketed = m.max_size_bytes != null;
        const device: structs.MemoryDevice = .{
            .header = .of(structs.MemoryDevice, handle.memory_device + i),
            .array_handle = handle.memory_array,
            .total_width = m.width_bits,
            .data_width = m.width_bits,
            .size_mb = if (m.size_bytes) |size| deviceSizeMb(size) else 0,
            .form_factor = m.form_factor,
            .device_locator = s.add(std.fmt.comptimePrint("DIMM {d}", .{i})),
            .bank_locator = s.add("BANK 0"),
            .memory_type = m.type,
            .manufacturer = s.add(info.vendor),
            .serial = s.add(if (socketed) &module_serial_slot else "0"),
            .asset_tag = s.add("0"),
            .part_number = s.add(if (socketed) module_part_slot else "River-RAM"),
        };
        const off = a.add(device, s);
        if (m.size_bytes == null) {
            if (runtime_device != null) {
                @compileError("board info: only one memory can take its size from the RAM found at boot");
            }
            runtime_device = off;
        }
    }

    _ = a.add(structs.End{ .header = .of(structs.End, handle.end) }, Strings{});

    return .{
        .bytes = a.bytes,
        .runtime_array = if (capacity == null) array_off else null,
        .runtime_device = runtime_device,
    };
}

fn view(comptime T: type, table: []u8, off: usize) *T {
    return @ptrCast(table[off..][0..@sizeOf(T)]);
}

/// Write the values that depend on the RAM found at boot. Safe to call again.
pub fn patchRam(comptime a: Assembled, table: *[a.bytes.len]u8, ram_bytes: u64) void {
    if (a.runtime_array) |off| {
        const capacity = arrayCapacity(ram_bytes);
        const array = view(structs.MemoryArray, table, off);
        array.max_capacity_kb = capacity.kb;
        array.ext_max_capacity = capacity.ext;
    }
    if (a.runtime_device) |off| {
        view(structs.MemoryDevice, table, off).size_mb = deviceSizeMb(ram_bytes);
    }
}

/// Point the entry point at the table and set its checksum.
pub fn seal(entry: *structs.EntryPoint, table_address: u64) void {
    entry.table_address = table_address;
    entry.checksum = 0;
    var sum: u8 = 0;
    for (std.mem.asBytes(entry)) |b| sum +%= b;
    entry.checksum = 0 -% sum;
}

const test_fw: Firmware = .{ .major = 0, .minor = 1, .patch = 0, .release_date = "01/01/2026" };
const gib: u64 = 1 << 30;

const Found = struct {
    formatted: []const u8,
    strings: []const u8,

    fn string(self: Found, index: u8) []const u8 {
        var it = std.mem.splitScalar(u8, self.strings, 0);
        var i: u8 = 1;
        while (it.next()) |s| : (i += 1) {
            if (i == index) return s;
        }
        return "";
    }
};

/// Walk the table as an OS does and return the `nth` structure of a type.
fn find(table: []const u8, type_id: u8, nth: usize) ?Found {
    var off: usize = 0;
    var seen: usize = 0;
    while (off + 4 <= table.len) {
        const len = table[off + 1];
        var end = off + len;
        while (end + 1 < table.len and !(table[end] == 0 and table[end + 1] == 0)) end += 1;
        if (table[off] == type_id) {
            if (seen == nth) return .{
                .formatted = table[off..][0..len],
                .strings = table[off + len .. end + 1],
            };
            seen += 1;
        }
        off = end + 2;
    }
    return null;
}

fn defaultTable() [assemble(.{}, test_fw).bytes.len]u8 {
    const a = comptime assemble(.{}, test_fw);
    var table = a.bytes[0..a.bytes.len].*;
    patchRam(a, &table, 2 * gib);
    return table;
}

test "a default board keeps the formatted areas of the old byte writer" {
    const table = defaultTable();
    const expect = std.testing.expectEqualSlices;

    try expect(u8, &.{
        0x00, 0x18, 0x00, 0x00, 0x01, 0x02, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0xff,
    }, find(&table, 0, 0).?.formatted);
    try expect(u8, &.{
        0x01, 0x1b, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x57, 0x65, 0x69, 0x72, 0x00, 0x01,
        0x40, 0x00, 0x80, 0x00, 0x52, 0x69, 0x76, 0x65, 0x72, 0x00, 0x06, 0x05, 0x06,
    }, find(&table, 1, 0).?.formatted);
    try expect(u8, &.{
        0x02, 0x0f, 0x00, 0x02, 0x01, 0x02, 0x03, 0x04, 0x05, 0x09, 0x06, 0x00, 0x03, 0x0a, 0x00,
    }, find(&table, 2, 0).?.formatted);
    try expect(u8, &.{
        0x03, 0x15, 0x00, 0x03, 0x01, 0x03, 0x02, 0x03, 0x04, 0x03, 0x03,
        0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, find(&table, 3, 0).?.formatted);
    try expect(u8, &.{
        0x04, 0x2a, 0x00, 0x04, 0x01, 0x03, 0xfe, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x03, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x06, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0x04, 0x05, 0x06, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x02,
    }, find(&table, 4, 0).?.formatted);
    try expect(u8, &.{
        0x10, 0x17, 0x00, 0x10, 0x03, 0x03, 0x03, 0x00, 0x00, 0x20, 0x00, 0xfe,
        0xff, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, find(&table, 16, 0).?.formatted);
    try expect(u8, &.{
        0x11, 0x1b, 0x00, 0x11, 0x00, 0x10, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x08,
        0x09, 0x00, 0x01, 0x02, 0x02, 0x04, 0x00, 0x00, 0x00, 0x03, 0x04, 0x05, 0x06,
    }, find(&table, 17, 0).?.formatted);
    try expect(u8, &.{ 0x7f, 0x04, 0x00, 0x7f }, find(&table, 127, 0).?.formatted);
}

test "a default board has no OEM strings structure" {
    const table = defaultTable();
    try std.testing.expect(find(&table, 11, 0) == null);
}

test "a default board keeps its strings, with a 16-digit system serial slot" {
    const table = defaultTable();
    const expect = std.testing.expectEqualStrings;

    const bios = find(&table, 0, 0).?;
    try expect("Lilith Semiconductor", bios.string(1));
    try expect("Weir 0.1.0", bios.string(2));
    try expect("01/01/2026", bios.string(3));

    const system = find(&table, 1, 0).?;
    try expect("Lilith Semiconductor", system.string(1));
    try expect("River", system.string(2));
    try expect("1.0", system.string(3));
    try expect("0000000000000000", system.string(4));
    try expect("0", system.string(5));
    try expect("River", system.string(6));

    try expect("Onboard", find(&table, 2, 0).?.string(6));
    try expect("River-RV64", find(&table, 4, 0).?.string(6));

    const dimm = find(&table, 17, 0).?;
    try expect("DIMM 0", dimm.string(1));
    try expect("0", dimm.string(4));
    try expect("River-RAM", dimm.string(6));
}

test "the table is a chain of structures that ends with type 127" {
    const table = defaultTable();
    var off: usize = 0;
    var last: u8 = 0;
    while (off < table.len) {
        try std.testing.expect(off + 4 <= table.len);
        const len = table[off + 1];
        try std.testing.expect(len >= 4);
        last = table[off];
        var end = off + len;
        while (!(table[end] == 0 and table[end + 1] == 0)) end += 1;
        off = end + 2;
    }
    try std.testing.expectEqual(table.len, off);
    try std.testing.expectEqual(@as(u8, 127), last);
}

test "RAM of 2 TiB or more goes in the extended capacity field" {
    const a = comptime assemble(.{}, test_fw);
    var table = a.bytes[0..a.bytes.len].*;
    patchRam(a, &table, 4096 * gib);

    const array = find(&table, 16, 0).?.formatted;
    try std.testing.expectEqual(@as(u32, 0x8000_0000), std.mem.readInt(u32, array[7..11], .little));
    try std.testing.expectEqual(4096 * gib, std.mem.readInt(u64, array[15..23], .little));
    // The 2.3 device layout cannot hold this size, so it stops at its maximum.
    const dimm = find(&table, 17, 0).?.formatted;
    try std.testing.expectEqual(@as(u16, 0x7fff), std.mem.readInt(u16, dimm[12..14], .little));
}

test "a Harbor board file fills the processor, memory and board structures" {
    const info: BoardInfo = @import("testdata/kc705.board.zon");
    const a = comptime assemble(info, test_fw);
    var table = a.bytes[0..a.bytes.len].*;
    // A 512 MiB module sits in a socket that takes 1 GiB.
    patchRam(a, &table, gib / 2);

    try std.testing.expectEqualStrings("River KC705", find(&table, 1, 0).?.string(2));
    try std.testing.expectEqualStrings("river", find(&table, 1, 0).?.string(6));
    try std.testing.expectEqualStrings("kc705", find(&table, 2, 0).?.string(2));

    const cpu = find(&table, 4, 0).?;
    try std.testing.expectEqualStrings("River RV64", cpu.string(3));
    try std.testing.expectEqualStrings("rv64imac", cpu.string(6));
    try std.testing.expectEqual(@as(u16, 50), std.mem.readInt(u16, cpu.formatted[0x14..0x16], .little));
    try std.testing.expectEqual(@as(u16, 50), std.mem.readInt(u16, cpu.formatted[0x16..0x18], .little));
    try std.testing.expectEqual(@as(u8, 2), cpu.formatted[0x23]); // core count
    try std.testing.expectEqual(@as(u8, 2), cpu.formatted[0x24]); // cores enabled
    try std.testing.expectEqual(@as(u8, 2), cpu.formatted[0x25]); // thread count

    const oem = find(&table, 11, 0).?;
    try std.testing.expectEqual(@as(u8, 1), oem.formatted[4]);
    try std.testing.expectEqualStrings("fpga=xc7k325t-ffg900", oem.string(1));

    // The array capacity is the socket limit, not the fitted module.
    const array = find(&table, 16, 0).?.formatted;
    try std.testing.expectEqual(@as(u32, 1024 * 1024), std.mem.readInt(u32, array[7..11], .little));

    const dimm = find(&table, 17, 0).?;
    try std.testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, dimm.formatted[8..10], .little));
    try std.testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, dimm.formatted[10..12], .little));
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, dimm.formatted[12..14], .little));
    try std.testing.expectEqual(@as(u8, 0x0d), dimm.formatted[14]); // SODIMM
    try std.testing.expectEqual(@as(u8, 0x18), dimm.formatted[18]); // DDR3
    try std.testing.expectEqualStrings("00000000", dimm.string(4));
    try std.testing.expectEqual(@as(usize, 20), dimm.string(6).len);
}

test "a soldered memory keeps its build-time size at boot" {
    const info: BoardInfo = .{ .memory = &.{
        .{ .type = .ddr3, .form_factor = .chip, .width_bits = 16, .size_bytes = 256 << 20 },
    } };
    const a = comptime assemble(info, test_fw);
    try std.testing.expect(a.runtime_array == null);
    try std.testing.expect(a.runtime_device == null);

    var table = a.bytes[0..a.bytes.len].*;
    patchRam(a, &table, 2 * gib);
    const chip = find(&table, 17, 0).?.formatted;
    try std.testing.expectEqual(@as(u16, 256), std.mem.readInt(u16, chip[12..14], .little));
    const array = find(&table, 16, 0).?.formatted;
    try std.testing.expectEqual(@as(u32, 256 * 1024), std.mem.readInt(u32, array[7..11], .little));
}

test "each memory gets its own device structure and handle" {
    const info: BoardInfo = .{ .memory = &.{
        .{ .type = .ddr3, .form_factor = .chip, .width_bits = 16, .size_bytes = 256 << 20 },
        .{ .type = .sram, .form_factor = .chip, .width_bits = 8, .size_bytes = 1 << 20 },
    } };
    const a = comptime assemble(info, test_fw);
    const table = a.bytes;

    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, find(table, 16, 0).?.formatted[13..15], .little));
    const second = find(table, 17, 1).?;
    try std.testing.expectEqual(@as(u16, 0x1101), std.mem.readInt(u16, second.formatted[2..4], .little));
    try std.testing.expectEqual(@as(u8, 0x06), second.formatted[18]); // SRAM
    try std.testing.expectEqualStrings("DIMM 1", second.string(1));
    try std.testing.expect(find(table, 17, 2) == null);
}

test "a sealed entry point sums to zero and names the table" {
    var entry: structs.EntryPoint = .{ .major = 3, .minor = 6, .table_max_size = 445, .table_address = 0 };
    seal(&entry, 0x8123_4560);
    var sum: u8 = 0;
    for (std.mem.asBytes(&entry)) |b| sum +%= b;
    try std.testing.expectEqual(@as(u8, 0), sum);
    try std.testing.expectEqual(@as(u64, 0x8123_4560), entry.table_address);

    // A second seal at a new address stays valid.
    seal(&entry, 0x9000_0000);
    sum = 0;
    for (std.mem.asBytes(&entry)) |b| sum +%= b;
    try std.testing.expectEqual(@as(u8, 0), sum);
}

test "an empty board string becomes string 0 and keeps the later strings" {
    const a = comptime assemble(.{ .sku = "" }, test_fw);
    const system = find(a.bytes, 1, 0).?;
    try std.testing.expectEqual(@as(u8, 0), system.formatted[0x19]); // SKU
    try std.testing.expectEqual(@as(u8, 5), system.formatted[0x1a]); // family
    try std.testing.expectEqualStrings("River", system.string(5));
    try std.testing.expectEqualStrings("River", find(a.bytes, 2, 0).?.string(2));
}
