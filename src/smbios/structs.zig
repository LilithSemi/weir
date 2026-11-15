//! SMBIOS structure layouts, from the DMTF SMBIOS Reference Specification 3.6.
//!
//! Each struct is the formatted area of one structure type. SMBIOS does not
//! align its fields, so every multi-byte field has `align(1)`. The strings that
//! follow a formatted area are not part of these structs.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // The table gets these structs as raw bytes, and SMBIOS is little-endian.
    if (builtin.cpu.arch.endian() != .little) @compileError("SMBIOS layouts need a little-endian target");
}

/// The 1-based position of a string in the structure's string set. 0 is no string.
pub const String = u8;

pub const Header = extern struct {
    type: u8,
    length: u8,
    handle: u16 align(1),

    pub fn of(comptime T: type, handle: u16) Header {
        return .{ .type = T.type_id, .length = @sizeOf(T), .handle = handle };
    }
};

/// The SMBIOS 3.0 64-bit entry point.
pub const EntryPoint = extern struct {
    anchor: [5]u8 = "_SM3_".*,
    checksum: u8 = 0,
    length: u8 = 0x18,
    major: u8,
    minor: u8,
    docrev: u8 = 0,
    revision: u8 = 1,
    reserved: u8 = 0,
    table_max_size: u32 align(1),
    table_address: u64 align(1),
};

pub const Bios = extern struct {
    pub const type_id: u8 = 0;
    /// Characteristics bit 3: BIOS characteristics are not supported.
    pub const characteristics_not_supported: u64 = 1 << 3;

    header: Header,
    vendor: String,
    version: String,
    start_segment: u16 align(1) = 0,
    release_date: String,
    /// ROM size in 64 KiB units, less one.
    rom_size: u8 = 0,
    characteristics: u64 align(1),
    characteristics_ext: [2]u8 = .{ 0, 0 },
    major_release: u8,
    minor_release: u8,
    /// 0xff: the board has no embedded controller.
    ec_major_release: u8 = 0xff,
    ec_minor_release: u8 = 0xff,
};

pub const System = extern struct {
    pub const type_id: u8 = 1;

    header: Header,
    manufacturer: String,
    product: String,
    version: String,
    serial: String,
    uuid: [16]u8,
    /// 0x06: power switch.
    wake_up_type: u8 = 0x06,
    sku: String,
    family: String,
};

pub const Baseboard = extern struct {
    pub const type_id: u8 = 2;

    header: Header,
    manufacturer: String,
    product: String,
    version: String,
    serial: String,
    asset_tag: String,
    /// 0x09: hosting board, replaceable.
    features: u8 = 0x09,
    location: String,
    chassis_handle: u16 align(1),
    /// 0x0a: motherboard.
    board_type: u8 = 0x0a,
    object_count: u8 = 0,
};

pub const ChassisType = enum(u8) {
    other = 0x01,
    unknown = 0x02,
    desktop = 0x03,
    low_profile_desktop = 0x04,
    mini_tower = 0x06,
    tower = 0x07,
    laptop = 0x09,
    notebook = 0x0a,
    all_in_one = 0x0d,
    rack_mount = 0x17,
    embedded_pc = 0x22,
    mini_pc = 0x23,
};

pub const Chassis = extern struct {
    pub const type_id: u8 = 3;
    /// State value 0x03: safe. Security value 0x03: none.
    const safe: u8 = 0x03;

    header: Header,
    manufacturer: String,
    type: ChassisType,
    version: String,
    serial: String,
    asset_tag: String,
    bootup_state: u8 = safe,
    power_supply_state: u8 = safe,
    thermal_state: u8 = safe,
    security_status: u8 = safe,
    oem_defined: u32 align(1) = 0,
    height: u8 = 0,
    power_cords: u8 = 0,
    element_count: u8 = 0,
    element_length: u8 = 0,
};

/// Processor Information in the SMBIOS 2.6 layout.
pub const Processor = extern struct {
    pub const type_id: u8 = 4;
    /// Family 0xfe: read the `family2` field.
    pub const family_use_family2: u8 = 0xfe;
    /// The proposed Processor Family 2 code for RISC-V RV64.
    pub const family2_rv64: u16 = 0x0201;
    pub const no_cache: u16 = 0xffff;

    header: Header,
    socket: String,
    /// 0x03: central processor.
    processor_type: u8 = 0x03,
    family: u8 = family_use_family2,
    manufacturer: String,
    id: u64 align(1) = 0,
    version: String,
    /// Bit 7 set: the low 7 bits hold the voltage times 10. 0x80 is 0.0 V.
    voltage: u8 = 0x80,
    external_clock_mhz: u16 align(1) = 0,
    max_speed_mhz: u16 align(1) = 0,
    current_speed_mhz: u16 align(1) = 0,
    /// 0x41: socket populated, CPU enabled.
    status: u8 = 0x41,
    /// 0x06: no upgrade.
    upgrade: u8 = 0x06,
    l1_cache: u16 align(1) = no_cache,
    l2_cache: u16 align(1) = no_cache,
    l3_cache: u16 align(1) = no_cache,
    serial: String,
    asset_tag: String,
    part_number: String,
    core_count: u8 = 0,
    core_enabled: u8 = 0,
    thread_count: u8 = 0,
    /// Bit 2: 64-bit capable.
    characteristics: u16 align(1) = 0x0004,
    family2: u16 align(1) = family2_rv64,
};

pub const OemStrings = extern struct {
    pub const type_id: u8 = 11;

    header: Header,
    count: u8,
};

pub const MemoryArray = extern struct {
    pub const type_id: u8 = 16;
    /// `max_capacity_kb` value that sends the reader to `ext_max_capacity`.
    pub const use_ext_capacity: u32 = 0x8000_0000;
    pub const no_error_info: u16 = 0xfffe;

    header: Header,
    /// 0x03: system board.
    location: u8 = 0x03,
    /// 0x03: system memory.
    use: u8 = 0x03,
    /// 0x03: no error correction.
    error_correction: u8 = 0x03,
    max_capacity_kb: u32 align(1) = 0,
    error_handle: u16 align(1) = no_error_info,
    device_count: u16 align(1),
    /// In bytes. Read only when `max_capacity_kb` is `use_ext_capacity`.
    ext_max_capacity: u64 align(1) = 0,
};

pub const MemoryType = enum(u8) {
    other = 0x01,
    unknown = 0x02,
    dram = 0x03,
    sram = 0x06,
    sdram = 0x0f,
    ddr = 0x12,
    ddr2 = 0x13,
    ddr3 = 0x18,
    ddr4 = 0x1a,
    lpddr4 = 0x1e,
    ddr5 = 0x22,
    lpddr5 = 0x23,
};

pub const FormFactor = enum(u8) {
    other = 0x01,
    unknown = 0x02,
    chip = 0x05,
    dimm = 0x09,
    sodimm = 0x0d,
};

/// Memory Device in the SMBIOS 2.3 layout.
pub const MemoryDevice = extern struct {
    pub const type_id: u8 = 17;
    pub const width_unknown: u16 = 0xffff;
    /// The largest value `size_mb` holds in this layout.
    pub const size_mb_max: u16 = 0x7fff;

    header: Header,
    array_handle: u16 align(1),
    error_handle: u16 align(1) = MemoryArray.no_error_info,
    total_width: u16 align(1),
    data_width: u16 align(1),
    size_mb: u16 align(1) = 0,
    form_factor: FormFactor,
    device_set: u8 = 0,
    device_locator: String,
    bank_locator: String,
    memory_type: MemoryType,
    /// Bit 2: unknown.
    type_detail: u16 align(1) = 0x0004,
    speed: u16 align(1) = 0,
    manufacturer: String,
    serial: String,
    asset_tag: String,
    part_number: String,
};

pub const End = extern struct {
    pub const type_id: u8 = 127;

    header: Header,
};

fn checkLayout(comptime T: type, comptime size: usize) void {
    if (@sizeOf(T) != size or @alignOf(T) != 1) {
        @compileError(@typeName(T) ++ " does not match its SMBIOS layout");
    }
}

comptime {
    checkLayout(Header, 0x04);
    checkLayout(EntryPoint, 0x18);
    checkLayout(Bios, 0x18);
    checkLayout(System, 0x1b);
    checkLayout(Baseboard, 0x0f);
    checkLayout(Chassis, 0x15);
    checkLayout(Processor, 0x2a);
    checkLayout(OemStrings, 0x05);
    checkLayout(MemoryArray, 0x17);
    checkLayout(MemoryDevice, 0x1b);
    checkLayout(End, 0x04);
}

test "fields sit at the offsets the SMBIOS specification gives" {
    try std.testing.expectEqual(@as(usize, 0x0a), @offsetOf(Bios, "characteristics"));
    try std.testing.expectEqual(@as(usize, 0x08), @offsetOf(System, "uuid"));
    try std.testing.expectEqual(@as(usize, 0x0b), @offsetOf(Baseboard, "chassis_handle"));
    try std.testing.expectEqual(@as(usize, 0x0d), @offsetOf(Chassis, "oem_defined"));
    try std.testing.expectEqual(@as(usize, 0x28), @offsetOf(Processor, "family2"));
    try std.testing.expectEqual(@as(usize, 0x0f), @offsetOf(MemoryArray, "ext_max_capacity"));
    try std.testing.expectEqual(@as(usize, 0x0c), @offsetOf(MemoryDevice, "size_mb"));
    try std.testing.expectEqual(@as(usize, 0x10), @offsetOf(EntryPoint, "table_address"));
}

test "a header takes its type and length from the structure" {
    const h = Header.of(Processor, 0x0400);
    try std.testing.expectEqual(@as(u8, 4), h.type);
    try std.testing.expectEqual(@as(u8, 0x2a), h.length);
    try std.testing.expectEqual(@as(u16, 0x0400), h.handle);
}

test "memory types carry their SMBIOS type 17 codes" {
    try std.testing.expectEqual(@as(u8, 0x18), @intFromEnum(MemoryType.ddr3));
    try std.testing.expectEqual(@as(u8, 0x1e), @intFromEnum(MemoryType.lpddr4));
    try std.testing.expectEqual(@as(u8, 0x22), @intFromEnum(MemoryType.ddr5));
    try std.testing.expectEqual(@as(u8, 0x23), @intFromEnum(MemoryType.lpddr5));
}
