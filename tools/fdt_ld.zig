//! Build-time linker-script generator. Parses the SoC device tree with the
//! shared `dtree` reader and emits the linker script whose addresses come from
//! that same description the firmware boots with - so build.zig never hand-rolls
//! a flattened-tree parser.
//!
//! Usage: fdt-ld <dtb-path> <kind:main|fsbl> <out-path> [region-hex]
//!   main : firmware image linked at the DRAM /memory base.
//!   fsbl : XIP first-stage - .text/.rodata in the SPI-NOR flash window, and
//!          .data/.bss/stack in the DRAM window (region-hex bytes), .data's load
//!          image in flash. creek has no SRAM, so DRAM is the only writable RAM.

const std = @import("std");
const dtree = @import("dtree");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // program name
    const dtb_path = args.next() orelse return error.Usage;
    const kind = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const region_str = args.next(); // optional (fsbl only)

    // Defaults for a build with no -Ddtb: match the has_dtb=false SoC description
    // in src/soc.zig (QEMU virt - RAM at 0x80000000, SPI-NOR flash at 0x20000000),
    // so the default firmware links at the same base the SoC boots with. Board
    // builds (e.g. creek) pass -Ddtb and the bases come from the tree instead.
    var flash_base: u64 = 0x20000000;
    var ram_base: u64 = 0x80000000;
    var ram_size: u64 = 0x08000000; // 128 MiB (only used by the fsbl layout)
    // On-chip SRAM window (compatible "mmio-sram"), 0 if the tree has none.
    // When present the FSBL puts its scratch (stack/.data/.bss) HERE instead of
    // the top of DRAM, so the FSBL can bring up + read-train the DDR without
    // needing a working DRAM read first (the boot-strap fragility that blocked
    // running the DDR below its overclock).
    var sram_base: u64 = 0;
    var sram_size: u64 = 0;
    // Byte offset of the `river-fsbl` partition within the flash. The FSBL XIPs
    // from here, ABOVE the fpga-bitstream slot on an FPGA. 0 (flash base) when
    // the tree carries no partition map (legacy layout / ASIC at offset 0).
    var fsbl_off: u64 = 0;
    // The `river-firmware` partition: where the main Weir image lives + its max
    // size. Defaults match the historical -Dfsbl-main-offset/-max when the tree
    // carries no partition map.
    var fw_off: u64 = 0x100000;
    var fw_max: u64 = 16 << 20;

    if (dtb_path.len != 0) {
        const file = if (std.fs.path.isAbsolute(dtb_path))
            try std.Io.Dir.openFileAbsolute(io, dtb_path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, dtb_path, .{});
        defer file.close(io);
        const fdt = try dtree.Reader.initFile(gpa, io, file);
        defer fdt.deinit();
        parseBases(&fdt, &flash_base, &ram_base, &ram_size, &sram_base, &sram_size, &fsbl_off, &fw_off, &fw_max);
    }

    const script = if (std.mem.eql(u8, kind, "fsbl")) blk: {
        const region: u64 = if (region_str) |s| try std.fmt.parseInt(u64, s, 0) else 0x4000;
        // Prefer on-chip SRAM for the FSBL scratch when the tree has it: the FSBL
        // then runs its stack/.data/.bss out of SRAM and never reads DRAM before
        // it has brought DDR up and read-trained it. Without SRAM (legacy creek),
        // fall back to the TOP of the DRAM window - the FSBL scratch MUST NOT sit
        // at ram_base or main Weir's (bottom-loaded) image copy overwrites the
        // FSBL's own live stack/con mid-flight (silent self-corruption).
        var origin = ram_base + ram_size - region;
        var len = region;
        if (sram_size != 0) {
            origin = sram_base;
            len = sram_size;
        }
        // The FSBL executes XIP from the `river-fsbl` partition, so its FLASH
        // ORIGIN is flash_base + fsbl_off (clears the fpga-bitstream slot). The
        // main image offset + max come from the `river-firmware` partition,
        // lowered to the _fsbl_main_offset/_max absolute symbols.
        break :blk try std.fmt.allocPrint(gpa, fsbl_template, .{ flash_base + fsbl_off, origin, len, fw_off, fw_max });
    } else try std.fmt.allocPrint(gpa, main_template, .{ram_base});

    const out = if (std.fs.path.isAbsolute(out_path))
        try std.Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, script);
}

/// Single pass over the tree: capture the DRAM /memory base+size and the SPI-NOR
/// (jedec,spi-nor) flash base, honouring the root's #address-cells/#size-cells so
/// 1-cell (32-bit) and 2-cell (64-bit) trees both parse.
fn parseBases(fdt: *const dtree.Reader, flash: *u64, ram: *u64, ram_size: *u64, sram: *u64, sram_size: *u64, fsbl_off: *u64, fw_off: *u64, fw_max: *u64) void {
    var iter = fdt.nodeIterator();
    var addr_cells: u32 = 2; // DT default
    var size_cells: u32 = 1; // DT default
    var addr_set = false;
    var size_set = false;
    var in_mem = false;
    var in_flash = false;
    var in_sram = false;
    // A `fixed-partitions` leaf (`partition@NNN`): captures its reg offset+size
    // (1 address + 1 size cell, so the first 8 bytes) and which known label it
    // carries, decided at node end so the reg/label prop order does not matter.
    // river-fsbl -> FSBL XIP origin; river-firmware -> main image offset + max.
    var in_partition = false;
    var part_off: u64 = 0;
    var part_size: u64 = 0;
    var part_is_fsbl = false;
    var part_is_firmware = false;
    while (iter.next() catch return) |node| {
        switch (node) {
            .begin => |bn| {
                in_mem = std.mem.startsWith(u8, bn.name, "memory") and
                    (bn.name.len == 6 or bn.name[6] == '@');
                in_flash = false; // set below if this node is compatible "jedec,spi-nor"
                in_sram = false; // set below if this node is compatible "mmio-sram"
                in_partition = std.mem.startsWith(u8, bn.name, "partition@");
                if (in_partition) {
                    part_off = 0;
                    part_size = 0;
                    part_is_fsbl = false;
                    part_is_firmware = false;
                }
            },
            .end => {
                if (in_partition and part_is_fsbl) fsbl_off.* = part_off;
                if (in_partition and part_is_firmware) {
                    fw_off.* = part_off;
                    fw_max.* = part_size;
                }
                in_mem = false;
                in_flash = false;
                in_sram = false;
                in_partition = false;
            },
            .prop => |p| {
                if (in_partition) {
                    // Partition reg = <offset size> under the container's
                    // #address-cells=1/#size-cells=1: offset is the first cell,
                    // size the second.
                    if (std.mem.eql(u8, p.name, "reg") and p.value.len >= 8) {
                        part_off = std.mem.readInt(u32, p.value[0..4], .big);
                        part_size = std.mem.readInt(u32, p.value[4..8], .big);
                    }
                    if (std.mem.eql(u8, p.name, "label")) {
                        if (std.mem.indexOf(u8, p.value, "river-fsbl") != null)
                            part_is_fsbl = true;
                        if (std.mem.indexOf(u8, p.value, "river-firmware") != null)
                            part_is_firmware = true;
                    }
                }
                if (!addr_set and std.mem.eql(u8, p.name, "#address-cells") and p.value.len >= 4) {
                    addr_cells = std.mem.readInt(u32, p.value[0..4], .big);
                    addr_set = true;
                }
                if (!size_set and std.mem.eql(u8, p.name, "#size-cells") and p.value.len >= 4) {
                    size_cells = std.mem.readInt(u32, p.value[0..4], .big);
                    size_set = true;
                }
                if (std.mem.eql(u8, p.name, "compatible")) {
                    if (std.mem.indexOf(u8, p.value, "jedec,spi-nor") != null) in_flash = true;
                    if (std.mem.indexOf(u8, p.value, "mmio-sram") != null) in_sram = true;
                }
                if (std.mem.eql(u8, p.name, "reg") and p.value.len >= (addr_cells + size_cells) * 4) {
                    var base: u64 = 0;
                    var i: u32 = 0;
                    while (i < addr_cells) : (i += 1) {
                        base = (base << 32) | std.mem.readInt(u32, p.value[i * 4 ..][0..4], .big);
                    }
                    var size: u64 = 0;
                    var j: u32 = 0;
                    while (j < size_cells) : (j += 1) {
                        size = (size << 32) | std.mem.readInt(u32, p.value[(addr_cells + j) * 4 ..][0..4], .big);
                    }
                    if (in_mem) {
                        ram.* = base;
                        ram_size.* = size;
                    }
                    if (in_flash) flash.* = base;
                    if (in_sram) {
                        sram.* = base;
                        sram_size.* = size;
                    }
                }
            },
        }
    }
}

const main_template =
    \\/* Generated by tools/fdt_ld.zig from the SoC device tree. Firmware image
    \\ * layout for RISC-V; loaded at the start of RAM in M-mode; reset = _start. */
    \\ENTRY(_start)
    \\RAM_BASE = 0x{x};
    \\STACK_SIZE = 0x10000; /* 64 KiB per-hart (must stay 1 << 16; see start.zig) */
    \\MAX_HARTS = 8;
    \\SECTIONS
    \\{{
    \\    . = RAM_BASE;
    \\    .text : {{ KEEP(*(.text.boot)) *(.text .text.*) }}
    \\    . = ALIGN(8);
    \\    .rodata : {{ *(.rodata .rodata.* .srodata .srodata.*) }}
    \\    . = ALIGN(8);
    \\    __rodata_end = .;
    \\    .data : {{ PROVIDE(__global_pointer$ = . + 0x800); *(.data .data.* .sdata .sdata.*) }}
    \\    . = ALIGN(8);
    \\    .bss (NOLOAD) : {{ __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON) . = ALIGN(8); __bss_end = .; }}
    \\    . = ALIGN(16);
    \\    .noinit (NOLOAD) : {{ *(.noinit .noinit.*) }}
    \\    . = ALIGN(16);
    \\    _stacks_bottom = .;
    \\    . = . + STACK_SIZE * MAX_HARTS;
    \\    _stacks_top = .;
    \\    /DISCARD/ : {{ *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.riscv.attributes) }}
    \\}}
    \\
;

const fsbl_template =
    \\/* Generated by tools/fdt_ld.zig from the SoC device tree. XIP first-stage:
    \\ * .text/.rodata execute in place from the SPI-NOR flash window; writable
    \\ * .data/.bss and the stack live in the DRAM window (the dcache backs it as
    \\ * scratch until the FSBL brings DDR up). .data's load image is in flash and
    \\ * _start copies it. creek has no SRAM, so DRAM is the only writable RAM. */
    \\ENTRY(_start)
    \\MEMORY
    \\{{
    \\    FLASH (rx)  : ORIGIN = 0x{x}, LENGTH = 0x100000
    \\    RAM   (rwx) : ORIGIN = 0x{x}, LENGTH = 0x{x}
    \\}}
    \\SECTIONS
    \\{{
    \\    .text : {{ KEEP(*(.text.boot)) *(.text .text.*) }} > FLASH
    \\    .rodata : {{ *(.rodata .rodata.* .srodata .srodata.*) }} > FLASH
    \\    .data : {{ PROVIDE(__global_pointer$ = . + 0x800); *(.data .data.* .sdata .sdata.*) }} > RAM AT> FLASH
    \\    _data_lma = LOADADDR(.data);
    \\    _data_vma = ADDR(.data);
    \\    _data_end = _data_vma + SIZEOF(.data);
    \\    .bss (NOLOAD) : {{ __bss_start = .; *(.bss .bss.* .sbss .sbss.* COMMON); . = ALIGN(8); __bss_end = .; }} > RAM
    \\    /DISCARD/ : {{ *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.riscv.attributes) }}
    \\}}
    \\_stack_top = ORIGIN(RAM) + LENGTH(RAM);
    \\/* Main-image flash layout from the `river-firmware` DT partition. Absolute
    \\ * symbols: config.zig reads their ADDRESS as the value (no build flag). */
    \\_fsbl_main_offset = 0x{x};
    \\_fsbl_main_max = 0x{x};
    \\
;
