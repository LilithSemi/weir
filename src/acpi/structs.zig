//! ACPI structure layouts that Weir writes itself, from ACPI 6.6 and the
//! Microsoft SPCR specification. Multi-byte fields have `align(1)` so no struct
//! has padding.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // The tables get these structs as raw bytes, and ACPI is little-endian.
    if (builtin.cpu.arch.endian() != .little) @compileError("ACPI layouts need a little-endian target");
}

/// Length of the SDT header in front of every table body.
pub const sdt_header_len = 36;

/// Generic Address Structure.
pub const Gas = extern struct {
    /// 0: system memory.
    space_id: u8 = 0,
    bit_width: u8,
    bit_offset: u8 = 0,
    /// 1: byte access. 3: dword access.
    access_size: u8,
    address: u64 align(1),
};

/// SPCR revision 2 body.
pub const SpcrBody = extern struct {
    /// 0: full 16550.
    interface_type: u8 = 0,
    reserved0: [3]u8 = @splat(0),
    base_address: Gas,
    /// 0: no interrupt, the console is polled.
    interrupt_type: u8 = 0,
    irq: u8 = 0,
    gsi: u32 align(1) = 0,
    /// 7: 115200.
    baud_rate: u8,
    parity: u8 = 0,
    stop_bits: u8,
    flow_control: u8 = 0,
    terminal_type: u8 = 0,
    language: u8 = 0,
    /// 0xffff: not a PCI device.
    pci_device_id: u16 align(1) = 0xffff,
    pci_vendor_id: u16 align(1) = 0xffff,
    pci_bus: u8 = 0,
    pci_device: u8 = 0,
    pci_function: u8 = 0,
    pci_flags: u32 align(1) = 0,
    pci_segment: u8 = 0,
    reserved1: u32 align(1) = 0,
};

pub const RhctBody = extern struct {
    flags: u32 align(1) = 0,
    timebase_hz: u64 align(1),
    node_count: u32 align(1),
    /// Offset of the first node from the start of the table.
    node_offset: u32 align(1),
};

pub const RhctNodeType = enum(u16) {
    isa_string = 0,
    mmu = 2,
    hart_info = 0xffff,
};

pub const RhctNodeHeader = extern struct {
    type: RhctNodeType align(1),
    length: u16 align(1),
    revision: u16 align(1) = 1,
};

/// The ISA string and its pad follow this struct.
pub const RhctIsaNode = extern struct {
    header: RhctNodeHeader,
    /// String length with the NUL terminator.
    isa_length: u16 align(1),
};

pub const RhctMmuNode = extern struct {
    header: RhctNodeHeader = .{ .type = .mmu, .length = @sizeOf(RhctMmuNode) },
    reserved: u8 = 0,
    /// 0: Sv39. 1: Sv48. 2: Sv57.
    mmu_type: u8,
};

/// A hart info node with two offsets: the ISA node and the MMU node.
pub const RhctHartInfo = extern struct {
    header: RhctNodeHeader = .{ .type = .hart_info, .length = @sizeOf(RhctHartInfo) },
    offset_count: u16 align(1) = 2,
    uid: u32 align(1),
    /// Offsets of the nodes this hart uses, from the start of the table.
    offsets: [2]u32 align(1),
};

/// MADT RISC-V Interrupt Controller structure (type 0x18).
pub const MadtRintc = extern struct {
    pub const type_id: u8 = 0x18;
    pub const flag_enabled: u32 = 1;

    type: u8 = type_id,
    length: u8 = @sizeOf(MadtRintc),
    version: u8 = 1,
    reserved: u8 = 0,
    flags: u32 align(1),
    hart_id: u64 align(1),
    uid: u32 align(1),
    ext_intc_id: u32 align(1),
    /// Zero: a PLIC system has no IMSIC.
    imsic_base: u64 align(1) = 0,
    imsic_size: u32 align(1) = 0,
};

/// MADT RISC-V Platform-Level Interrupt Controller structure (type 0x1B).
pub const MadtPlic = extern struct {
    pub const type_id: u8 = 0x1b;

    type: u8 = type_id,
    length: u8 = @sizeOf(MadtPlic),
    version: u8 = 1,
    id: u8,
    hw_id: [8]u8,
    num_irqs: u16 align(1),
    max_priority: u16 align(1),
    /// ACPI 6.6 defines no flags.
    flags: u32 align(1) = 0,
    size: u32 align(1),
    base: u64 align(1),
    gsi_base: u32 align(1),
};

fn checkLayout(comptime T: type, comptime size: usize) void {
    if (@sizeOf(T) != size or @alignOf(T) != 1) {
        @compileError(@typeName(T) ++ " does not match its ACPI layout");
    }
}

comptime {
    checkLayout(Gas, 12);
    checkLayout(SpcrBody, 44);
    checkLayout(RhctBody, 20);
    checkLayout(RhctNodeHeader, 6);
    checkLayout(RhctIsaNode, 8);
    checkLayout(RhctMmuNode, 8);
    checkLayout(RhctHartInfo, 20);
    checkLayout(MadtRintc, 36);
    checkLayout(MadtPlic, 36);
}
