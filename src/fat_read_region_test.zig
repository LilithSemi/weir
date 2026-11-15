const std = @import("std");
const conduit = @import("conduit");
const block = @import("block/block.zig");
const fs = @import("fs/fs.zig");
const fat = @import("fs/fat.zig");

const sector_size = 512;
const sector_count = 128;
const eoc: u32 = 0x0fff_ffff;

const Call = struct { lba: u64, count: u32 };

const Disk = struct {
    sectors: [sector_count][sector_size]u8 = @splat(@splat(0)),
    calls: [256]Call = undefined,
    call_count: usize = 0,
    fail_lba: ?u64 = null,
    dev: block.Device = undefined,

    fn read(ctx: ?*anyopaque, lba: u64, count: u32, dst: [*]u8) bool {
        const self: *Disk = @ptrCast(@alignCast(ctx.?));
        if (self.call_count == self.calls.len) return false;
        self.calls[self.call_count] = .{ .lba = lba, .count = count };
        self.call_count += 1;
        if (lba + count > self.sectors.len) return false;
        if (self.fail_lba) |bad| if (lba <= bad and bad < lba + count) return false;
        for (0..count) |i| {
            @memcpy(dst[i * sector_size ..][0..sector_size], &self.sectors[lba + i]);
        }
        return true;
    }

    fn device(self: *Disk) conduit.device.Block {
        return .{
            .ctx = self,
            .block_size = sector_size,
            .num_blocks = self.sectors.len,
            .read_blocks = read,
        };
    }
};

fn write16(buf: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], value, .little);
}

fn write32(buf: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], value, .little);
}

fn setup(disk: *Disk, chain: []const u32) block.Partition {
    return setupWithSpc(disk, chain, 1);
}

fn setupWithSpc(disk: *Disk, chain: []const u32, sectors_per_cluster: u8) block.Partition {
    const bpb = &disk.sectors[0];
    write16(bpb, 11, sector_size);
    bpb[13] = sectors_per_cluster;
    write16(bpb, 14, 1); // Reserved sectors.
    bpb[16] = 1; // FAT count.
    write32(bpb, 32, sector_count);
    write32(bpb, 36, 1); // FAT32 size in sectors.
    write32(bpb, 44, 2); // Root cluster.

    for (chain, 0..) |cluster, i| {
        const next = if (i + 1 < chain.len) chain[i + 1] else eoc;
        write32(&disk.sectors[1], @as(usize, cluster) * 4, next);
        const first_lba = 2 + (cluster - 2) * @as(u32, sectors_per_cluster);
        for (0..sectors_per_cluster) |sector_in_cluster| {
            const lba = first_lba + @as(u32, @intCast(sector_in_cluster));
            for (&disk.sectors[lba], 0..) |*byte, j| {
                byte.* = @truncate(lba * 13 + @as(u32, @intCast(j)));
            }
        }
    }

    disk.dev = disk.device();
    const part = block.Partition{ .dev = &disk.dev, .base_lba = 0, .num_blocks = sector_count };
    _ = fat.mount(part) orelse unreachable;
    disk.call_count = 0;
    return part;
}

fn mountFile(disk: *Disk, chain: []const u32, size: u32) fs.Fs {
    const part = setup(disk, chain);
    const ent = disk.sectors[2][0..32]; // FAT32 root cluster 2 is LBA 2.
    @memcpy(ent[0..11], "KERNEL  EFI");
    ent[11] = 0x20; // archive/regular file
    write16(ent, 20, 0);
    write16(ent, 26, @intCast(chain[0]));
    write32(ent, 28, size);
    return fat.mount(part) orelse unreachable;
}

fn checkChainBytes(out: []const u8, chain: []const u32) !void {
    for (out, 0..) |byte, i| {
        const cluster = chain[i / sector_size];
        const in_sector: u32 = @intCast(i % sector_size);
        try std.testing.expectEqual(@as(u8, @truncate(cluster * 13 + in_sector)), byte);
    }
}

fn dataCalls(disk: *const Disk, out: []u32) usize {
    var n: usize = 0;
    for (disk.calls[0..disk.call_count]) |call| {
        if (call.lba >= 2) {
            if (n < out.len) out[n] = call.count;
            n += 1;
        }
    }
    return n;
}

fn checkBytes(out: []const u8, start_offset: u64, first_cluster: u32) !void {
    for (out, 0..) |byte, i| {
        const file_offset = start_offset + i;
        const cluster = first_cluster + @as(u32, @intCast(file_offset / sector_size));
        const in_sector = @as(u32, @intCast(file_offset % sector_size));
        try std.testing.expectEqual(@as(u8, @truncate(cluster * 13 + in_sector)), byte);
    }
}

fn checkLbaBytes(out: []const u8, start_offset: u64, first_lba: u32) !void {
    for (out, 0..) |byte, i| {
        const file_offset = start_offset + i;
        const lba = first_lba + @as(u32, @intCast(file_offset / sector_size));
        const in_sector = @as(u32, @intCast(file_offset % sector_size));
        try std.testing.expectEqual(@as(u8, @truncate(lba * 13 + in_sector)), byte);
    }
}

test "contiguous clusters coalesce across one-sector cluster boundaries" {
    var disk = Disk{};
    var chain: [40]u32 = undefined;
    for (&chain, 0..) |*cluster, i| cluster.* = @intCast(i + 2);
    _ = setup(&disk, &chain);

    var out: [chain.len * sector_size]u8 = undefined;
    const got = fat.readRegion(chain[0], out.len, 0, &out);
    try std.testing.expectEqual(out.len, got);
    try checkBytes(&out, 0, chain[0]);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), dataCalls(&disk, &counts));
    try std.testing.expectEqual(@as(u32, chain.len), counts[0]);
}

test "fragmented clusters split runs and preserve the chain contents" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3, 20, 21, 22, 40 };
    _ = setup(&disk, &chain);

    var out: [chain.len * sector_size]u8 = undefined;
    const got = fat.readRegion(chain[0], out.len, 0, &out);
    try std.testing.expectEqual(out.len, got);
    for (chain, 0..) |cluster, i| {
        for (out[i * sector_size ..][0..sector_size], 0..) |byte, j| {
            try std.testing.expectEqual(@as(u8, @truncate(cluster * 13 + @as(u32, @intCast(j)))), byte);
        }
    }

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 1 }, counts[0..3]);
}

test "unaligned head and tail use sector bounce without losing contiguous middle" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3, 4, 5, 6 };
    _ = setup(&disk, &chain);

    var out: [1800]u8 = undefined;
    const got = fat.readRegion(chain[0], chain.len * sector_size, 100, &out);
    try std.testing.expectEqual(out.len, got);
    try checkBytes(&out, 100, chain[0]);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 1 }, counts[0..3]);
}

test "short chain stops before advertised size and EOF reads return zero" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3, 4 };
    _ = setup(&disk, &chain);

    var out: [5 * sector_size]u8 = undefined;
    @memset(&out, 0xaa);
    const got = fat.readRegion(chain[0], out.len, 0, &out);
    try std.testing.expectEqual(@as(usize, 3 * sector_size), got);
    try checkBytes(out[0..got], 0, chain[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), out[got]);
    try std.testing.expectEqual(@as(usize, 0), fat.readRegion(chain[0], out.len, out.len, &out));
}

test "a block read error returns the bytes already produced" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3, 20, 21 };
    _ = setup(&disk, &chain);
    disk.fail_lba = 20;

    var out: [chain.len * sector_size]u8 = undefined;
    const got = fat.readRegion(chain[0], out.len, 0, &out);
    try std.testing.expectEqual(@as(usize, 2 * sector_size), got);
    try checkBytes(out[0..got], 0, chain[0]);
}

test "multi-sector clusters keep partial tail on the final cluster" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3 };
    _ = setupWithSpc(&disk, &chain, 4);

    var out: [5 * sector_size + 100]u8 = undefined;
    const file_size = 8 * sector_size;
    const got = fat.readRegion(chain[0], file_size, 0, &out);
    try std.testing.expectEqual(out.len, got);
    try checkLbaBytes(&out, 0, 2);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 5, 1 }, counts[0..2]);
}

test "successive multi-sector reads resume within and across clusters" {
    var disk = Disk{};
    const chain = [_]u32{ 2, 3, 4 };
    _ = setupWithSpc(&disk, &chain, 4);
    const file_size = 12 * sector_size;

    var first: [3 * sector_size]u8 = undefined;
    try std.testing.expectEqual(first.len, fat.readRegion(chain[0], file_size, 0, &first));
    try checkLbaBytes(&first, 0, 2);
    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), dataCalls(&disk, &counts));
    try std.testing.expectEqual(@as(u32, 3), counts[0]);

    disk.call_count = 0;
    var second: [8 * sector_size]u8 = undefined;
    try std.testing.expectEqual(second.len, fat.readRegion(chain[0], file_size, first.len, &second));
    try checkLbaBytes(&second, first.len, 2);
    try std.testing.expectEqual(@as(usize, 1), dataCalls(&disk, &counts));
    try std.testing.expectEqual(@as(u32, 8), counts[0]);
}

test "file read resolves a directory entry, coalesces contiguous clusters, and checks capacity" {
    var disk = Disk{};
    var chain: [40]u32 = undefined;
    for (&chain, 0..) |*cluster, i| cluster.* = @intCast(i + 3);
    const size: u32 = chain.len * sector_size;
    const filesystem = mountFile(&disk, &chain, size);

    var out: [chain.len * sector_size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, out.len), filesystem.readFile("kernel.efi", &out));
    try checkChainBytes(&out, &chain);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 1, 40 }, counts[0..2]);

    var too_small: [out.len - 1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), filesystem.readFile("KERNEL.EFI", &too_small));
    try std.testing.expectEqual(@as(?usize, null), filesystem.readFile("missing.bin", &out));
}

test "file read preserves fragmented cluster order" {
    var disk = Disk{};
    const chain = [_]u32{ 3, 4, 20, 21 };
    const filesystem = mountFile(&disk, &chain, chain.len * sector_size);

    var out: [chain.len * sector_size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, out.len), filesystem.readFile("KERNEL.EFI", &out));
    try checkChainBytes(&out, &chain);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2 }, counts[0..3]);
}

test "file read handles a final partial sector after a coalesced run" {
    var disk = Disk{};
    const chain = [_]u32{ 3, 4, 5 };
    const size: u32 = 2 * sector_size + 100;
    const filesystem = mountFile(&disk, &chain, size);

    var out: [size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, out.len), filesystem.readFile("KERNEL.EFI", &out));
    try checkChainBytes(&out, &chain);

    var counts: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 3), dataCalls(&disk, &counts));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 1 }, counts[0..3]);
}

test "file read returns null on I/O failure after a prior fragmented run" {
    var disk = Disk{};
    const chain = [_]u32{ 3, 4, 20, 21 };
    const filesystem = mountFile(&disk, &chain, chain.len * sector_size);
    disk.fail_lba = 20;

    var out: [chain.len * sector_size]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), filesystem.readFile("KERNEL.EFI", &out));
}

test "file read reports an intentionally short malformed FAT chain" {
    var disk = Disk{};
    const chain = [_]u32{ 3, 4 };
    const advertised_size: u32 = 3 * sector_size;
    const filesystem = mountFile(&disk, &chain, advertised_size);

    var out: [advertised_size]u8 = undefined;
    @memset(&out, 0xaa);
    const got = filesystem.readFile("KERNEL.EFI", &out) orelse return error.ExpectedShortRead;
    try std.testing.expectEqual(@as(usize, 2 * sector_size), got);
    try checkChainBytes(out[0..got], &chain);
    try std.testing.expectEqual(@as(u8, 0xaa), out[got]);
}
