//! Driver for the register block of the Harbor scanout display. The display
//! shows a framebuffer in the SDRAM at the address in FB_BASE.

const std = @import("std");
const gop = @import("gop.zig");

const ctrl = 0x00;
const fb_base = 0x10;
const fb_stride = 0x18;
const h_active = 0x20;
const v_active = 0x30;
const format = 0x58;

const ctrl_enable: u32 = 1 << 0;

/// Volatile 32-bit access at a fixed base address.
pub const Mmio = struct {
    base: usize,

    pub fn read(self: Mmio, off: usize) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        return ptr.*;
    }

    pub fn write(self: Mmio, off: usize, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        ptr.* = value;
    }
};

pub fn Display(comptime Bus: type) type {
    return struct {
        const Self = @This();

        bus: Bus,

        /// The mode of the build. Null when the format is one that Weir does
        /// not draw or the registers do not describe a screen.
        pub fn mode(self: Self) ?gop.Mode {
            const found: gop.Mode = .{
                .width = self.bus.read(h_active),
                .height = self.bus.read(v_active),
                .stride = self.bus.read(fb_stride),
                .format = gop.Format.fromCode(self.bus.read(format)) orelse return null,
            };
            return if (found.valid()) found else null;
        }

        /// Shows the framebuffer at `address`. The display takes the address
        /// and the enable bit together at the next frame start.
        pub fn start(self: Self, address: u32) void {
            self.bus.write(fb_base, address);
            self.bus.write(ctrl, ctrl_enable);
        }
    };
}

/// The alignment of a framebuffer address. Each line must start on a new row
/// of the SDRAM, and the stride is a whole number of rows.
pub fn alignment(stride: u32) usize {
    const row = @as(usize, 1) << @intCast(@ctz(stride));
    return @max(row, 4096);
}

const testing = std.testing;

const Fake = struct {
    regs: [0x68 / 8]u32 = @splat(0),
    writes: [4]usize = @splat(0),
    write_count: usize = 0,

    pub fn read(self: *Fake, off: usize) u32 {
        return self.regs[off / 8];
    }

    pub fn write(self: *Fake, off: usize, value: u32) void {
        self.regs[off / 8] = value;
        self.writes[self.write_count] = off;
        self.write_count += 1;
    }

    fn screen(width: u32, height: u32, stride: u32, code: u32) Fake {
        var fake: Fake = .{};
        fake.regs[h_active / 8] = width;
        fake.regs[v_active / 8] = height;
        fake.regs[fb_stride / 8] = stride;
        fake.regs[format / 8] = code;
        return fake;
    }
};

test "the mode comes from the registers" {
    var fake = Fake.screen(640, 480, 2048, 0);
    const display: Display(*Fake) = .{ .bus = &fake };
    const mode = display.mode().?;
    try testing.expectEqual(@as(u32, 640), mode.width);
    try testing.expectEqual(@as(u32, 480), mode.height);
    try testing.expectEqual(@as(u32, 2048), mode.stride);
    try testing.expectEqual(gop.Format.rgb565, mode.format);
}

test "a format that Weir does not draw or an empty screen gives no mode" {
    var packed_rgb = Fake.screen(640, 480, 2048, 1);
    try testing.expect((Display(*Fake){ .bus = &packed_rgb }).mode() == null);
    var empty = Fake.screen(0, 480, 2048, 0);
    try testing.expect((Display(*Fake){ .bus = &empty }).mode() == null);
    var narrow = Fake.screen(640, 480, 1024, 0);
    try testing.expect((Display(*Fake){ .bus = &narrow }).mode() == null);
}

test "start writes the address before the enable bit" {
    var fake = Fake.screen(640, 480, 2048, 0);
    const display: Display(*Fake) = .{ .bus = &fake };
    display.start(0x81e0_0000);
    try testing.expectEqual(@as(usize, 2), fake.write_count);
    try testing.expectEqual(@as(usize, fb_base), fake.writes[0]);
    try testing.expectEqual(@as(usize, ctrl), fake.writes[1]);
    try testing.expectEqual(@as(u32, 0x81e0_0000), fake.regs[fb_base / 8]);
    try testing.expectEqual(@as(u32, 1), fake.regs[ctrl / 8]);
}

test "the address alignment is a page or a row of the stride" {
    try testing.expectEqual(@as(usize, 4096), alignment(2048));
    try testing.expectEqual(@as(usize, 4096), alignment(3 * 1024));
    try testing.expectEqual(@as(usize, 8192), alignment(8192));
    try testing.expectEqual(@as(usize, 16384), alignment(3 * 16384));
}
