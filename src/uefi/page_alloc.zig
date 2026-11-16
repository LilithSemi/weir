//! Page and pool allocators for the EFI boot services.
//!
//! The extent allocator keeps a fixed table of free extents in address order.
//! It never reads or writes the memory it manages. The pool puts a header in
//! front of each block. Both have no platform imports, so their tests run on
//! the host.

const std = @import("std");

pub const Extent = struct { start: usize, end: usize };

/// An allocator with room for `capacity` free extents. Every address and size
/// is a multiple of `unit`. An argument that is not is rejected.
pub fn ExtentAllocator(comptime capacity: usize, comptime unit: usize) type {
    comptime if (capacity < 2) @compileError("an extent table needs at least two slots");
    comptime if (!std.math.isPowerOfTwo(unit)) @compileError("the unit must be a power of two");

    return struct {
        const Self = @This();

        base: usize,
        end: usize,
        extents: [capacity]Extent,
        count: usize,
        /// Freed blocks lost because the table was full.
        dropped: usize,

        /// One free extent over the whole units in [base, end). An empty range
        /// gives no extents.
        pub fn init(base: usize, end: usize) Self {
            const start = std.math.add(usize, base, unit - 1) catch end;
            const lo = start & ~(unit - 1);
            const hi = end & ~(unit - 1);
            var self: Self = .{ .base = lo, .end = hi, .extents = undefined, .count = 0, .dropped = 0 };
            if (lo < hi) {
                self.extents[0] = .{ .start = lo, .end = hi };
                self.count = 1;
            } else {
                self.end = lo;
            }
            return self;
        }

        fn aligned(value: usize) bool {
            return value & (unit - 1) == 0;
        }

        /// First fit from the lowest address. The block is aligned to the power
        /// of two `alignment` (at least one unit) and ends at or below `limit`.
        /// When the table is full, an extent that the block would split in two
        /// is skipped.
        pub fn alloc(self: *Self, size: usize, requested_alignment: usize, limit: usize) ?usize {
            if (size == 0 or !aligned(size)) return null;
            if (requested_alignment == 0 or !std.math.isPowerOfTwo(requested_alignment)) return null;
            const alignment = @max(requested_alignment, unit);
            var i: usize = 0;
            while (i < self.count) : (i += 1) {
                const e = self.extents[i];
                // The aligned start only grows from one extent to the next, so
                // an overflow or a block past the limit ends the search.
                const start = std.math.add(usize, e.start, alignment - 1) catch return null;
                const block_start = start & ~(alignment - 1);
                const block_end = std.math.add(usize, block_start, size) catch return null;
                if (block_end > limit) return null;
                if (block_end > e.end) continue;
                if (self.carve(i, block_start, block_end)) return block_start;
            }
            return null;
        }

        /// Take [addr, addr + size) if all of it is free.
        pub fn allocAt(self: *Self, addr: usize, size: usize) bool {
            if (size == 0 or !aligned(addr) or !aligned(size)) return false;
            const block_end = std.math.add(usize, addr, size) catch return false;
            const i = self.find(addr) orelse return false;
            if (block_end > self.extents[i].end) return false;
            return self.carve(i, addr, block_end);
        }

        /// Return [addr, addr + size). A range outside the managed range or one
        /// that overlaps free memory is ignored.
        pub fn free(self: *Self, addr: usize, size: usize) void {
            if (size == 0 or !aligned(addr) or !aligned(size)) return;
            const block_end = std.math.add(usize, addr, size) catch return;
            if (addr < self.base or block_end > self.end) return;

            var i: usize = 0;
            while (i < self.count and self.extents[i].end <= addr) : (i += 1) {}
            if (i < self.count and self.extents[i].start < block_end) return;

            const merge_low = i > 0 and self.extents[i - 1].end == addr;
            const merge_high = i < self.count and self.extents[i].start == block_end;
            if (merge_low and merge_high) {
                self.extents[i - 1].end = self.extents[i].end;
                self.remove(i);
            } else if (merge_low) {
                self.extents[i - 1].end = block_end;
            } else if (merge_high) {
                self.extents[i].start = addr;
            } else if (self.count == capacity) {
                self.dropped += 1;
            } else {
                self.insert(i, .{ .start = addr, .end = block_end });
            }
        }

        /// True when all of [addr, addr + size) is free.
        pub fn isFree(self: *const Self, addr: usize, size: usize) bool {
            if (size == 0 or !aligned(addr) or !aligned(size)) return false;
            const block_end = std.math.add(usize, addr, size) catch return false;
            const i = self.find(addr) orelse return false;
            return block_end <= self.extents[i].end;
        }

        pub fn freeBytes(self: *const Self) usize {
            var total: usize = 0;
            for (self.freeExtents()) |e| total += e.end - e.start;
            return total;
        }

        /// The free extents in address order.
        pub fn freeExtents(self: *const Self) []const Extent {
            return self.extents[0..self.count];
        }

        fn find(self: *const Self, addr: usize) ?usize {
            for (self.freeExtents(), 0..) |e, i| {
                if (e.start <= addr and addr < e.end) return i;
            }
            return null;
        }

        // Take [start, end) out of extent i, which holds all of it. False when
        // the extent splits in two and the table is full.
        fn carve(self: *Self, i: usize, start: usize, end: usize) bool {
            const e = self.extents[i];
            std.debug.assert(e.start <= start and start < end and end <= e.end);
            const pad = start > e.start;
            const tail = end < e.end;
            if (pad and tail) {
                if (self.count == capacity) return false;
                self.extents[i].end = start;
                self.insert(i + 1, .{ .start = end, .end = e.end });
            } else if (pad) {
                self.extents[i].end = start;
            } else if (tail) {
                self.extents[i].start = end;
            } else {
                self.remove(i);
            }
            return true;
        }

        fn insert(self: *Self, i: usize, e: Extent) void {
            std.debug.assert(self.count < capacity and i <= self.count);
            var j = self.count;
            while (j > i) : (j -= 1) self.extents[j] = self.extents[j - 1];
            self.extents[i] = e;
            self.count += 1;
        }

        fn remove(self: *Self, i: usize) void {
            std.debug.assert(i < self.count);
            var j = i;
            while (j + 1 < self.count) : (j += 1) self.extents[j] = self.extents[j + 1];
            self.count -= 1;
        }
    };
}

pub const page_size = 4096;
pub const PageAllocator = ExtentAllocator(64, page_size);

/// The header in front of each pool block. `size` is the size of the whole
/// block, header included.
pub const PoolHeader = extern struct { size: u64, magic: u64 };
pub const pool_magic: u64 = 0x4c4f_4f50_5249_4557;
/// Small pool blocks round up to this size, so they free into few extents.
pub const pool_granule = 64;
/// A pool request of this size or more, with its header, takes whole pages.
pub const large_block = 32 * 1024;
pub const chunk_size = 64 * 1024;
pub const max_chunks = 16;

const ChunkAllocator = ExtentAllocator(32, pool_granule);

comptime {
    if (@sizeOf(PoolHeader) != 16) @compileError("the pool header must keep the data 16 byte aligned");
}

/// AllocatePool and FreePool on top of a page allocator. A small block comes
/// from a chunk of pages with its own extent allocator. A large block, or a
/// small one when the chunk table is full, takes whole pages.
pub const Pool = struct {
    pages: *PageAllocator,
    chunks: [max_chunks]ChunkAllocator,
    in_use: [max_chunks]bool,

    pub fn init(pages: *PageAllocator) Pool {
        return .{ .pages = pages, .chunks = undefined, .in_use = @splat(false) };
    }

    /// The address of a 16 byte aligned buffer of `size` bytes, or null.
    pub fn alloc(self: *Pool, size: usize) ?usize {
        const total = std.math.add(usize, size, @sizeOf(PoolHeader)) catch return null;
        const block = if (total >= large_block) self.allocPages(total) else self.allocSmall(total);
        const b = block orelse return null;
        const header: *PoolHeader = @ptrFromInt(b.start);
        header.* = .{ .size = b.end - b.start, .magic = pool_magic };
        return b.start + @sizeOf(PoolHeader);
    }

    fn allocPages(self: *Pool, total: usize) ?Extent {
        const padded = std.math.add(usize, total, page_size - 1) catch return null;
        const size = padded & ~@as(usize, page_size - 1);
        const start = self.pages.alloc(size, page_size, std.math.maxInt(usize)) orelse return null;
        return .{ .start = start, .end = start + size };
    }

    fn allocSmall(self: *Pool, total: usize) ?Extent {
        const size = std.mem.alignForward(usize, total, pool_granule);
        for (&self.chunks, self.in_use) |*c, used| {
            if (!used) continue;
            if (c.alloc(size, pool_granule, std.math.maxInt(usize))) |start| return .{ .start = start, .end = start + size };
        }
        for (&self.chunks, &self.in_use) |*c, *used| {
            if (used.*) continue;
            const base = self.pages.alloc(chunk_size, page_size, std.math.maxInt(usize)) orelse return null;
            c.* = .init(base, base + chunk_size);
            used.* = true;
            const start = c.alloc(size, pool_granule, std.math.maxInt(usize)).?;
            return .{ .start = start, .end = start + size };
        }
        return self.allocPages(total);
    }

    /// Free the buffer at `addr`. False when `addr` has no live pool header.
    pub fn free(self: *Pool, addr: usize) bool {
        const pages = self.pages;
        if (addr % @sizeOf(PoolHeader) != 0 or addr < @sizeOf(PoolHeader)) return false;
        const block = addr - @sizeOf(PoolHeader);
        if (block < pages.base or block >= pages.end) return false;
        const header: *PoolHeader = @ptrFromInt(block);
        if (header.magic != pool_magic or header.size == 0 or header.size > pages.end - block) return false;
        const size: usize = @intCast(header.size);

        for (&self.chunks, &self.in_use) |*c, *used| {
            if (!used.* or block < c.base or block >= c.end) continue;
            if (size % pool_granule != 0 or size > c.end - block) return false;
            header.magic = 0;
            c.free(block, size);
            if (c.freeBytes() == chunk_size) {
                pages.free(c.base, chunk_size);
                used.* = false;
            }
            return true;
        }
        if (block % page_size != 0 or size % page_size != 0) return false;
        header.magic = 0;
        pages.free(block, size);
        return true;
    }

    pub fn chunkCount(self: *const Pool) usize {
        var n: usize = 0;
        for (self.in_use) |u| n += @intFromBool(u);
        return n;
    }
};

const testing = std.testing;
const mib: usize = 1 << 20;
const test_base: usize = 0x8400_0000;
const test_end: usize = test_base + 64 * mib;

fn expectExtents(a: anytype, want: []const Extent) !void {
    try testing.expectEqualSlices(Extent, want, a.freeExtents());
}

test "init gives one extent over the range" {
    const a = PageAllocator.init(test_base, test_end);
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "init of an empty range gives no extents" {
    var a = PageAllocator.init(test_base, test_base);
    try testing.expectEqual(@as(usize, 0), a.freeExtents().len);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, std.math.maxInt(usize)));
}

test "alloc is first fit from the lowest address" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(4096, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(8192, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 3 * 4096), a.alloc(4096, 4096, test_end));
    try expectExtents(&a, &.{.{ .start = test_base + 4 * 4096, .end = test_end }});
}

test "alloc takes the lowest hole that fits" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(4096, 4096, test_end).?;
    const y = a.alloc(4 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    a.free(x, 4096);
    a.free(y, 4 * 4096);
    // The hole is five pages long. A two page block goes to its start.
    try testing.expectEqual(@as(?usize, x), a.alloc(2 * 4096, 4096, test_end));
}

test "init rounds the range in to whole pages" {
    const a = PageAllocator.init(test_base + 64, test_end - 64);
    try expectExtents(&a, &.{.{ .start = test_base + 4096, .end = test_end - 4096 }});
    try testing.expectEqual(test_base + 4096, a.base);
    try testing.expectEqual(test_end - 4096, a.end);
    const b = PageAllocator.init(test_base + 64, test_base + 4000);
    try testing.expectEqual(@as(usize, 0), b.freeExtents().len);
}

test "alloc aligns to 4 KiB and to the unit when asked for less" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(4096, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(4096, 8, test_end));
    try testing.expectEqual(@as(?usize, test_base + 2 * 4096), a.alloc(4096, 1, test_end));
}

test "arguments that are not whole pages are rejected" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(2 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    const before = a;
    try testing.expectEqual(@as(?usize, null), a.alloc(100, 4096, test_end));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096 + 64, 4096, test_end));
    try testing.expect(!a.allocAt(test_end - 2 * 4096 + 64, 4096));
    try testing.expect(!a.allocAt(test_end - 2 * 4096, 100));
    a.free(x + 64, 4096);
    a.free(x, 100);
    a.free(x, 4096 + 64);
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(test_end - 4096 + 64, 64));
    try testing.expect(!a.isFree(test_end - 4096, 64));
}

test "alloc aligns to 2 MiB" {
    var a = PageAllocator.init(test_base, test_end);
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expectEqual(@as(?usize, test_base + 2 * mib), a.alloc(2 * mib, 2 * mib, test_end));
    // A small block still fits in the pad below the aligned block.
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(4096, 4096, test_end));
}

test "alloc rejects an alignment that is not a power of two" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 0, test_end));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 3 * 4096, test_end));
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "alloc of size zero gives null" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(0, 4096, test_end));
}

test "alloc keeps the block at or below the limit" {
    var a = PageAllocator.init(test_base, test_end);
    const limit = test_base + 8192;
    try testing.expectEqual(@as(?usize, test_base), a.alloc(8192, 4096, limit));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, limit));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, test_base));
}

test "alloc of the whole range is an exact fit" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(64 * mib, 4096, test_end));
    try testing.expectEqual(@as(usize, 0), a.freeExtents().len);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, test_end));
}

test "alloc fills a hole of exactly its size" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(3 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    a.free(x, 3 * 4096);
    try testing.expectEqual(@as(?usize, x), a.alloc(3 * 4096, 4096, test_end));
    try testing.expectEqual(@as(usize, 1), a.freeExtents().len);
}

test "alloc larger than the range gives null" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(64 * mib + 4096, 4096, test_end));
}

test "allocAt inside one extent splits it in two" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base + mib, mib));
    try expectExtents(&a, &.{
        .{ .start = test_base, .end = test_base + mib },
        .{ .start = test_base + 2 * mib, .end = test_end },
    });
}

test "allocAt at the start and the end of an extent" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base, mib));
    try testing.expect(a.allocAt(test_end - mib, mib));
    try expectExtents(&a, &.{.{ .start = test_base + mib, .end = test_end - mib }});
}

test "allocAt on a partly used range fails and changes nothing" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base + mib, mib));
    const before = a;
    try testing.expect(!a.allocAt(test_base + mib / 2, mib));
    try testing.expect(!a.allocAt(test_base + mib + mib / 2, mib));
    try testing.expect(!a.allocAt(test_base, 4 * mib));
    try expectExtents(&a, before.freeExtents());
}

test "allocAt outside the range fails" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expect(!a.allocAt(test_base - 4096, 8192));
    try testing.expect(!a.allocAt(test_end - 4096, 8192));
    try testing.expect(!a.allocAt(test_end, 4096));
    try testing.expect(!a.allocAt(test_base, 0));
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "free in allocation order returns to one extent" {
    var a = PageAllocator.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    for (blocks) |b| a.free(b, 4096);
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "free in reverse order returns to one extent" {
    var a = PageAllocator.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    var i: usize = blocks.len;
    while (i > 0) {
        i -= 1;
        a.free(blocks[i], 4096);
    }
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "free merges with the lower, the upper and both neighbours" {
    var a = PageAllocator.init(test_base, test_end);
    var blocks: [5]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    // Free the middle block first: it has no free neighbour.
    a.free(blocks[2], 4096);
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    // Merges with the upper neighbour only.
    a.free(blocks[1], 4096);
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    try testing.expect(a.isFree(blocks[1], 2 * 4096));
    // Merges with the lower neighbour only.
    a.free(blocks[3], 4096);
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    try testing.expect(a.isFree(blocks[1], 3 * 4096));
    // Merges with both: the free run and the tail of the range.
    a.free(blocks[4], 4096);
    try expectExtents(&a, &.{
        .{ .start = test_base + 4096, .end = test_end },
    });
    a.free(blocks[0], 4096);
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "alloc after free gives the same address" {
    var a = PageAllocator.init(test_base, test_end);
    _ = a.alloc(4096, 4096, test_end).?;
    const x = a.alloc(5 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    a.free(x, 5 * 4096);
    try testing.expectEqual(@as(?usize, x), a.alloc(5 * 4096, 4096, test_end));
}

test "a double free is ignored" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(4096, 4096, test_end).?;
    const y = a.alloc(4096, 4096, test_end).?;
    a.free(x, 4096);
    const before = a;
    a.free(x, 4096);
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(y, 4096));
}

test "a free of a range that is half free is ignored in full" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(2 * 4096, 4096, test_end).?;
    const y = a.alloc(4096, 4096, test_end).?;
    a.free(x, 4096);
    const before = a;
    // The first page is free, the second is not.
    a.free(x, 2 * 4096);
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(x + 4096, 4096));
    // The block below the tail extent, and one page of the tail.
    a.free(y, 2 * 4096);
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(y, 4096));
}

test "a free that covers a free extent is ignored in full" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(3 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    a.free(x + 4096, 4096);
    const before = a;
    a.free(x, 3 * 4096);
    try expectExtents(&a, before.freeExtents());
}

test "a full table drops a block that cannot merge and counts it" {
    const Small = ExtentAllocator(4, page_size);
    var a = Small.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    // Blocks 0, 2 and 4 plus the tail fill the four slots.
    a.free(blocks[0], 4096);
    a.free(blocks[2], 4096);
    a.free(blocks[4], 4096);
    try testing.expectEqual(@as(usize, 4), a.freeExtents().len);
    const free_before = a.freeBytes();
    a.free(blocks[6], 4096);
    try testing.expectEqual(@as(usize, 1), a.dropped);
    try testing.expectEqual(free_before, a.freeBytes());
    try testing.expect(!a.isFree(blocks[6], 4096));
    // A block that merges needs no new slot.
    a.free(blocks[1], 4096);
    try testing.expectEqual(@as(usize, 1), a.dropped);
    try testing.expect(a.isFree(blocks[0], 3 * 4096));
}

test "a full table makes alloc and allocAt skip a split" {
    const Small = ExtentAllocator(2, page_size);
    var a = Small.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base + mib, mib));
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    // A block in the middle of an extent needs a third slot.
    try testing.expect(!a.allocAt(test_base + 4096, 4096));
    // A block at the start of an extent needs no new slot.
    try testing.expectEqual(@as(?usize, test_base), a.alloc(4096, 4096, test_end));
    // An 8 KiB aligned block in the first extent leaves a pad below it, so
    // alloc skips to the next extent.
    try testing.expectEqual(@as(?usize, test_base + 2 * mib), a.alloc(4096, 8192, test_end));
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
}

test "out of range and overflowing arguments are ignored" {
    var a = PageAllocator.init(test_base, test_end);
    const max = std.math.maxInt(usize);
    const x = a.alloc(4096, 4096, test_end).?;
    const before = a;
    a.free(test_base - 4096, 4096);
    a.free(test_end, 4096);
    a.free(test_end - 4096, 8192);
    a.free(x, max);
    a.free(max - 4095, 4096);
    a.free(max, 2);
    a.free(x, 0);
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.allocAt(max - 4095, 8192));
    try testing.expect(!a.allocAt(x + 4096, max));
    try testing.expect(!a.isFree(x + 4096, max));
    try testing.expectEqual(@as(?usize, null), a.alloc(max, 4096, max));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, @as(usize, 1) << (@bitSizeOf(usize) - 1), max));
    try expectExtents(&a, before.freeExtents());
}

test "alloc near the top of the address space does not overflow" {
    const max = std.math.maxInt(usize);
    const top = max - 4095;
    var a = PageAllocator.init(top - 8192, top);
    try testing.expectEqual(@as(?usize, top - 8192), a.alloc(8192, 4096, max));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, max));
    var b = PageAllocator.init(top - 4096 + 1, max);
    try testing.expectEqual(@as(?usize, null), b.alloc(4096, 4096, max));
    var c = ExtentAllocator(4, 1).init(max - 100, max);
    try testing.expectEqual(@as(?usize, null), c.alloc(1, 4096, max));
    try testing.expectEqual(@as(?usize, max - 100), c.alloc(100, 1, max));
}

test "the allocator matches a bitmap model over random operations" {
    const granule: usize = 16;
    const units = 512;
    const base: usize = 0x1000_0000;
    const end = base + units * granule;
    // The table never fills here: there are at most units / 2 extents.
    var a = ExtentAllocator(units / 2 + 1, granule).init(base, end);
    var model: [units]bool = @splat(true);
    var live: [units]Extent = undefined;
    var live_n: usize = 0;

    var prng = std.Random.DefaultPrng.init(0x5745_4952);
    const r = prng.random();

    var op: usize = 0;
    while (op < 4000) : (op += 1) {
        switch (r.uintLessThan(u8, 4)) {
            0 => {
                const size = (r.uintLessThan(usize, 24) + 1) * granule;
                const alignment = granule << r.uintLessThan(u3, 5);
                const limit = base + r.uintLessThan(usize, units + 1) * granule;
                const want = modelFirstFit(&model, base, granule, size, alignment, limit);
                const got = a.alloc(size, alignment, limit);
                try testing.expectEqual(want, got);
                if (got) |addr| {
                    modelSet(&model, base, granule, addr, size, false);
                    live[live_n] = .{ .start = addr, .end = addr + size };
                    live_n += 1;
                }
            },
            1 => {
                const addr = base + r.uintLessThan(usize, units) * granule;
                const size = (r.uintLessThan(usize, 16) + 1) * granule;
                const want = modelAllFree(&model, base, granule, addr, size);
                try testing.expectEqual(want, a.allocAt(addr, size));
                if (want) {
                    modelSet(&model, base, granule, addr, size, false);
                    live[live_n] = .{ .start = addr, .end = addr + size };
                    live_n += 1;
                }
            },
            2 => if (live_n > 0) {
                const i = r.uintLessThan(usize, live_n);
                const blk = live[i];
                live[i] = live[live_n - 1];
                live_n -= 1;
                a.free(blk.start, blk.end - blk.start);
                modelSet(&model, base, granule, blk.start, blk.end - blk.start, true);
            },
            else => {
                // A random range: often a double free or out of range.
                const addr = base - 4 * granule + r.uintLessThan(usize, units + 8) * granule;
                const size = r.uintLessThan(usize, 8) * granule;
                const valid = size > 0 and addr >= base and addr + size <= end and
                    modelNoneFree(&model, base, granule, addr, size);
                a.free(addr, size);
                if (valid) {
                    modelSet(&model, base, granule, addr, size, true);
                    // A live block that lost a part is gone from the model too.
                    var j: usize = 0;
                    while (j < live_n) {
                        if (live[j].start < addr + size and addr < live[j].end) {
                            live[j] = live[live_n - 1];
                            live_n -= 1;
                        } else j += 1;
                    }
                }
            },
        }
        try expectMatchesModel(&a, &model, base, granule);
    }
    try testing.expectEqual(@as(usize, 0), a.dropped);
}

fn modelFirstFit(model: []const bool, base: usize, granule: usize, size: usize, alignment: usize, limit: usize) ?usize {
    var addr = std.mem.alignForward(usize, base, alignment);
    while (addr + size <= limit and addr + size <= base + model.len * granule) : (addr += alignment) {
        if (modelAllFree(model, base, granule, addr, size)) return addr;
    }
    return null;
}

fn modelAllFree(model: []const bool, base: usize, granule: usize, addr: usize, size: usize) bool {
    const first = (addr - base) / granule;
    const n = size / granule;
    if (first + n > model.len) return false;
    for (model[first..][0..n]) |f| if (!f) return false;
    return true;
}

fn modelNoneFree(model: []const bool, base: usize, granule: usize, addr: usize, size: usize) bool {
    const first = (addr - base) / granule;
    for (model[first..][0 .. size / granule]) |f| if (f) return false;
    return true;
}

fn modelSet(model: []bool, base: usize, granule: usize, addr: usize, size: usize, value: bool) void {
    const first = (addr - base) / granule;
    @memset(model[first..][0 .. size / granule], value);
}

fn expectMatchesModel(a: anytype, model: []const bool, base: usize, granule: usize) !void {
    var free_units: usize = 0;
    var runs: usize = 0;
    for (model, 0..) |f, i| {
        try testing.expectEqual(f, a.isFree(base + i * granule, granule));
        if (f) free_units += 1;
        if (f and (i == 0 or !model[i - 1])) runs += 1;
    }
    try testing.expectEqual(free_units * granule, a.freeBytes());
    try testing.expectEqual(runs, a.freeExtents().len);
}

var test_arena: [2 * mib]u8 align(page_size) = undefined;

fn testPages() PageAllocator {
    const base = @intFromPtr(&test_arena);
    return .init(base, base + test_arena.len);
}

fn headerOf(addr: usize) *PoolHeader {
    return @ptrFromInt(addr - @sizeOf(PoolHeader));
}

test "a small pool block comes from a chunk" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const addr = pool.alloc(100).?;
    try testing.expectEqual(pages.base + 16, addr);
    try testing.expectEqual(@as(u64, 128), headerOf(addr).size);
    try testing.expectEqual(pool_magic, headerOf(addr).magic);
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(test_arena.len - chunk_size, pages.freeBytes());
}

test "small sizes round up to 64 bytes with the header" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(1).?;
    const b = pool.alloc(48).?;
    const c = pool.alloc(49).?;
    const d = pool.alloc(0).?;
    try testing.expectEqual(a + 64, b);
    try testing.expectEqual(b + 64, c);
    try testing.expectEqual(c + 128, d);
    try testing.expectEqual(@as(u64, 128), headerOf(c).size);
    try testing.expectEqual(@as(u64, 64), headerOf(d).size);
    for ([_]usize{ a, b, c, d }) |p| try testing.expectEqual(@as(usize, 0), p % 16);
}

test "freeing the last small block of a chunk returns its pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100).?;
    const b = pool.alloc(200).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expect(pool.free(b));
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
    try expectExtents(&pages, &.{.{ .start = pages.base, .end = pages.end }});
}

test "a block of 32 KiB or more with its header takes whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const big = pool.alloc(large_block - 16).?;
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
    try testing.expectEqual(@as(usize, 0), (big - 16) % page_size);
    try testing.expectEqual(@as(u64, large_block), headerOf(big).size);
    const small = pool.alloc(large_block - 17).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(@as(u64, large_block), headerOf(small).size);
    try testing.expect(pool.free(big));
    try testing.expect(pool.free(small));
    try expectExtents(&pages, &.{.{ .start = pages.base, .end = pages.end }});
}

test "a large block rounds up to whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const big = pool.alloc(40000).?;
    try testing.expectEqual(@as(u64, 40960), headerOf(big).size);
    try testing.expectEqual(test_arena.len - 40960, pages.freeBytes());
    try testing.expect(pool.free(big));
    try testing.expectEqual(test_arena.len, pages.freeBytes());
}

test "small blocks fill a chunk and then take a second" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(large_block - 17).?;
    _ = pool.alloc(large_block - 17).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    _ = pool.alloc(large_block - 17).?;
    try testing.expectEqual(@as(usize, 2), pool.chunkCount());
}

test "a full chunk table makes a small block take whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    var i: usize = 0;
    while (i < 2 * max_chunks) : (i += 1) _ = pool.alloc(large_block - 17).?;
    try testing.expectEqual(@as(usize, max_chunks), pool.chunkCount());
    const before = pages.freeBytes();
    const extra = pool.alloc(100).?;
    try testing.expectEqual(@as(usize, 0), (extra - 16) % page_size);
    try testing.expectEqual(@as(u64, page_size), headerOf(extra).size);
    try testing.expectEqual(before - page_size, pages.freeBytes());
    try testing.expect(pool.free(extra));
    try testing.expectEqual(before, pages.freeBytes());
}

test "a pool block is reused after free" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(10).?;
    const a = pool.alloc(300).?;
    _ = pool.alloc(10).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(?usize, a), pool.alloc(300));
}

test "a double free of a pool block is rejected" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(10).?;
    const a = pool.alloc(10).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(u64, 0), headerOf(a).magic);
    try testing.expect(!pool.free(a));
    const big = pool.alloc(large_block).?;
    try testing.expect(pool.free(big));
    try testing.expect(!pool.free(big));
}

test "a bad pool pointer or header is rejected and frees nothing" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100).?;
    const free_before = pages.freeBytes();
    try testing.expect(!pool.free(a + 8));
    try testing.expect(!pool.free(a + 64));
    try testing.expect(!pool.free(pages.base));
    try testing.expect(!pool.free(pages.end + 16));
    try testing.expect(!pool.free(0));
    headerOf(a).size = 100;
    try testing.expect(!pool.free(a));
    headerOf(a).size = test_arena.len;
    try testing.expect(!pool.free(a));
    headerOf(a).size = 128;
    headerOf(a).magic = 1;
    try testing.expect(!pool.free(a));
    try testing.expectEqual(free_before, pages.freeBytes());
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    headerOf(a).magic = pool_magic;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
}

test "pool alloc fails when the pages run out" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    try testing.expectEqual(@as(?usize, null), pool.alloc(test_arena.len));
    try testing.expectEqual(@as(?usize, null), pool.alloc(std.math.maxInt(usize)));
    try testing.expectEqual(@as(?usize, null), pool.alloc(std.math.maxInt(usize) - 20));
    try testing.expectEqual(test_arena.len, pages.freeBytes());
    var empty = PageAllocator.init(0, 0);
    var none = Pool.init(&empty);
    try testing.expectEqual(@as(?usize, null), none.alloc(10));
    try testing.expect(!none.free(64));
}
