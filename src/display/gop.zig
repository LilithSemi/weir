//! The mode description and the block transfers of the graphics output
//! protocol, on a framebuffer in memory. This file has no platform imports,
//! so its tests run on the host.

const std = @import("std");
const Gop = std.os.uefi.protocol.GraphicsOutput;

pub const BltPixel = Gop.BltPixel;
pub const BltOperation = Gop.BltOperation;

/// A pixel layout of the framebuffer. The values are the Harbor format codes.
pub const Format = enum(u32) {
    /// 16 bits, little-endian, red in bits 15:11.
    rgb565 = 0,
    /// Bytes blue, green, red, unused.
    xrgb8888 = 2,
    /// Bytes blue, green, red, alpha.
    argb8888 = 3,

    pub fn fromCode(code: u32) ?Format {
        return switch (code) {
            0 => .rgb565,
            2 => .xrgb8888,
            3 => .argb8888,
            else => null,
        };
    }

    pub fn bytes(format: Format) usize {
        return switch (format) {
            .rgb565 => 2,
            .xrgb8888, .argb8888 => 4,
        };
    }

    pub fn name(format: Format) []const u8 {
        return switch (format) {
            .rgb565 => "r5g6b5",
            .xrgb8888 => "x8r8g8b8",
            .argb8888 => "a8r8g8b8",
        };
    }
};

pub const Mode = struct {
    width: u32,
    height: u32,
    /// Bytes from one line to the next.
    stride: u32,
    format: Format,

    /// False for a mode that has no pixels or whose lines overlap.
    pub fn valid(mode: Mode) bool {
        if (mode.width == 0 or mode.height == 0) return false;
        if (mode.stride % mode.format.bytes() != 0) return false;
        return @as(u64, mode.width) * mode.format.bytes() <= mode.stride;
    }

    /// The bytes of the framebuffer.
    pub fn size(mode: Mode) usize {
        return @as(usize, mode.stride) * mode.height;
    }

    pub fn info(mode: Mode) Gop.Mode.Info {
        return .{
            .version = 0,
            .horizontal_resolution = mode.width,
            .vertical_resolution = mode.height,
            .pixel_format = switch (mode.format) {
                .rgb565 => .bit_mask,
                .xrgb8888, .argb8888 => .blue_green_red_reserved_8_bit_per_color,
            },
            .pixel_information = switch (mode.format) {
                .rgb565 => .{ .red_mask = 0xf800, .green_mask = 0x07e0, .blue_mask = 0x001f, .reserved_mask = 0 },
                .xrgb8888, .argb8888 => .{ .red_mask = 0, .green_mask = 0, .blue_mask = 0, .reserved_mask = 0 },
            },
            .pixels_per_scan_line = @intCast(mode.stride / mode.format.bytes()),
        };
    }
};

pub const Surface = struct {
    pixels: [*]u8,
    mode: Mode,

    fn at(surface: Surface, x: usize, y: usize) [*]u8 {
        return surface.pixels + y * surface.mode.stride + x * surface.mode.format.bytes();
    }

    fn put(surface: Surface, x: usize, y: usize, pixel: BltPixel) void {
        const p = surface.at(x, y);
        switch (surface.mode.format) {
            .rgb565 => {
                const value = (@as(u16, pixel.red >> 3) << 11) | (@as(u16, pixel.green >> 2) << 5) | (pixel.blue >> 3);
                std.mem.writeInt(u16, p[0..2], value, .little);
            },
            .xrgb8888, .argb8888 => p[0..4].* = .{ pixel.blue, pixel.green, pixel.red, 0xff },
        }
    }

    fn get(surface: Surface, x: usize, y: usize) BltPixel {
        const p = surface.at(x, y);
        switch (surface.mode.format) {
            .rgb565 => {
                const value = std.mem.readInt(u16, p[0..2], .little);
                const red: u8 = @truncate(value >> 11);
                const green: u8 = @truncate((value >> 5) & 0x3f);
                const blue: u8 = @truncate(value & 0x1f);
                return .{
                    .red = (red << 3) | (red >> 2),
                    .green = (green << 2) | (green >> 4),
                    .blue = (blue << 3) | (blue >> 2),
                    .reserved = 0,
                };
            },
            .xrgb8888, .argb8888 => return .{ .blue = p[0], .green = p[1], .red = p[2], .reserved = 0 },
        }
    }

    /// Makes all of the framebuffer black.
    pub fn clear(surface: Surface) void {
        @memset(surface.pixels[0..surface.mode.size()], 0);
    }

    fn inside(surface: Surface, x: usize, y: usize, width: usize, height: usize) bool {
        const right = std.math.add(usize, x, width) catch return false;
        const bottom = std.math.add(usize, y, height) catch return false;
        return right <= surface.mode.width and bottom <= surface.mode.height;
    }

    /// One block transfer of the protocol. `delta` is the bytes of one line of
    /// `buffer`, or 0 when a line has `width` pixels.
    pub fn blt(
        surface: Surface,
        buffer: ?[*]BltPixel,
        operation: BltOperation,
        source_x: usize,
        source_y: usize,
        dest_x: usize,
        dest_y: usize,
        width: usize,
        height: usize,
        delta: usize,
    ) error{InvalidParameter}!void {
        if (width == 0 or height == 0) return error.InvalidParameter;
        const pitch = if (delta == 0) width else delta / @sizeOf(BltPixel);
        switch (operation) {
            .blt_video_fill => {
                const color = (buffer orelse return error.InvalidParameter)[0];
                if (!surface.inside(dest_x, dest_y, width, height)) return error.InvalidParameter;
                for (0..height) |row| {
                    for (0..width) |col| surface.put(dest_x + col, dest_y + row, color);
                }
            },
            .blt_video_to_blt_buffer => {
                const out = buffer orelse return error.InvalidParameter;
                if (!surface.inside(source_x, source_y, width, height)) return error.InvalidParameter;
                for (0..height) |row| {
                    const line = out + (dest_y + row) * pitch + dest_x;
                    for (0..width) |col| line[col] = surface.get(source_x + col, source_y + row);
                }
            },
            .blt_buffer_to_video => {
                const in = buffer orelse return error.InvalidParameter;
                if (!surface.inside(dest_x, dest_y, width, height)) return error.InvalidParameter;
                for (0..height) |row| {
                    const line = in + (source_y + row) * pitch + source_x;
                    for (0..width) |col| surface.put(dest_x + col, dest_y + row, line[col]);
                }
            },
            .blt_video_to_video => {
                if (!surface.inside(source_x, source_y, width, height)) return error.InvalidParameter;
                if (!surface.inside(dest_x, dest_y, width, height)) return error.InvalidParameter;
                const len = width * surface.mode.format.bytes();
                // The row order keeps a row that is still a source from an
                // earlier write. One row can overlap itself, so it moves.
                for (0..height) |i| {
                    const row = if (dest_y > source_y) height - 1 - i else i;
                    const from = surface.at(source_x, source_y + row)[0..len];
                    const to = surface.at(dest_x, dest_y + row)[0..len];
                    @memmove(to, from);
                }
            },
            else => return error.InvalidParameter,
        }
    }
};

const testing = std.testing;

fn testSurface(storage: []u8, format: Format) Surface {
    @memset(storage, 0xee);
    const mode: Mode = .{ .width = 4, .height = 3, .stride = 24, .format = format };
    return .{ .pixels = storage.ptr, .mode = mode };
}

const pure_red: BltPixel = .{ .red = 0xff, .green = 0, .blue = 0, .reserved = 0 };
const teal: BltPixel = .{ .red = 0x10, .green = 0x80, .blue = 0xf8, .reserved = 0 };

fn expectPixel(want: BltPixel, got: BltPixel) !void {
    try testing.expectEqual(want.red, got.red);
    try testing.expectEqual(want.green, got.green);
    try testing.expectEqual(want.blue, got.blue);
}

test "the mode information of an rgb565 mode has the bit masks" {
    const mode: Mode = .{ .width = 640, .height = 480, .stride = 2048, .format = .rgb565 };
    try testing.expect(mode.valid());
    try testing.expectEqual(@as(usize, 983040), mode.size());
    const info = mode.info();
    try testing.expectEqual(@as(u32, 640), info.horizontal_resolution);
    try testing.expectEqual(@as(u32, 480), info.vertical_resolution);
    try testing.expectEqual(Gop.PixelFormat.bit_mask, info.pixel_format);
    try testing.expectEqual(@as(u32, 0xf800), info.pixel_information.red_mask);
    try testing.expectEqual(@as(u32, 0x07e0), info.pixel_information.green_mask);
    try testing.expectEqual(@as(u32, 0x001f), info.pixel_information.blue_mask);
    try testing.expectEqual(@as(u32, 1024), info.pixels_per_scan_line);
}

test "the mode information of a 32 bit mode is blue green red" {
    const mode: Mode = .{ .width = 640, .height = 480, .stride = 4096, .format = .xrgb8888 };
    const info = mode.info();
    try testing.expectEqual(Gop.PixelFormat.blue_green_red_reserved_8_bit_per_color, info.pixel_format);
    try testing.expectEqual(@as(u32, 1024), info.pixels_per_scan_line);
}

test "a mode with no pixels or with lines that overlap is not valid" {
    const good: Mode = .{ .width = 4, .height = 3, .stride = 8, .format = .rgb565 };
    try testing.expect(good.valid());
    var bad = good;
    bad.width = 0;
    try testing.expect(!bad.valid());
    bad = good;
    bad.stride = 6;
    try testing.expect(!bad.valid());
    bad = good;
    bad.stride = 9;
    try testing.expect(!bad.valid());
    try testing.expect(Format.fromCode(1) == null);
    try testing.expectEqual(Format.argb8888, Format.fromCode(3).?);
}

test "a fill writes rgb565 words and leaves the rest of the line" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .rgb565);
    var color = [_]BltPixel{pure_red};
    try surface.blt(&color, .blt_video_fill, 0, 0, 1, 1, 2, 1, 0);
    // Line 1 starts at byte 24. Pixel 1 is at byte 26.
    try testing.expectEqualSlices(u8, &.{ 0xee, 0xee, 0x00, 0xf8, 0x00, 0xf8, 0xee, 0xee }, storage[24..32]);
    try testing.expectEqual(@as(u8, 0xee), storage[23]);
    try testing.expectEqual(@as(u8, 0xee), storage[48]);
}

test "a fill writes blue green red bytes in a 32 bit mode" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .xrgb8888);
    var color = [_]BltPixel{teal};
    try surface.blt(&color, .blt_video_fill, 0, 0, 3, 2, 1, 1, 0);
    try testing.expectEqualSlices(u8, &.{ 0xf8, 0x80, 0x10, 0xff }, storage[48 + 12 ..][0..4]);
}

test "a buffer goes to the video and comes back with its line pitch" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .xrgb8888);
    // A buffer of 3 by 2 pixels. The transfer takes the 2 by 2 block at x 1.
    var in: [6]BltPixel = undefined;
    for (&in, 0..) |*p, i| p.* = .{ .red = @intCast(i), .green = @intCast(i * 2), .blue = @intCast(i * 3), .reserved = 0 };
    try surface.blt(&in, .blt_buffer_to_video, 1, 0, 2, 1, 2, 2, 3 * @sizeOf(BltPixel));
    try expectPixel(in[1], surface.get(2, 1));
    try expectPixel(in[2], surface.get(3, 1));
    try expectPixel(in[4], surface.get(2, 2));
    try expectPixel(in[5], surface.get(3, 2));

    var out: [4]BltPixel = undefined;
    try surface.blt(&out, .blt_video_to_blt_buffer, 2, 1, 0, 0, 2, 2, 0);
    try expectPixel(in[1], out[0]);
    try expectPixel(in[2], out[1]);
    try expectPixel(in[4], out[2]);
    try expectPixel(in[5], out[3]);
}

test "an rgb565 pixel comes back with its high bits" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .rgb565);
    var color = [_]BltPixel{teal};
    try surface.blt(&color, .blt_video_fill, 0, 0, 0, 0, 1, 1, 0);
    const got = surface.get(0, 0);
    try testing.expectEqual(@as(u8, 0x10), got.red);
    try testing.expectEqual(@as(u8, 0x82), got.green);
    try testing.expectEqual(@as(u8, 0xff), got.blue);
}

test "a video to video transfer that overlaps moves down and up" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .rgb565);
    for (0..3) |y| {
        for (0..4) |x| surface.put(x, y, .{ .red = @intCast(y * 64 + 8), .green = 0, .blue = @intCast(x * 32 + 8), .reserved = 0 });
    }
    const top = surface.get(1, 0);
    const middle = surface.get(1, 1);
    try surface.blt(null, .blt_video_to_video, 0, 0, 0, 1, 4, 2, 0);
    try expectPixel(top, surface.get(1, 1));
    try expectPixel(middle, surface.get(1, 2));
    try surface.blt(null, .blt_video_to_video, 0, 1, 0, 0, 4, 2, 0);
    try expectPixel(top, surface.get(1, 0));
    try expectPixel(middle, surface.get(1, 1));
}

test "a transfer outside the screen or with no buffer is refused" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .rgb565);
    var color = [_]BltPixel{pure_red};
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .blt_video_fill, 0, 0, 3, 0, 2, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .blt_video_fill, 0, 0, 0, 2, 1, 2, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .blt_video_fill, 0, 0, 0, 0, 0, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(null, .blt_video_fill, 0, 0, 0, 0, 1, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(null, .blt_buffer_to_video, 0, 0, 0, 0, 1, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .blt_video_to_video, 0, 0, 1, 0, 4, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .graphics_output_blt_operation_max, 0, 0, 0, 0, 1, 1, 0));
    try testing.expectError(error.InvalidParameter, surface.blt(&color, .blt_video_fill, std.math.maxInt(usize), 0, std.math.maxInt(usize), 0, 2, 1, 0));
}

test "clear makes each byte of the framebuffer zero" {
    var storage: [72]u8 = undefined;
    const surface = testSurface(&storage, .rgb565);
    surface.clear();
    try testing.expectEqualSlices(u8, &@as([72]u8, @splat(0)), &storage);
}
