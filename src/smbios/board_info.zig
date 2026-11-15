//! Board identity for the SMBIOS tables.
//!
//! Harbor writes these fields to a `board.zon` file next to the device tree.
//! Every field has a default, so a file can give any subset.

const structs = @import("structs.zig");

pub const Cpu = struct {
    model: []const u8,
    /// The ISA string, for example "rv64imac".
    isa: []const u8 = "",
    harts: u16 = 1,
    clock_hz: u64 = 0,
};

pub const Memory = struct {
    type: structs.MemoryType,
    form_factor: structs.FormFactor,
    /// Data width in bits. 0xffff is unknown.
    width_bits: u16,
    /// Set for soldered memory. Null means the RAM size found at boot.
    size_bytes: ?u64 = null,
    /// Set for socketed memory: the largest module the SoC can map.
    max_size_bytes: ?u64 = null,
};

pub const Board = struct {
    preset: []const u8,
    fpga_part: []const u8 = "",
};

pub const BoardInfo = struct {
    vendor: []const u8 = "Lilith Semiconductor",
    /// Null means the `model` of the device tree root.
    product: ?[]const u8 = null,
    family: []const u8 = "River",
    version: []const u8 = "1.0",
    sku: []const u8 = "0",
    chassis_type: structs.ChassisType = .desktop,
    cpu: ?Cpu = null,
    memory: []const Memory = &.{},
    board: ?Board = null,
};
