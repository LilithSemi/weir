//! Assemble the combined `weir.img` flash image. It reads the SoC device tree
//! for the flash size and the `river-fsbl`/`river-firmware` partition offsets,
//! then lays the FSBL and the packed firmware into a zero-filled image at those
//! offsets. The offsets are the same ones fdt2ld links the FSBL against (both
//! tools share tools/fdt_bases.zig), so the image and the linker script cannot
//! drift. The result flashes straight to the SPI-NOR: FSBL runs XIP from its
//! partition, and it loads the firmware from its partition.
//!
//! Usage: mkflash <dtb-path> <fsbl-bin> <packed-fw-bin> <out-path>
//!   dtb-path : the SoC device tree, or "" to use the defaults in fdt_bases.

const std = @import("std");
const dtree = @import("dtree");
const fdt_bases = @import("fdt_bases");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // zippy:ignore discarded_error -- the tool ignores the program name arg
    const dtb_path = args.next() orelse return error.Usage;
    const fsbl_path = args.next() orelse return error.Usage;
    const fw_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    var bases: fdt_bases.Bases = .{};
    if (dtb_path.len != 0) {
        const file = if (std.fs.path.isAbsolute(dtb_path))
            try std.Io.Dir.openFileAbsolute(io, dtb_path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, dtb_path, .{});
        defer file.close(io);
        const fdt = try dtree.Reader.initFile(gpa, io, file);
        defer fdt.deinit();
        fdt_bases.parse(&fdt, &bases);
    }

    const fsbl = try std.Io.Dir.cwd().readFileAlloc(io, fsbl_path, gpa, .unlimited);
    defer gpa.free(fsbl);
    const fw = try std.Io.Dir.cwd().readFileAlloc(io, fw_path, gpa, .unlimited);
    defer gpa.free(fw);

    // The FSBL must sit inside its own partition. When the tree gives a firmware
    // offset above the FSBL, that is the FSBL partition end. An overlap means
    // the FSBL image is larger than its slot, which would corrupt the firmware.
    if (bases.fw_off > bases.fsbl_off and bases.fsbl_off + fsbl.len > bases.fw_off)
        return error.FsblOverflowsPartition;

    // Size the image to the flash window. Fall back to the end of the firmware
    // image when the tree carries no flash size.
    const image_size = if (bases.flash_size != 0) bases.flash_size else bases.fw_off + fw.len;
    if (bases.fsbl_off + fsbl.len > image_size) return error.FsblExceedsFlash;
    if (bases.fw_off + fw.len > image_size) return error.FirmwareExceedsFlash;

    const out = if (std.fs.path.isAbsolute(out_path))
        try std.Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.setLength(io, image_size);
    try out.writePositionalAll(io, fsbl, bases.fsbl_off);
    try out.writePositionalAll(io, fw, bases.fw_off);
}
