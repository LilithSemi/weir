//! Address-map values that build-time host tools read from the SoC device tree.
//! Both the linker-script generator (fdt2ld.zig) and the flash-image assembler
//! (mkflash.zig) parse the same tree through this module, so the FSBL link
//! offsets and the offsets the image places them at can never drift.
//!
//! The `dtree` reader does the flattened-tree walk. This module only maps the
//! nodes it cares about to the fields below.

const std = @import("std");
const dtree = @import("dtree");

/// Address-map values for the flash layout and the linker script. `parse` fills
/// them from a device tree. The field defaults match the has_dtb=false SoC
/// description in src/soc.zig (QEMU virt: RAM at 0x80000000, SPI-NOR flash at
/// 0x20000000). This way a build with no -Ddtb uses the same bases the SoC
/// boots with. Board builds (creek, delta) pass -Ddtb and take the bases from
/// the tree instead.
pub const Bases = struct {
    flash_base: u64 = 0x20000000,
    /// Total size of the SPI-NOR flash window. mkflash makes the image this
    /// large. 0 when the tree has no flash reg size, so callers fall back.
    flash_size: u64 = 0,
    ram_base: u64 = 0x80000000,
    ram_size: u64 = 0x08000000, // 128 MiB. Only the fsbl layout uses this.
    /// On-chip SRAM window (compatible "mmio-sram"), 0 when the tree has none.
    /// When it exists the FSBL puts its scratch (stack/.data/.bss) here, not at
    /// the top of DRAM. The FSBL then brings up and read-trains the DDR without
    /// a working DRAM read first. That boot-strap fragility blocked running the
    /// DDR below its overclock.
    sram_base: u64 = 0,
    sram_size: u64 = 0,
    /// Byte offset of the `river-fsbl` partition in the flash. The FSBL XIPs
    /// from here, above the fpga-bitstream slot on an FPGA. It is 0 (flash base)
    /// when the tree carries no partition map (legacy layout, or ASIC at 0).
    fsbl_off: u64 = 0,
    /// The `river-firmware` partition. This is where the main Weir image lives.
    fw_off: u64 = 0x100000,
    /// Max size of the main Weir image. The defaults match the historical
    /// -Dfsbl-main-offset and -Dfsbl-main-max flags when the tree carries no
    /// partition map.
    fw_max: u64 = 16 << 20,
};

/// Per-node state gathered while descending the tree. A node's `reg` is decoded
/// with its PARENT's #address-cells/#size-cells; whether the node is memory,
/// flash, or an SRAM window is decided at its `.end`, so the `reg`, `compatible`,
/// and `label` property order does not matter.
const Node = struct {
    /// #address-cells/#size-cells this node declares for its children. The DT
    /// default is 2 address cells + 1 size cell.
    addr_cells: u32 = 2,
    size_cells: u32 = 1,
    is_mem: bool = false,
    is_flash: bool = false,
    is_sram: bool = false,
    is_partition: bool = false,
    reg_base: u64 = 0,
    reg_size: u64 = 0,
    reg_valid: bool = false,
    part_off: u64 = 0,
    part_size: u64 = 0,
    part_is_fsbl: bool = false,
    part_is_firmware: bool = false,
};

/// Fill `out` in one pass over the tree: the DRAM /memory base and size, the
/// SPI-NOR (jedec,spi-nor) flash base and size, the SRAM window, and the
/// `river-fsbl`/`river-firmware` partition offsets. It tracks #address-cells/
/// #size-cells per node level (a node's `reg` uses its parent's counts), so a
/// flash node under a 1-cell bus in a 2-cell-root tree still parses. 1-cell
/// (32-bit) and 2-cell (64-bit) trees both work.
pub fn parse(fdt: *const dtree.Reader, out: *Bases) void {
    var iter = fdt.nodeIterator();
    // One entry per open node. stack[0] is the implicit root parent (holding the
    // DT default cells); sp indexes the current node. 24 levels is far more than
    // any real tree nests; deeper nodes reuse the deepest slot.
    var stack = [_]Node{.{}} ** 24;
    var sp: usize = 0;

    while (iter.next() catch return) |node| {
        switch (node) {
            .begin => |bn| {
                if (sp + 1 < stack.len) sp += 1;
                stack[sp] = .{
                    .is_mem = std.mem.startsWith(u8, bn.name, "memory") and
                        (bn.name.len == 6 or bn.name[6] == '@'),
                    .is_partition = std.mem.startsWith(u8, bn.name, "partition@"),
                };
            },
            .end => {
                const nd = stack[sp];
                if (nd.reg_valid) {
                    if (nd.is_mem) {
                        out.ram_base = nd.reg_base;
                        out.ram_size = nd.reg_size;
                    }
                    if (nd.is_flash) {
                        out.flash_base = nd.reg_base;
                        out.flash_size = nd.reg_size;
                    }
                    if (nd.is_sram) {
                        out.sram_base = nd.reg_base;
                        out.sram_size = nd.reg_size;
                    }
                }
                if (nd.is_partition and nd.part_is_fsbl) out.fsbl_off = nd.part_off;
                if (nd.is_partition and nd.part_is_firmware) {
                    out.fw_off = nd.part_off;
                    out.fw_max = nd.part_size;
                }
                if (sp > 0) sp -= 1;
            },
            .prop => |p| {
                const cur = &stack[sp];
                // #address-cells/#size-cells set THIS node's counts, for its
                // children. Its own reg (below) uses the parent's.
                if (std.mem.eql(u8, p.name, "#address-cells") and p.value.len >= 4)
                    cur.addr_cells = std.mem.readInt(u32, p.value[0..4], .big);
                if (std.mem.eql(u8, p.name, "#size-cells") and p.value.len >= 4)
                    cur.size_cells = std.mem.readInt(u32, p.value[0..4], .big);
                if (std.mem.eql(u8, p.name, "compatible")) {
                    if (std.mem.indexOf(u8, p.value, "jedec,spi-nor") != null) cur.is_flash = true;
                    if (std.mem.indexOf(u8, p.value, "mmio-sram") != null) cur.is_sram = true;
                }
                // A `fixed-partitions` leaf's reg = <offset size> (1 cell each);
                // its label names the slot. river-fsbl gives the FSBL XIP origin,
                // river-firmware the main image offset and max.
                if (cur.is_partition) {
                    if (std.mem.eql(u8, p.name, "reg") and p.value.len >= 8) {
                        cur.part_off = std.mem.readInt(u32, p.value[0..4], .big);
                        cur.part_size = std.mem.readInt(u32, p.value[4..8], .big);
                    }
                    if (std.mem.eql(u8, p.name, "label")) {
                        if (std.mem.indexOf(u8, p.value, "river-fsbl") != null) cur.part_is_fsbl = true;
                        if (std.mem.indexOf(u8, p.value, "river-firmware") != null) cur.part_is_firmware = true;
                    }
                }
                // A node's reg is decoded with its parent's cell counts.
                const parent = if (sp > 0) stack[sp - 1] else Node{};
                const reg_bytes = (parent.addr_cells + parent.size_cells) * 4;
                if (std.mem.eql(u8, p.name, "reg") and p.value.len >= reg_bytes) {
                    var base: u64 = 0;
                    var i: u32 = 0;
                    while (i < parent.addr_cells) : (i += 1) {
                        base = (base << 32) | std.mem.readInt(u32, p.value[i * 4 ..][0..4], .big);
                    }
                    var size: u64 = 0;
                    var j: u32 = 0;
                    while (j < parent.size_cells) : (j += 1) {
                        const off = (parent.addr_cells + j) * 4;
                        size = (size << 32) | std.mem.readInt(u32, p.value[off..][0..4], .big);
                    }
                    cur.reg_base = base;
                    cur.reg_size = size;
                    cur.reg_valid = true;
                }
            },
        }
    }
}
