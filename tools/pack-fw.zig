//! Prepend the WEIR image header the FSBL reads to a raw firmware image, so the
//! result can be flashed to the `river-firmware` partition. src/fsbl/flash.zig
//! reads this header to find and size the main image.
//!
//! Usage: pack-fw <input> <output>
//! Output layout: 4-byte little-endian magic 'WEIR', 4-byte little-endian
//! length, then the input bytes.

const std = @import("std");

const MAGIC: u32 = 0x52494557; // 'WEIR' little-endian

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // zippy:ignore discarded_error -- the tool ignores the program name arg
    const in_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;

    const image = try std.Io.Dir.cwd().readFileAlloc(io, in_path, gpa, .unlimited);
    defer gpa.free(image);

    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], MAGIC, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(image.len), .little);

    const out = if (std.fs.path.isAbsolute(out_path))
        try std.Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, &header);
    try out.writeStreamingAll(io, image);
}
