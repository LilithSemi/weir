//! The boot splash: a BMP drawn at the center of a display. This file has no
//! platform imports, so its tests run on the host.

const std = @import("std");
const bmp = @import("bmp.zig");
const gop = @import("gop.zig");

pub const Offset = struct { x: u32, y: u32 };

/// Draws `image` at the center of `surface` and gives its top left corner.
/// Null when the image is larger than the screen, and then nothing is drawn.
pub fn draw(surface: gop.Surface, image: bmp.Image) ?Offset {
    const mode = surface.mode;
    if (image.width > mode.width or image.height > mode.height) return null;
    const offset: Offset = .{ .x = (mode.width - image.width) / 2, .y = (mode.height - image.height) / 2 };
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const rgb = image.pixel(x, y);
            surface.put(offset.x + x, offset.y + y, .{ .red = rgb.red, .green = rgb.green, .blue = rgb.blue, .reserved = 0 });
        }
    }
    return offset;
}

const testing = std.testing;

// A 2x1 image: a red pixel, then a blue pixel, as a bottom-up 24 bit BMP.
const two_pixels: bmp.Image = .{
    .width = 2,
    .height = 1,
    .bytes_per_pixel = 3,
    .top_down = false,
    .stride = 8,
    .pixels = &.{ 0, 0, 0xff, 0xff, 0, 0, 0, 0 },
};

test "the image goes to the center in the format of the screen" {
    var storage: [4 * 3 * 4]u8 = @splat(0);
    const surface: gop.Surface = .{
        .pixels = &storage,
        .mode = .{ .width = 4, .height = 3, .stride = 16, .format = .xrgb8888 },
    };
    try testing.expectEqual(Offset{ .x = 1, .y = 1 }, draw(surface, two_pixels).?);
    // Row 1, columns 1 and 2, as blue, green, red, unused bytes.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff, 0xff, 0, 0, 0xff }, storage[16 + 4 ..][0..8]);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), storage[0..16]);

    var narrow: [4 * 3 * 2]u8 = @splat(0);
    const rgb565: gop.Surface = .{
        .pixels = &narrow,
        .mode = .{ .width = 4, .height = 3, .stride = 8, .format = .rgb565 },
    };
    _ = draw(rgb565, two_pixels).?;
    try testing.expectEqual(@as(u16, 0xf800), std.mem.readInt(u16, narrow[8 + 2 ..][0..2], .little));
    try testing.expectEqual(@as(u16, 0x001f), std.mem.readInt(u16, narrow[8 + 4 ..][0..2], .little));
}

test "an image larger than the screen is not drawn" {
    var storage: [2]u8 = @splat(0xaa);
    const surface: gop.Surface = .{
        .pixels = &storage,
        .mode = .{ .width = 1, .height = 1, .stride = 2, .format = .rgb565 },
    };
    try testing.expectEqual(@as(?Offset, null), draw(surface, two_pixels));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, &storage);
}
