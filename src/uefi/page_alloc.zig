//! Page and pool allocators for the EFI boot services.
//!
//! The extent allocator keeps a fixed table of free extents in address order.
//! The tagged allocator adds a table that labels the allocated extents with a
//! memory type and an owner. Neither reads or writes the memory it manages. The
//! pool puts a header in front of each block. All have no platform imports, so
//! their tests run on the host.

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
        /// Frees refused because the table was full. The block stays allocated.
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

        /// Return [addr, addr + size). False, with no change, for a range
        /// outside the managed range, one that overlaps free memory, or one
        /// that needs a new slot when the table is full.
        pub fn free(self: *Self, addr: usize, size: usize) bool {
            if (size == 0 or !aligned(addr) or !aligned(size)) return false;
            const block_end = std.math.add(usize, addr, size) catch return false;
            if (addr < self.base or block_end > self.end) return false;

            var i: usize = 0;
            while (i < self.count and self.extents[i].end <= addr) : (i += 1) {}
            if (i < self.count and self.extents[i].start < block_end) return false;

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
                return false;
            } else {
                self.insert(i, .{ .start = addr, .end = block_end });
            }
            return true;
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

/// The memory type of an allocated range. The values are the UEFI memory types.
pub const Kind = enum(u8) {
    /// Memory that Weir keeps after ExitBootServices.
    reserved = 0,
    loader_code = 1,
    loader_data = 2,
    boot_services_code = 3,
    boot_services_data = 4,
    runtime_services_code = 5,
    runtime_services_data = 6,
    acpi_reclaim = 9,
    acpi_nvs = 10,

    /// The kind for the memory type a caller gives to AllocatePages or
    /// AllocatePool, or null for a type that a caller cannot allocate. Other
    /// types that the OS must not take back, and the OEM and OS vendor ranges,
    /// give reserved.
    pub fn fromEfi(memory_type: u32) ?Kind {
        return switch (memory_type) {
            0, 8, 11, 12, 13, 0x7000_0000...0xffff_ffff => .reserved,
            1 => .loader_code,
            2 => .loader_data,
            3 => .boot_services_code,
            4 => .boot_services_data,
            5 => .runtime_services_code,
            6 => .runtime_services_data,
            9 => .acpi_reclaim,
            10 => .acpi_nvs,
            // Conventional, persistent, unaccepted and undefined types.
            else => null,
        };
    }

    /// Small pool blocks of these kinds can share loader data chunks, as the
    /// OS takes all of them back.
    fn sharesChunks(kind: Kind) bool {
        return kind == .loader_data or kind == .boot_services_code or kind == .boot_services_data;
    }
};

/// Who can free an allocated range.
pub const Owner = enum(u8) {
    /// A caller of AllocatePages. FreePages frees only this owner.
    caller,
    /// The pool: its chunks and its large blocks.
    pool,
    /// Weir: loaded images, the initrd and scratch buffers.
    firmware,
};

pub const Tag = packed struct(u16) { kind: Kind, owner: Owner };

/// The label of an allocated range that has no slot in a full tag table.
pub const default_tag: Tag = .{ .kind = .loader_data, .owner = .firmware };

/// A part of the managed range. `tag` is null for free memory.
pub const Span = struct { start: usize, end: usize, tag: ?Tag };

/// An extent allocator with a second table that tags the allocated extents.
/// The free table decides what is free. When the tag table is full, a new
/// allocation still succeeds and its range has `default_tag`.
pub fn TaggedAllocator(comptime free_capacity: usize, comptime tag_capacity: usize, comptime unit: usize) type {
    comptime if (tag_capacity < 2) @compileError("a tag table needs at least two slots");

    return struct {
        const Self = @This();
        const Free = ExtentAllocator(free_capacity, unit);
        const Tagged = struct { start: usize, end: usize, tag: Tag };
        pub const free_slots = free_capacity;

        free_table: Free,
        base: usize,
        end: usize,
        /// Allocated extents in address order. Neighbours with the same tag
        /// are merged.
        tags: [tag_capacity]Tagged,
        tag_count: usize,
        /// Allocated ranges that got no tag because the tag table was full.
        untagged: usize,
        /// Changes on each alloc and free that succeeds.
        generation: usize,

        pub fn init(base: usize, end: usize) Self {
            const f = Free.init(base, end);
            return .{
                .free_table = f,
                .base = f.base,
                .end = f.end,
                .tags = undefined,
                .tag_count = 0,
                .untagged = 0,
                .generation = 0,
            };
        }

        pub fn alloc(self: *Self, size: usize, alignment: usize, limit: usize, tag: Tag) ?usize {
            const addr = self.free_table.alloc(size, alignment, limit) orelse return null;
            self.label(addr, addr + size, tag);
            return addr;
        }

        pub fn allocAt(self: *Self, addr: usize, size: usize, tag: Tag) bool {
            if (!self.free_table.allocAt(addr, size)) return false;
            self.label(addr, addr + size, tag);
            return true;
        }

        /// Free [addr, addr + size) when all of it is allocated and each tagged
        /// part of it has `owner`. A part with no tag accepts any owner.
        pub fn free(self: *Self, addr: usize, size: usize, owner: Owner) bool {
            const block_end = std.math.add(usize, addr, size) catch return false;
            for (self.tags[0..self.tag_count]) |t| {
                if (t.start < block_end and addr < t.end and t.tag.owner != owner) return false;
            }
            if (!self.free_table.free(addr, size)) return false;
            self.unlabel(addr, block_end);
            self.generation +%= 1;
            return true;
        }

        pub fn isFree(self: *const Self, addr: usize, size: usize) bool {
            return self.free_table.isFree(addr, size);
        }

        pub fn freeBytes(self: *const Self) usize {
            return self.free_table.freeBytes();
        }

        pub fn freeExtents(self: *const Self) []const Extent {
            return self.free_table.freeExtents();
        }

        /// The tag of the allocated unit at `addr`, or null when it is free or
        /// outside the managed range.
        pub fn tagAt(self: *const Self, addr: usize) ?Tag {
            if (addr < self.base or addr >= self.end) return null;
            if (self.isFree(addr & ~@as(usize, unit - 1), unit)) return null;
            for (self.tags[0..self.tag_count]) |t| {
                if (t.start <= addr and addr < t.end) return t.tag;
            }
            return default_tag;
        }

        /// All of the managed range in address order, each unit once.
        pub fn walk(self: *const Self) Walker {
            return .{ .a = self, .pos = self.base };
        }

        pub const Walker = struct {
            a: *const Self,
            pos: usize,
            free_i: usize = 0,
            tag_i: usize = 0,

            pub fn next(w: *Walker) ?Span {
                const start = w.pos;
                if (start >= w.a.end) return null;
                const free_extents = w.a.freeExtents();
                if (w.free_i < free_extents.len and free_extents[w.free_i].start == start) {
                    w.pos = free_extents[w.free_i].end;
                    w.free_i += 1;
                    return .{ .start = start, .end = w.pos, .tag = null };
                }
                // Allocated up to the next free extent. No tagged extent
                // overlaps free memory.
                const limit = if (w.free_i < free_extents.len) free_extents[w.free_i].start else w.a.end;
                const tags = w.a.tags[0..w.a.tag_count];
                while (w.tag_i < tags.len and tags[w.tag_i].end <= start) w.tag_i += 1;
                if (w.tag_i < tags.len and tags[w.tag_i].start <= start) {
                    w.pos = @min(tags[w.tag_i].end, limit);
                    return .{ .start = start, .end = w.pos, .tag = tags[w.tag_i].tag };
                }
                w.pos = if (w.tag_i < tags.len) @min(tags[w.tag_i].start, limit) else limit;
                return .{ .start = start, .end = w.pos, .tag = default_tag };
            }
        };

        // Tag [start, end), which was free until now.
        fn label(self: *Self, start: usize, end: usize, tag: Tag) void {
            self.generation +%= 1;
            var i: usize = 0;
            while (i < self.tag_count and self.tags[i].start < start) : (i += 1) {}
            const merge_low = i > 0 and self.tags[i - 1].end == start and self.tags[i - 1].tag == tag;
            const merge_high = i < self.tag_count and self.tags[i].start == end and self.tags[i].tag == tag;
            if (merge_low and merge_high) {
                self.tags[i - 1].end = self.tags[i].end;
                self.removeTag(i);
            } else if (merge_low) {
                self.tags[i - 1].end = end;
            } else if (merge_high) {
                self.tags[i].start = start;
            } else if (self.tag_count == tag_capacity) {
                self.untagged += 1;
            } else {
                self.insertTag(i, .{ .start = start, .end = end, .tag = tag });
            }
        }

        // Remove [start, end) from the tagged extents. When a split needs a
        // slot and the table is full, the upper part loses its tag.
        fn unlabel(self: *Self, start: usize, end: usize) void {
            var i: usize = 0;
            while (i < self.tag_count) {
                const t = self.tags[i];
                if (t.end <= start or end <= t.start) {
                    i += 1;
                } else if (t.start < start and end < t.end) {
                    self.tags[i].end = start;
                    if (self.tag_count == tag_capacity) {
                        self.untagged += 1;
                    } else {
                        self.insertTag(i + 1, .{ .start = end, .end = t.end, .tag = t.tag });
                    }
                    return;
                } else if (t.start < start) {
                    self.tags[i].end = start;
                    i += 1;
                } else if (end < t.end) {
                    self.tags[i].start = end;
                    return;
                } else {
                    self.removeTag(i);
                }
            }
        }

        fn insertTag(self: *Self, i: usize, t: Tagged) void {
            std.debug.assert(self.tag_count < tag_capacity and i <= self.tag_count);
            std.mem.copyBackwards(Tagged, self.tags[i + 1 .. self.tag_count + 1], self.tags[i..self.tag_count]);
            self.tags[i] = t;
            self.tag_count += 1;
        }

        fn removeTag(self: *Self, i: usize) void {
            std.debug.assert(i < self.tag_count);
            std.mem.copyForwards(Tagged, self.tags[i .. self.tag_count - 1], self.tags[i + 1 .. self.tag_count]);
            self.tag_count -= 1;
        }
    };
}

pub const page_size = 4096;
pub const PageAllocator = TaggedAllocator(64, 64, page_size);

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

const chunk_tag: Tag = .{ .kind = .loader_data, .owner = .pool };

/// AllocatePool and FreePool on top of a page allocator. A small block of
/// loader data or boot services memory comes from a chunk of pages with its
/// own extent allocator. A large block, a block of another kind, or a small one
/// when the chunk table is full, takes whole pages with the kind as its tag.
pub const Pool = struct {
    pages: *PageAllocator,
    chunks: [max_chunks]ChunkAllocator,
    in_use: [max_chunks]bool,

    pub fn init(pages: *PageAllocator) Pool {
        return .{ .pages = pages, .chunks = undefined, .in_use = @splat(false) };
    }

    /// The address of a 16 byte aligned buffer of `size` bytes, or null. A
    /// block that takes whole pages has the memory type `kind`.
    pub fn alloc(self: *Pool, size: usize, kind: Kind) ?usize {
        const total = std.math.add(usize, size, @sizeOf(PoolHeader)) catch return null;
        const small = total < large_block and kind.sharesChunks();
        const block = if (small) self.allocSmall(total, kind) else self.allocPages(total, kind);
        const b = block orelse return null;
        const header: *PoolHeader = @ptrFromInt(b.start);
        header.* = .{ .size = b.end - b.start, .magic = pool_magic };
        return b.start + @sizeOf(PoolHeader);
    }

    fn allocPages(self: *Pool, total: usize, kind: Kind) ?Extent {
        const padded = std.math.add(usize, total, page_size - 1) catch return null;
        const size = padded & ~@as(usize, page_size - 1);
        const tag: Tag = .{ .kind = kind, .owner = .pool };
        const start = self.pages.alloc(size, page_size, std.math.maxInt(usize), tag) orelse return null;
        return .{ .start = start, .end = start + size };
    }

    fn allocSmall(self: *Pool, total: usize, kind: Kind) ?Extent {
        const size = std.mem.alignForward(usize, total, pool_granule);
        for (&self.chunks, self.in_use) |*c, used| {
            if (!used) continue;
            if (c.alloc(size, pool_granule, std.math.maxInt(usize))) |start| return .{ .start = start, .end = start + size };
        }
        for (&self.chunks, &self.in_use) |*c, *used| {
            if (used.*) continue;
            const base = self.pages.alloc(chunk_size, page_size, std.math.maxInt(usize), chunk_tag) orelse return null;
            c.* = .init(base, base + chunk_size);
            used.* = true;
            const start = c.alloc(size, pool_granule, std.math.maxInt(usize)).?;
            return .{ .start = start, .end = start + size };
        }
        return self.allocPages(total, kind);
    }

    /// Free the buffer at `addr`. False, with the block still allocated, when
    /// `addr` has no live pool header or its block was not released.
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
            if (!c.free(block, size)) return false;
            header.magic = 0;
            // A chunk that the page allocator cannot take back stays in use.
            if (c.freeBytes() == chunk_size and pages.free(c.base, chunk_size, .pool)) used.* = false;
            return true;
        }
        if (block % page_size != 0 or size % page_size != 0) return false;
        if (!pages.free(block, size, .pool)) return false;
        header.magic = 0;
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
const Extents = ExtentAllocator(64, page_size);

fn expectExtents(a: anytype, want: []const Extent) !void {
    try testing.expectEqualSlices(Extent, want, a.freeExtents());
}

test "init gives one extent over the range" {
    const a = Extents.init(test_base, test_end);
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "init of an empty range gives no extents" {
    var a = Extents.init(test_base, test_base);
    try testing.expectEqual(@as(usize, 0), a.freeExtents().len);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, std.math.maxInt(usize)));
}

test "alloc is first fit from the lowest address" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(4096, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(8192, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 3 * 4096), a.alloc(4096, 4096, test_end));
    try expectExtents(&a, &.{.{ .start = test_base + 4 * 4096, .end = test_end }});
}

test "alloc takes the lowest hole that fits" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(4096, 4096, test_end).?;
    const y = a.alloc(4 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x, 4096));
    try testing.expect(a.free(y, 4 * 4096));
    // The hole is five pages long. A two page block goes to its start.
    try testing.expectEqual(@as(?usize, x), a.alloc(2 * 4096, 4096, test_end));
}

test "init rounds the range in to whole pages" {
    const a = Extents.init(test_base + 64, test_end - 64);
    try expectExtents(&a, &.{.{ .start = test_base + 4096, .end = test_end - 4096 }});
    try testing.expectEqual(test_base + 4096, a.base);
    try testing.expectEqual(test_end - 4096, a.end);
    const b = Extents.init(test_base + 64, test_base + 4000);
    try testing.expectEqual(@as(usize, 0), b.freeExtents().len);
}

test "alloc aligns to 4 KiB and to the unit when asked for less" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(4096, 4096, test_end));
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(4096, 8, test_end));
    try testing.expectEqual(@as(?usize, test_base + 2 * 4096), a.alloc(4096, 1, test_end));
}

test "arguments that are not whole pages are rejected" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(2 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    const before = a;
    try testing.expectEqual(@as(?usize, null), a.alloc(100, 4096, test_end));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096 + 64, 4096, test_end));
    try testing.expect(!a.allocAt(test_end - 2 * 4096 + 64, 4096));
    try testing.expect(!a.allocAt(test_end - 2 * 4096, 100));
    try testing.expect(!a.free(x + 64, 4096));
    try testing.expect(!a.free(x, 100));
    try testing.expect(!a.free(x, 4096 + 64));
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(test_end - 4096 + 64, 64));
    try testing.expect(!a.isFree(test_end - 4096, 64));
}

test "alloc aligns to 2 MiB" {
    var a = Extents.init(test_base, test_end);
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expectEqual(@as(?usize, test_base + 2 * mib), a.alloc(2 * mib, 2 * mib, test_end));
    // A small block still fits in the pad below the aligned block.
    try testing.expectEqual(@as(?usize, test_base + 4096), a.alloc(4096, 4096, test_end));
}

test "alloc rejects an alignment that is not a power of two" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 0, test_end));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 3 * 4096, test_end));
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "alloc of size zero gives null" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(0, 4096, test_end));
}

test "alloc keeps the block at or below the limit" {
    var a = Extents.init(test_base, test_end);
    const limit = test_base + 8192;
    try testing.expectEqual(@as(?usize, test_base), a.alloc(8192, 4096, limit));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, limit));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, test_base));
}

test "alloc of the whole range is an exact fit" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, test_base), a.alloc(64 * mib, 4096, test_end));
    try testing.expectEqual(@as(usize, 0), a.freeExtents().len);
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, test_end));
}

test "alloc fills a hole of exactly its size" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(3 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x, 3 * 4096));
    try testing.expectEqual(@as(?usize, x), a.alloc(3 * 4096, 4096, test_end));
    try testing.expectEqual(@as(usize, 1), a.freeExtents().len);
}

test "alloc larger than the range gives null" {
    var a = Extents.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(64 * mib + 4096, 4096, test_end));
}

test "allocAt inside one extent splits it in two" {
    var a = Extents.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base + mib, mib));
    try expectExtents(&a, &.{
        .{ .start = test_base, .end = test_base + mib },
        .{ .start = test_base + 2 * mib, .end = test_end },
    });
}

test "allocAt at the start and the end of an extent" {
    var a = Extents.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base, mib));
    try testing.expect(a.allocAt(test_end - mib, mib));
    try expectExtents(&a, &.{.{ .start = test_base + mib, .end = test_end - mib }});
}

test "allocAt on a partly used range fails and changes nothing" {
    var a = Extents.init(test_base, test_end);
    try testing.expect(a.allocAt(test_base + mib, mib));
    const before = a;
    try testing.expect(!a.allocAt(test_base + mib / 2, mib));
    try testing.expect(!a.allocAt(test_base + mib + mib / 2, mib));
    try testing.expect(!a.allocAt(test_base, 4 * mib));
    try expectExtents(&a, before.freeExtents());
}

test "allocAt outside the range fails" {
    var a = Extents.init(test_base, test_end);
    try testing.expect(!a.allocAt(test_base - 4096, 8192));
    try testing.expect(!a.allocAt(test_end - 4096, 8192));
    try testing.expect(!a.allocAt(test_end, 4096));
    try testing.expect(!a.allocAt(test_base, 0));
    try testing.expectEqual(64 * mib, a.freeBytes());
}

test "free in allocation order returns to one extent" {
    var a = Extents.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    for (blocks) |b| try testing.expect(a.free(b, 4096));
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "free in reverse order returns to one extent" {
    var a = Extents.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    var i: usize = blocks.len;
    while (i > 0) {
        i -= 1;
        try testing.expect(a.free(blocks[i], 4096));
    }
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "free merges with the lower, the upper and both neighbours" {
    var a = Extents.init(test_base, test_end);
    var blocks: [5]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    // Free the middle block first: it has no free neighbour.
    try testing.expect(a.free(blocks[2], 4096));
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    // Merges with the upper neighbour only.
    try testing.expect(a.free(blocks[1], 4096));
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    try testing.expect(a.isFree(blocks[1], 2 * 4096));
    // Merges with the lower neighbour only.
    try testing.expect(a.free(blocks[3], 4096));
    try testing.expectEqual(@as(usize, 2), a.freeExtents().len);
    try testing.expect(a.isFree(blocks[1], 3 * 4096));
    // Merges with both: the free run and the tail of the range.
    try testing.expect(a.free(blocks[4], 4096));
    try expectExtents(&a, &.{
        .{ .start = test_base + 4096, .end = test_end },
    });
    try testing.expect(a.free(blocks[0], 4096));
    try expectExtents(&a, &.{.{ .start = test_base, .end = test_end }});
}

test "alloc after free gives the same address" {
    var a = Extents.init(test_base, test_end);
    _ = a.alloc(4096, 4096, test_end).?;
    const x = a.alloc(5 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x, 5 * 4096));
    try testing.expectEqual(@as(?usize, x), a.alloc(5 * 4096, 4096, test_end));
}

test "a double free is ignored" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(4096, 4096, test_end).?;
    const y = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x, 4096));
    const before = a;
    try testing.expect(!a.free(x, 4096));
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(y, 4096));
}

test "a free of a range that is half free is ignored in full" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(2 * 4096, 4096, test_end).?;
    const y = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x, 4096));
    const before = a;
    // The first page is free, the second is not.
    try testing.expect(!a.free(x, 2 * 4096));
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(x + 4096, 4096));
    // The block below the tail extent, and one page of the tail.
    try testing.expect(!a.free(y, 2 * 4096));
    try expectExtents(&a, before.freeExtents());
    try testing.expect(!a.isFree(y, 4096));
}

test "a free that covers a free extent is ignored in full" {
    var a = Extents.init(test_base, test_end);
    const x = a.alloc(3 * 4096, 4096, test_end).?;
    _ = a.alloc(4096, 4096, test_end).?;
    try testing.expect(a.free(x + 4096, 4096));
    const before = a;
    try testing.expect(!a.free(x, 3 * 4096));
    try expectExtents(&a, before.freeExtents());
}

test "a full table drops a block that cannot merge and counts it" {
    const Small = ExtentAllocator(4, page_size);
    var a = Small.init(test_base, test_end);
    var blocks: [8]usize = undefined;
    for (&blocks) |*b| b.* = a.alloc(4096, 4096, test_end).?;
    // Blocks 0, 2 and 4 plus the tail fill the four slots.
    try testing.expect(a.free(blocks[0], 4096));
    try testing.expect(a.free(blocks[2], 4096));
    try testing.expect(a.free(blocks[4], 4096));
    try testing.expectEqual(@as(usize, 4), a.freeExtents().len);
    const free_before = a.freeBytes();
    try testing.expect(!a.free(blocks[6], 4096));
    try testing.expectEqual(@as(usize, 1), a.dropped);
    try testing.expectEqual(free_before, a.freeBytes());
    try testing.expect(!a.isFree(blocks[6], 4096));
    // A block that merges needs no new slot.
    try testing.expect(a.free(blocks[1], 4096));
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
    var a = Extents.init(test_base, test_end);
    const max = std.math.maxInt(usize);
    const x = a.alloc(4096, 4096, test_end).?;
    const before = a;
    try testing.expect(!a.free(test_base - 4096, 4096));
    try testing.expect(!a.free(test_end, 4096));
    try testing.expect(!a.free(test_end - 4096, 8192));
    try testing.expect(!a.free(x, max));
    try testing.expect(!a.free(max - 4095, 4096));
    try testing.expect(!a.free(max, 2));
    try testing.expect(!a.free(x, 0));
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
    var a = Extents.init(top - 8192, top);
    try testing.expectEqual(@as(?usize, top - 8192), a.alloc(8192, 4096, max));
    try testing.expectEqual(@as(?usize, null), a.alloc(4096, 4096, max));
    var b = Extents.init(top - 4096 + 1, max);
    try testing.expectEqual(@as(?usize, null), b.alloc(4096, 4096, max));
    var c = ExtentAllocator(4, 1).init(max - 100, max);
    try testing.expectEqual(@as(?usize, null), c.alloc(1, 4096, max));
    try testing.expectEqual(@as(?usize, max - 100), c.alloc(100, 1, max));
}

const code_caller: Tag = .{ .kind = .loader_code, .owner = .caller };
const data_caller: Tag = .{ .kind = .loader_data, .owner = .caller };
const code_firmware: Tag = .{ .kind = .loader_code, .owner = .firmware };
const data_pool: Tag = .{ .kind = .loader_data, .owner = .pool };

fn expectWalk(a: anytype, want: []const Span) !void {
    var it = a.walk();
    for (want) |s| try testing.expectEqual(@as(?Span, s), it.next());
    try testing.expectEqual(@as(?Span, null), it.next());
}

test "the allocator matches a tag model over random operations" {
    const granule: usize = 16;
    const units = 512;
    const base: usize = 0x1000_0000;
    const end = base + units * granule;
    const tags = [_]Tag{ code_caller, data_caller, code_firmware, data_pool };
    // Neither table fills here: there are at most units extents.
    var a = TaggedAllocator(units / 2 + 1, units, granule).init(base, end);
    var model: [units]?Tag = @splat(null);
    var live: [units]Extent = undefined;
    var live_n: usize = 0;

    var prng = std.Random.DefaultPrng.init(0x5745_4952);
    const r = prng.random();

    var op: usize = 0;
    var generation: usize = 0;
    while (op < 4000) : (op += 1) {
        const tag = tags[r.uintLessThan(usize, tags.len)];
        var changed = false;
        switch (r.uintLessThan(u8, 4)) {
            0 => {
                const size = (r.uintLessThan(usize, 24) + 1) * granule;
                const alignment = granule << r.uintLessThan(u3, 5);
                const limit = base + r.uintLessThan(usize, units + 1) * granule;
                const want = modelFirstFit(&model, base, granule, size, alignment, limit);
                const got = a.alloc(size, alignment, limit, tag);
                try testing.expectEqual(want, got);
                if (got) |addr| {
                    modelSet(&model, base, granule, addr, size, tag);
                    live[live_n] = .{ .start = addr, .end = addr + size };
                    live_n += 1;
                    changed = true;
                }
            },
            1 => {
                const addr = base + r.uintLessThan(usize, units) * granule;
                const size = (r.uintLessThan(usize, 16) + 1) * granule;
                const want = modelAllFree(&model, base, granule, addr, size);
                try testing.expectEqual(want, a.allocAt(addr, size, tag));
                if (want) {
                    modelSet(&model, base, granule, addr, size, tag);
                    live[live_n] = .{ .start = addr, .end = addr + size };
                    live_n += 1;
                    changed = true;
                }
            },
            2 => if (live_n > 0) {
                const i = r.uintLessThan(usize, live_n);
                const blk = live[i];
                live[i] = live[live_n - 1];
                live_n -= 1;
                const owner = model[(blk.start - base) / granule].?.owner;
                try testing.expect(a.free(blk.start, blk.end - blk.start, owner));
                modelSet(&model, base, granule, blk.start, blk.end - blk.start, null);
                changed = true;
            },
            else => {
                // A random range: often a double free, out of range, the wrong
                // owner, or a part of a block.
                const addr = base - 4 * granule + r.uintLessThan(usize, units + 8) * granule;
                const size = r.uintLessThan(usize, 8) * granule;
                const valid = size > 0 and addr >= base and addr + size <= end and
                    modelAllOwned(&model, base, granule, addr, size, tag.owner);
                try testing.expectEqual(valid, a.free(addr, size, tag.owner));
                if (valid) {
                    modelSet(&model, base, granule, addr, size, null);
                    changed = true;
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
        if (changed) generation += 1;
        try testing.expectEqual(generation, a.generation);
        try expectMatchesModel(&a, &model, base, granule);
    }
    try testing.expectEqual(@as(usize, 0), a.free_table.dropped);
    try testing.expectEqual(@as(usize, 0), a.untagged);
}

fn modelFirstFit(model: []const ?Tag, base: usize, granule: usize, size: usize, alignment: usize, limit: usize) ?usize {
    var addr = std.mem.alignForward(usize, base, alignment);
    while (addr + size <= limit and addr + size <= base + model.len * granule) : (addr += alignment) {
        if (modelAllFree(model, base, granule, addr, size)) return addr;
    }
    return null;
}

fn modelAllFree(model: []const ?Tag, base: usize, granule: usize, addr: usize, size: usize) bool {
    const first = (addr - base) / granule;
    const n = size / granule;
    if (first + n > model.len) return false;
    for (model[first..][0..n]) |t| if (t != null) return false;
    return true;
}

fn modelAllOwned(model: []const ?Tag, base: usize, granule: usize, addr: usize, size: usize, owner: Owner) bool {
    const first = (addr - base) / granule;
    for (model[first..][0 .. size / granule]) |t| {
        const tag = t orelse return false;
        if (tag.owner != owner) return false;
    }
    return true;
}

fn modelSet(model: []?Tag, base: usize, granule: usize, addr: usize, size: usize, value: ?Tag) void {
    const first = (addr - base) / granule;
    @memset(model[first..][0 .. size / granule], value);
}

// The walk must be the run length form of the model: free runs and runs of
// one tag, in address order, with no gap.
fn expectMatchesModel(a: anytype, model: []const ?Tag, base: usize, granule: usize) !void {
    var free_units: usize = 0;
    var free_runs: usize = 0;
    var tag_runs: usize = 0;
    var it = a.walk();
    var i: usize = 0;
    while (i < model.len) {
        var j = i + 1;
        while (j < model.len and model[j] == model[i]) : (j += 1) {}
        const want: Span = .{ .start = base + i * granule, .end = base + j * granule, .tag = model[i] };
        try testing.expectEqual(@as(?Span, want), it.next());
        try testing.expectEqual(model[i] == null, a.isFree(want.start, want.end - want.start));
        try testing.expectEqual(model[i], a.tagAt(want.start));
        try testing.expectEqual(model[j - 1], a.tagAt(want.end - granule));
        if (model[i] == null) {
            free_units += j - i;
            free_runs += 1;
        } else tag_runs += 1;
        i = j;
    }
    try testing.expectEqual(@as(?Span, null), it.next());
    try testing.expectEqual(free_units * granule, a.freeBytes());
    try testing.expectEqual(free_runs, a.freeExtents().len);
    try testing.expectEqual(tag_runs, a.tag_count);
}

test "kinds map from the uefi memory types" {
    try testing.expectEqual(Kind.loader_code, Kind.fromEfi(1).?);
    try testing.expectEqual(Kind.loader_data, Kind.fromEfi(2).?);
    try testing.expectEqual(Kind.boot_services_code, Kind.fromEfi(3).?);
    try testing.expectEqual(Kind.boot_services_data, Kind.fromEfi(4).?);
    try testing.expectEqual(Kind.runtime_services_code, Kind.fromEfi(5).?);
    try testing.expectEqual(Kind.runtime_services_data, Kind.fromEfi(6).?);
    try testing.expectEqual(Kind.acpi_reclaim, Kind.fromEfi(9).?);
    try testing.expectEqual(Kind.acpi_nvs, Kind.fromEfi(10).?);
}

test "reserved, unusable, mmio and vendor types map to reserved" {
    for ([_]u32{ 0, 8, 11, 12, 13, 0x7000_0000, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff }) |t| {
        try testing.expectEqual(Kind.reserved, Kind.fromEfi(t).?);
    }
}

test "conventional, persistent, unaccepted and undefined types are refused" {
    for ([_]u32{ 7, 14, 15, 16, 0x100, 0x6fff_ffff }) |t| {
        try testing.expectEqual(@as(?Kind, null), Kind.fromEfi(t));
    }
}

test "the walk of a new allocator is one free span" {
    const a = PageAllocator.init(test_base, test_end);
    try expectWalk(&a, &.{.{ .start = test_base, .end = test_end, .tag = null }});
    try testing.expectEqual(@as(?Tag, null), a.tagAt(test_base));
    try testing.expectEqual(@as(?Tag, null), a.tagAt(test_end));
    const empty = PageAllocator.init(test_base, test_base);
    try expectWalk(&empty, &.{});
}

test "neighbours with the same tag merge and other tags stay apart" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(4096, 4096, test_end, code_caller).?;
    const y = a.alloc(4096, 4096, test_end, code_caller).?;
    const z = a.alloc(4096, 4096, test_end, data_caller).?;
    try testing.expectEqual(@as(usize, 2), a.tag_count);
    try expectWalk(&a, &.{
        .{ .start = x, .end = y + 4096, .tag = code_caller },
        .{ .start = z, .end = z + 4096, .tag = data_caller },
        .{ .start = z + 4096, .end = test_end, .tag = null },
    });
    // A block that fills the hole between two blocks of its tag joins them.
    try testing.expect(a.free(y, 4096, .caller));
    try testing.expectEqual(@as(usize, 2), a.tag_count);
    try testing.expect(a.allocAt(y, 4096, data_caller));
    try testing.expectEqual(@as(usize, 2), a.tag_count);
    try expectWalk(&a, &.{
        .{ .start = x, .end = x + 4096, .tag = code_caller },
        .{ .start = y, .end = z + 4096, .tag = data_caller },
        .{ .start = z + 4096, .end = test_end, .tag = null },
    });
}

test "a free in the middle of a tagged block keeps the tags of the rest" {
    var a = PageAllocator.init(test_base, test_end);
    const x = a.alloc(8 * 4096, 4096, test_end, code_firmware).?;
    try testing.expect(a.free(x + 3 * 4096, 2 * 4096, .firmware));
    try expectWalk(&a, &.{
        .{ .start = x, .end = x + 3 * 4096, .tag = code_firmware },
        .{ .start = x + 3 * 4096, .end = x + 5 * 4096, .tag = null },
        .{ .start = x + 5 * 4096, .end = x + 8 * 4096, .tag = code_firmware },
        .{ .start = x + 8 * 4096, .end = test_end, .tag = null },
    });
    // The head and the tail free on their own.
    try testing.expect(a.free(x, 4096, .firmware));
    try testing.expect(a.free(x + 7 * 4096, 4096, .firmware));
    try testing.expectEqual(code_firmware, a.tagAt(x + 4096).?);
    try testing.expectEqual(code_firmware, a.tagAt(x + 6 * 4096).?);
    try testing.expectEqual(@as(usize, 2), a.tag_count);
}

test "free refuses free memory and the wrong owner" {
    var a = PageAllocator.init(test_base, test_end);
    const initrd: Tag = .{ .kind = .boot_services_data, .owner = .firmware };
    const x = a.alloc(4 * 4096, 4096, test_end, initrd).?;
    const y = a.alloc(4096, 4096, test_end, data_pool).?;
    const z = a.alloc(2 * 4096, 4096, test_end, data_caller).?;
    const before = a;
    // Free memory, a firmware range, a pool chunk, and a caller block that
    // runs into the pool chunk below it.
    try testing.expect(!a.free(z + 2 * 4096, 4096, .caller));
    try testing.expect(!a.free(x, 4 * 4096, .caller));
    try testing.expect(!a.free(x + 4096, 4096, .caller));
    try testing.expect(!a.free(y, 4096, .caller));
    try testing.expect(!a.free(y, 3 * 4096, .caller));
    try testing.expect(!a.free(z, 2 * 4096, .pool));
    try testing.expectEqual(before.generation, a.generation);
    try expectWalk(&a, &.{
        .{ .start = x, .end = x + 4 * 4096, .tag = initrd },
        .{ .start = y, .end = y + 4096, .tag = data_pool },
        .{ .start = z, .end = z + 2 * 4096, .tag = data_caller },
        .{ .start = z + 2 * 4096, .end = test_end, .tag = null },
    });
    try testing.expect(a.free(z, 2 * 4096, .caller));
    try testing.expect(a.free(y, 4096, .pool));
    try testing.expect(a.free(x, 4 * 4096, .firmware));
    try testing.expectEqual(before.generation + 3, a.generation);
    try testing.expectEqual(@as(usize, 0), a.tag_count);
}

test "a failed alloc or free does not change the generation" {
    var a = PageAllocator.init(test_base, test_end);
    try testing.expectEqual(@as(?usize, null), a.alloc(128 * mib, 4096, test_end, data_caller));
    try testing.expect(!a.allocAt(test_end, 4096, data_caller));
    try testing.expect(!a.free(test_base, 4096, .caller));
    try testing.expectEqual(@as(usize, 0), a.generation);
    const x = a.alloc(4096, 4096, test_end, data_caller).?;
    try testing.expect(a.allocAt(x + 4096, 4096, data_caller));
    try testing.expect(a.free(x, 4096, .caller));
    try testing.expectEqual(@as(usize, 3), a.generation);
}

test "a full tag table still gives a correct free and allocated partition" {
    const Small = TaggedAllocator(64, 2, page_size);
    var a = Small.init(test_base, test_end);
    const p = a.alloc(4096, 4096, test_end, code_caller).?;
    const q = a.alloc(4096, 4096, test_end, data_pool).?;
    // No slot for these two: they are allocated with no tag.
    const r = a.alloc(4096, 4096, test_end, code_firmware).?;
    const s = a.alloc(4096, 4096, test_end, data_caller).?;
    try testing.expectEqual(@as(usize, 2), a.untagged);
    try testing.expectEqual(default_tag, a.tagAt(r).?);
    try expectWalk(&a, &.{
        .{ .start = p, .end = p + 4096, .tag = code_caller },
        .{ .start = q, .end = q + 4096, .tag = data_pool },
        .{ .start = r, .end = s + 4096, .tag = default_tag },
        .{ .start = s + 4096, .end = test_end, .tag = null },
    });
    // A range with no tag frees for any owner. A tagged one still checks.
    try testing.expect(a.free(r, 4096, .pool));
    try testing.expect(!a.free(q, 4096, .caller));
    try expectWalk(&a, &.{
        .{ .start = p, .end = p + 4096, .tag = code_caller },
        .{ .start = q, .end = q + 4096, .tag = data_pool },
        .{ .start = r, .end = r + 4096, .tag = null },
        .{ .start = s, .end = s + 4096, .tag = default_tag },
        .{ .start = s + 4096, .end = test_end, .tag = null },
    });
}

test "a free that splits a tag in a full table drops the tag of the upper part" {
    const Small = TaggedAllocator(64, 2, page_size);
    var a = Small.init(test_base, test_end);
    const x = a.alloc(4 * 4096, 4096, test_end, code_firmware).?;
    const y = a.alloc(4096, 4096, test_end, data_pool).?;
    try testing.expect(a.free(x + 4096, 4096, .firmware));
    try testing.expectEqual(@as(usize, 1), a.untagged);
    try expectWalk(&a, &.{
        .{ .start = x, .end = x + 4096, .tag = code_firmware },
        .{ .start = x + 4096, .end = x + 2 * 4096, .tag = null },
        .{ .start = x + 2 * 4096, .end = x + 4 * 4096, .tag = default_tag },
        .{ .start = y, .end = y + 4096, .tag = data_pool },
        .{ .start = y + 4096, .end = test_end, .tag = null },
    });
}

test "a free that the free table cannot take keeps the block and its tag" {
    const Small = TaggedAllocator(2, 8, page_size);
    var a = Small.init(test_base, test_end);
    var blocks: [5]usize = undefined;
    for (&blocks, 0..) |*b, i| b.* = a.alloc(4096, 4096, test_end, if (i == 3) data_caller else code_caller).?;
    // Block 1 and the tail fill the free table. Block 3 needs a third slot.
    try testing.expect(a.free(blocks[1], 4096, .caller));
    const generation = a.generation;
    try testing.expect(!a.free(blocks[3], 4096, .caller));
    try testing.expectEqual(@as(usize, 1), a.free_table.dropped);
    try testing.expectEqual(generation, a.generation);
    try testing.expectEqual(data_caller, a.tagAt(blocks[3]).?);
    // Once block 2 is free, block 3 merges and needs no slot.
    try testing.expect(a.free(blocks[2], 4096, .caller));
    try testing.expect(a.free(blocks[3], 4096, .caller));
    try expectWalk(&a, &.{
        .{ .start = blocks[0], .end = blocks[1], .tag = code_caller },
        .{ .start = blocks[1], .end = blocks[4], .tag = null },
        .{ .start = blocks[4], .end = blocks[4] + 4096, .tag = code_caller },
        .{ .start = blocks[4] + 4096, .end = test_end, .tag = null },
    });
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
    const addr = pool.alloc(100, .loader_data).?;
    try testing.expectEqual(pages.base + 16, addr);
    try testing.expectEqual(@as(u64, 128), headerOf(addr).size);
    try testing.expectEqual(pool_magic, headerOf(addr).magic);
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(test_arena.len - chunk_size, pages.freeBytes());
}

test "small sizes round up to 64 bytes with the header" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(1, .loader_data).?;
    const b = pool.alloc(48, .loader_data).?;
    const c = pool.alloc(49, .loader_data).?;
    const d = pool.alloc(0, .loader_data).?;
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
    const a = pool.alloc(100, .loader_data).?;
    const b = pool.alloc(200, .loader_data).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expect(pool.free(b));
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
    try expectExtents(&pages, &.{.{ .start = pages.base, .end = pages.end }});
}

test "a block of 32 KiB or more with its header takes whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const big = pool.alloc(large_block - 16, .loader_data).?;
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
    try testing.expectEqual(@as(usize, 0), (big - 16) % page_size);
    try testing.expectEqual(@as(u64, large_block), headerOf(big).size);
    const small = pool.alloc(large_block - 17, .loader_data).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(@as(u64, large_block), headerOf(small).size);
    try testing.expect(pool.free(big));
    try testing.expect(pool.free(small));
    try expectExtents(&pages, &.{.{ .start = pages.base, .end = pages.end }});
}

test "a large block rounds up to whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const big = pool.alloc(40000, .loader_data).?;
    try testing.expectEqual(@as(u64, 40960), headerOf(big).size);
    try testing.expectEqual(test_arena.len - 40960, pages.freeBytes());
    try testing.expect(pool.free(big));
    try testing.expectEqual(test_arena.len, pages.freeBytes());
}

test "small blocks fill a chunk and then take a second" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(large_block - 17, .loader_data).?;
    _ = pool.alloc(large_block - 17, .loader_data).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    _ = pool.alloc(large_block - 17, .loader_data).?;
    try testing.expectEqual(@as(usize, 2), pool.chunkCount());
}

test "a full chunk table makes a small block take whole pages" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    var i: usize = 0;
    while (i < 2 * max_chunks) : (i += 1) _ = pool.alloc(large_block - 17, .loader_data).?;
    try testing.expectEqual(@as(usize, max_chunks), pool.chunkCount());
    const before = pages.freeBytes();
    const extra = pool.alloc(100, .loader_data).?;
    try testing.expectEqual(@as(usize, 0), (extra - 16) % page_size);
    try testing.expectEqual(@as(u64, page_size), headerOf(extra).size);
    try testing.expectEqual(before - page_size, pages.freeBytes());
    try testing.expect(pool.free(extra));
    try testing.expectEqual(before, pages.freeBytes());
}

test "a pool block is reused after free" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(10, .loader_data).?;
    const a = pool.alloc(300, .loader_data).?;
    _ = pool.alloc(10, .loader_data).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(?usize, a), pool.alloc(300, .loader_data));
}

test "a double free of a pool block is rejected" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    _ = pool.alloc(10, .loader_data).?;
    const a = pool.alloc(10, .loader_data).?;
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(u64, 0), headerOf(a).magic);
    try testing.expect(!pool.free(a));
    const big = pool.alloc(large_block, .loader_data).?;
    try testing.expect(pool.free(big));
    try testing.expect(!pool.free(big));
}

test "a bad pool pointer or header is rejected and frees nothing" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100, .loader_data).?;
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
    try testing.expectEqual(@as(?usize, null), pool.alloc(test_arena.len, .loader_data));
    try testing.expectEqual(@as(?usize, null), pool.alloc(std.math.maxInt(usize), .loader_data));
    try testing.expectEqual(@as(?usize, null), pool.alloc(std.math.maxInt(usize) - 20, .loader_data));
    try testing.expectEqual(test_arena.len, pages.freeBytes());
    var empty = PageAllocator.init(0, 0);
    var none = Pool.init(&empty);
    try testing.expectEqual(@as(?usize, null), none.alloc(10, .loader_data));
    try testing.expect(!none.free(64));
}

test "pool chunks are loader data and large blocks take the pool type" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const small = pool.alloc(100, .boot_services_data).?;
    const big = pool.alloc(large_block, .runtime_services_data).?;
    const rt_pool: Tag = .{ .kind = .runtime_services_data, .owner = .pool };
    try testing.expectEqual(data_pool, pages.tagAt(small).?);
    try testing.expectEqual(rt_pool, pages.tagAt(big).?);
    try expectWalk(&pages, &.{
        .{ .start = pages.base, .end = pages.base + chunk_size, .tag = data_pool },
        .{ .start = big - 16, .end = big - 16 + large_block + page_size, .tag = rt_pool },
        .{ .start = big - 16 + large_block + page_size, .end = pages.end, .tag = null },
    });
}

test "small loader data and boot services blocks share a chunk" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100, .loader_data).?;
    const b = pool.alloc(100, .boot_services_code).?;
    const c = pool.alloc(100, .boot_services_data).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(a + 128, b);
    try testing.expectEqual(b + 128, c);
    try expectWalk(&pages, &.{
        .{ .start = pages.base, .end = pages.base + chunk_size, .tag = data_pool },
        .{ .start = pages.base + chunk_size, .end = pages.end, .tag = null },
    });
}

test "a small block of another kind takes whole pages with its kind" {
    const kinds = [_]Kind{ .reserved, .loader_code, .runtime_services_code, .runtime_services_data, .acpi_reclaim, .acpi_nvs };
    for (kinds) |kind| {
        var pages = testPages();
        var pool = Pool.init(&pages);
        const addr = pool.alloc(256, kind).?;
        const tag: Tag = .{ .kind = kind, .owner = .pool };
        try testing.expectEqual(@as(usize, 0), pool.chunkCount());
        try testing.expectEqual(@as(usize, 0), (addr - 16) % page_size);
        try testing.expectEqual(@as(u64, page_size), headerOf(addr).size);
        try expectWalk(&pages, &.{
            .{ .start = addr - 16, .end = addr - 16 + page_size, .tag = tag },
            .{ .start = addr - 16 + page_size, .end = pages.end, .tag = null },
        });
        try testing.expect(pool.free(addr));
        try testing.expectEqual(@as(u64, 0), headerOf(addr).magic);
        try expectWalk(&pages, &.{.{ .start = pages.base, .end = pages.end, .tag = null }});
        try testing.expect(!pool.free(addr));
    }
}

test "a small block of another kind frees next to a chunk" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100, .loader_data).?;
    const rt = pool.alloc(100, .runtime_services_data).?;
    const b = pool.alloc(100, .loader_data).?;
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(pages.base + chunk_size + 16, rt);
    try testing.expectEqual(a + 128, b);
    try testing.expect(pool.free(rt));
    try testing.expect(pages.isFree(rt - 16, page_size));
    try testing.expect(pool.free(a));
    try testing.expect(pool.free(b));
    try testing.expectEqual(@as(usize, 0), pool.chunkCount());
    try expectExtents(&pages, &.{.{ .start = pages.base, .end = pages.end }});
}

test "a pool free that releases nothing fails and keeps the block" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const small = pool.alloc(100, .loader_data).?;
    _ = pool.alloc(100, .loader_data).?;
    const big = pool.alloc(40000, .loader_data).?;
    // A size that runs into free memory past the block.
    headerOf(big).size = 40960 + page_size;
    try testing.expect(!pool.free(big));
    try testing.expectEqual(pool_magic, headerOf(big).magic);
    headerOf(small).size = chunk_size - 64;
    try testing.expect(!pool.free(small));
    try testing.expectEqual(pool_magic, headerOf(small).magic);
    headerOf(big).size = 40960;
    headerOf(small).size = 128;
    try testing.expect(pool.free(big));
    try testing.expect(pool.free(small));
}

test "a pool header on memory the pool does not own frees nothing" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const x = pages.alloc(page_size, page_size, pages.end, data_caller).?;
    const header: *PoolHeader = @ptrFromInt(x);
    header.* = .{ .size = page_size, .magic = pool_magic };
    try testing.expect(!pool.free(x + 16));
    try testing.expectEqual(data_caller, pages.tagAt(x).?);
    try testing.expect(!pages.isFree(x, page_size));
}

test "a chunk that the page allocator cannot take back stays in use" {
    var pages = testPages();
    var pool = Pool.init(&pages);
    const a = pool.alloc(100, .loader_data).?;
    // Fill the page free table, so the chunk at the base has no free neighbour
    // and needs a slot it cannot get.
    var holes: [PageAllocator.free_slots]usize = undefined;
    for (&holes) |*h| {
        h.* = pages.alloc(page_size, page_size, pages.end, data_caller).?;
        _ = pages.alloc(page_size, page_size, pages.end, data_caller).?;
    }
    for (holes[1..]) |h| try testing.expect(pages.free(h, page_size, .caller));
    try testing.expectEqual(PageAllocator.free_slots, pages.freeExtents().len);
    try testing.expect(pool.free(a));
    try testing.expectEqual(@as(usize, 1), pool.chunkCount());
    try testing.expectEqual(data_pool, pages.tagAt(a).?);
    // The chunk still serves blocks.
    try testing.expectEqual(@as(?usize, a), pool.alloc(100, .loader_data));
}
