//! Uncompressed BMP images with 24 or 32 bits for each pixel, the format that
//! the boot splash and the ACPI BGRT table use. This file has no platform
//! imports, so its tests run on the host.

const std = @import("std");

pub const Error = error{
    /// The file is not a BMP, or it is cut short.
    NotBmp,
    /// A BMP with compression, a palette or another pixel layout.
    Unsupported,
};

pub const Rgb = struct { red: u8, green: u8, blue: u8 };

pub const Image = struct {
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    /// The first row of `pixels` is the top row of the image.
    top_down: bool,
    /// Bytes from one row to the next, a multiple of 4.
    stride: usize,
    pixels: []const u8,

    /// The pixel at column `x` of row `y`, from the top left.
    pub fn pixel(image: Image, x: usize, y: usize) Rgb {
        const row = if (image.top_down) y else image.height - 1 - y;
        const p = image.pixels[row * image.stride + x * image.bytes_per_pixel ..];
        return .{ .red = p[2], .green = p[1], .blue = p[0] };
    }
};

const file_header_len = 14;
const info_header_len = 40;
const bi_rgb = 0;
const bi_bitfields = 3;
// The only masks that BI_BITFIELDS may have: the layout of BI_RGB.
const masks = [3]u32{ 0x00ff_0000, 0x0000_ff00, 0x0000_00ff };

fn int(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub fn parse(bytes: []const u8) Error!Image {
    if (bytes.len < file_header_len + info_header_len) return error.NotBmp;
    if (!std.mem.eql(u8, bytes[0..2], "BM")) return error.NotBmp;
    const offset = int(u32, bytes, 10);
    const header_len = int(u32, bytes, 14);
    if (header_len < info_header_len) return error.Unsupported;
    const width = int(i32, bytes, 18);
    const height = int(i32, bytes, 22);
    const bits = int(u16, bytes, 28);
    const compression = int(u32, bytes, 30);
    if (int(u16, bytes, 26) != 1) return error.NotBmp;
    if (width <= 0 or height == 0) return error.NotBmp;
    if (bits != 24 and bits != 32) return error.Unsupported;
    switch (compression) {
        bi_rgb => {},
        bi_bitfields => {
            // The masks follow a 40 byte header, or are in a longer one.
            const at = file_header_len + info_header_len;
            if (bits != 32 or bytes.len < at + 12) return error.Unsupported;
            for (masks, 0..) |mask, i| {
                if (int(u32, bytes, at + i * 4) != mask) return error.Unsupported;
            }
        },
        else => return error.Unsupported,
    }

    const rows: u32 = @abs(height);
    const stride = (@as(usize, @intCast(width)) * bits + 31) / 32 * 4;
    const size = std.math.mul(usize, stride, rows) catch return error.NotBmp;
    if (offset > bytes.len or bytes.len - offset < size) return error.NotBmp;
    return .{
        .width = @intCast(width),
        .height = rows,
        .bytes_per_pixel = bits / 8,
        .top_down = height < 0,
        .stride = stride,
        .pixels = bytes[offset..][0..size],
    };
}

const testing = std.testing;

/// A BMP with a 40 byte header. Rows go from the top when `top_down` is set.
fn testBmp(comptime width: u32, comptime height: u32, comptime bits: u16, top_down: bool, compression: u32) [54 + 12 + ((width * bits + 31) / 32 * 4) * height]u8 {
    const stride = (width * bits + 31) / 32 * 4;
    var out: [54 + 12 + stride * height]u8 = @splat(0);
    out[0..2].* = "BM".*;
    std.mem.writeInt(u32, out[2..6], out.len, .little);
    std.mem.writeInt(u32, out[10..14], 54 + 12, .little);
    std.mem.writeInt(u32, out[14..18], info_header_len, .little);
    std.mem.writeInt(i32, out[18..22], width, .little);
    std.mem.writeInt(i32, out[22..26], if (top_down) -@as(i32, height) else height, .little);
    std.mem.writeInt(u16, out[26..28], 1, .little);
    std.mem.writeInt(u16, out[28..30], bits, .little);
    std.mem.writeInt(u32, out[30..34], compression, .little);
    for (masks, 0..) |mask, i| std.mem.writeInt(u32, out[54 + i * 4 ..][0..4], mask, .little);
    // Each pixel is blue = column, green = row in the file, red = 0x80.
    for (0..height) |row| {
        for (0..width) |col| {
            const p = out[66 + row * stride + col * (bits / 8) ..];
            p[0] = @intCast(col);
            p[1] = @intCast(row);
            p[2] = 0x80;
        }
    }
    return out;
}

test "a 24 bit image with rows from the bottom" {
    const file = testBmp(3, 2, 24, false, bi_rgb);
    const image = try parse(&file);
    try testing.expectEqual(@as(u32, 3), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    // Three pixels of 3 bytes give 9 bytes, padded to 12.
    try testing.expectEqual(@as(usize, 12), image.stride);
    // The top row is the last row in the file.
    try testing.expectEqual(Rgb{ .red = 0x80, .green = 1, .blue = 2 }, image.pixel(2, 0));
    try testing.expectEqual(Rgb{ .red = 0x80, .green = 0, .blue = 0 }, image.pixel(0, 1));
}

test "a 32 bit image with rows from the top and the standard masks" {
    const file = testBmp(2, 2, 32, true, bi_bitfields);
    const image = try parse(&file);
    try testing.expect(image.top_down);
    try testing.expectEqual(@as(usize, 8), image.stride);
    try testing.expectEqual(Rgb{ .red = 0x80, .green = 0, .blue = 1 }, image.pixel(1, 0));
    try testing.expectEqual(Rgb{ .red = 0x80, .green = 1, .blue = 0 }, image.pixel(0, 1));
}

test "a file that is not a BMP that Weir can draw" {
    const good = testBmp(2, 2, 24, false, bi_rgb);
    try testing.expectError(error.NotBmp, parse(good[0..40]));
    try testing.expectError(error.NotBmp, parse(good[0 .. good.len - 1]));

    var other = good;
    other[0] = 'X';
    try testing.expectError(error.NotBmp, parse(&other));

    var palette = good;
    std.mem.writeInt(u16, palette[28..30], 8, .little);
    try testing.expectError(error.Unsupported, parse(&palette));

    var rle = good;
    std.mem.writeInt(u32, rle[30..34], 1, .little);
    try testing.expectError(error.Unsupported, parse(&rle));

    var odd_masks = testBmp(2, 2, 32, false, bi_bitfields);
    std.mem.writeInt(u32, odd_masks[54..58], 0xff00_0000, .little);
    try testing.expectError(error.Unsupported, parse(&odd_masks));

    var old_header = good;
    std.mem.writeInt(u32, old_header[14..18], 12, .little);
    try testing.expectError(error.Unsupported, parse(&old_header));
}
