//! A block device whose blocks are bytes in RAM. The contents come from
//! another source, such as an image that the firmware read from a server.

const std = @import("std");
const conduit = @import("conduit");

pub const block_size = 512;

pub const RamDisk = struct {
    /// The whole blocks of the image. A part of a block at the end is not used.
    bytes: []u8,

    pub fn block(self: *RamDisk) conduit.device.Block {
        return .{
            .ctx = self,
            .block_size = block_size,
            .num_blocks = self.bytes.len / block_size,
            .read_blocks = readBlocks,
            .write_blocks = writeBlocks,
        };
    }

    fn span(self: *const RamDisk, lba: u64, count: u32) ?[]u8 {
        const blocks = self.bytes.len / block_size;
        if (lba > blocks or count > blocks - lba) return null;
        const start: usize = @intCast(lba * block_size);
        return self.bytes[start..][0 .. @as(usize, count) * block_size];
    }

    fn readBlocks(ctx: ?*anyopaque, lba: u64, count: u32, buf: [*]u8) bool {
        const self: *const RamDisk = @ptrCast(@alignCast(ctx));
        const from = self.span(lba, count) orelse return false;
        @memcpy(buf[0..from.len], from);
        return true;
    }

    fn writeBlocks(ctx: ?*anyopaque, lba: u64, count: u32, buf: [*]const u8) bool {
        const self: *const RamDisk = @ptrCast(@alignCast(ctx));
        const to = self.span(lba, count) orelse return false;
        @memcpy(to, buf[0..to.len]);
        return true;
    }
};

const testing = std.testing;

test "blocks read back what was written" {
    var bytes: [4 * block_size + 100]u8 = @splat(0);
    var disk: RamDisk = .{ .bytes = &bytes };
    const dev = disk.block();
    try testing.expectEqual(@as(u64, 4), dev.num_blocks);

    var data: [2 * block_size]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7);
    try testing.expect(dev.writeBlocks(2, 2, &data));
    var back: [2 * block_size]u8 = @splat(0);
    try testing.expect(dev.readBlocks(2, 2, &back));
    try testing.expectEqualSlices(u8, &data, &back);
    try testing.expectEqual(@as(u8, 0), bytes[2 * block_size - 1]);
}

test "a range past the end fails" {
    var bytes: [4 * block_size]u8 = @splat(0);
    var disk: RamDisk = .{ .bytes = &bytes };
    const dev = disk.block();
    var buf: [2 * block_size]u8 = undefined;
    try testing.expect(!dev.readBlocks(3, 2, &buf));
    try testing.expect(!dev.readBlocks(5, 1, &buf));
    try testing.expect(!dev.writeBlocks(std.math.maxInt(u64), 1, &buf));
    try testing.expect(dev.readBlocks(4, 0, &buf));
}
