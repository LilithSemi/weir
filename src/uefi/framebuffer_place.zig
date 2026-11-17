//! Where the framebuffer of a display goes. This file has no platform
//! imports, so its tests run on the host.

const std = @import("std");
const page_alloc = @import("page_alloc.zig");

pub const Range = struct {
    base: usize,
    size: usize,

    fn end(range: Range) usize {
        return range.base + range.size;
    }
};

pub const Request = struct {
    /// Bytes of the framebuffer, a whole number of pages.
    size: usize,
    /// A power of two.
    alignment: usize,
    /// The framebuffer of a display that has a fixed one.
    fixed: ?Range = null,
    /// The memory that the display can show. Null when it is not known.
    scanout: ?Range = null,
};

const tag: page_alloc.Tag = .{ .kind = .reserved, .owner = .firmware };

// The address register of a display holds 32 bits.
const address_limit: usize = 1 << 32;

/// The address of the framebuffer, or null when no memory fits. A framebuffer
/// from the pool goes below `top`, and `top` moves down to it, so the
/// framebuffers stack at the top of the pool.
pub fn place(pages: *page_alloc.PageAllocator, request: Request, top: *usize) ?usize {
    if (request.fixed) |fixed| {
        if (fixed.size < request.size or fixed.end() > address_limit) return null;
        // A fixed framebuffer that is in the pool must come out of it.
        if (fixed.end() > pages.base and fixed.base < pages.end) {
            if (!pages.allocAt(fixed.base, fixed.size, tag)) return null;
        }
        return fixed.base;
    }

    var low = pages.base;
    var high = @min(top.*, pages.end, address_limit);
    if (request.scanout) |scanout| {
        if (scanout.end() <= pages.base or scanout.base >= pages.end) {
            // The display shows a memory that is not in the pool. No other
            // user of that memory exists, so the framebuffer is at its start.
            const address = std.mem.alignForward(usize, scanout.base, request.alignment);
            if (address + request.size > @min(scanout.end(), address_limit)) return null;
            return address;
        }
        low = @max(low, scanout.base);
        high = @min(high, scanout.end());
    }

    if (high >= low + request.size) {
        const address = std.mem.alignBackward(usize, high - request.size, request.alignment);
        if (address >= low and pages.allocAt(address, request.size, tag)) {
            top.* = address;
            return address;
        }
    }
    // The top is in use. Take the lowest free block that the display can show.
    const limit = if (request.scanout) |scanout| @min(scanout.end(), address_limit) else address_limit;
    const address = pages.alloc(request.size, request.alignment, limit, tag) orelse return null;
    if (address < low) {
        _ = pages.free(address, request.size, .firmware);
        return null;
    }
    return address;
}

const testing = std.testing;
const mib = 1 << 20;
const pool_base = 0x8040_0000;
const pool_end = 0x8200_0000;

fn testPool() page_alloc.PageAllocator {
    return .init(pool_base, pool_end);
}

test "framebuffers stack down from the top of the pool" {
    var pages = testPool();
    var top: usize = pages.end;
    const first = place(&pages, .{ .size = 0xf0000, .alignment = 4096 }, &top).?;
    try testing.expectEqual(@as(usize, 0x81f1_0000), first);
    const second = place(&pages, .{ .size = 2 * mib, .alignment = 8192 }, &top).?;
    try testing.expectEqual(@as(usize, 0x81d1_0000), second);
    try testing.expectEqual(page_alloc.Kind.reserved, pages.tagAt(first).?.kind);
    try testing.expect(!pages.isFree(second, 2 * mib));
}

test "a fixed framebuffer outside the pool takes no pool memory" {
    var pages = testPool();
    var top: usize = pages.end;
    const free_before = pages.freeBytes();
    const fixed: Range = .{ .base = 0x8200_0000, .size = 2 * mib };
    try testing.expectEqual(@as(?usize, 0x8200_0000), place(&pages, .{ .size = mib, .alignment = 4096, .fixed = fixed }, &top));
    try testing.expectEqual(free_before, pages.freeBytes());
    try testing.expectEqual(@as(?usize, null), place(&pages, .{ .size = 4 * mib, .alignment = 4096, .fixed = fixed }, &top));
}

test "a fixed framebuffer in the pool comes out of the pool" {
    var pages = testPool();
    var top: usize = pages.end;
    const fixed: Range = .{ .base = 0x8100_0000, .size = 2 * mib };
    try testing.expectEqual(@as(?usize, 0x8100_0000), place(&pages, .{ .size = mib, .alignment = 4096, .fixed = fixed }, &top));
    try testing.expect(!pages.isFree(0x8100_0000, 2 * mib));
    // The same memory is not free for a second display.
    try testing.expectEqual(@as(?usize, null), place(&pages, .{ .size = mib, .alignment = 4096, .fixed = fixed }, &top));
}

test "the framebuffer stays in the memory that the display shows" {
    var pages = testPool();
    var top: usize = pages.end;
    const scanout: Range = .{ .base = 0x8000_0000, .size = 16 * mib };
    const address = place(&pages, .{ .size = mib, .alignment = 4096, .scanout = scanout }, &top).?;
    try testing.expectEqual(@as(usize, 0x80f0_0000), address);
}

test "a display on a memory outside the pool gets the start of that memory" {
    var pages = testPool();
    var top: usize = pages.end;
    const free_before = pages.freeBytes();
    const scanout: Range = .{ .base = 0x9000_0000, .size = 8 * mib };
    try testing.expectEqual(@as(?usize, 0x9000_0000), place(&pages, .{ .size = mib, .alignment = 4096, .scanout = scanout }, &top));
    try testing.expectEqual(free_before, pages.freeBytes());
    try testing.expectEqual(@as(?usize, null), place(&pages, .{ .size = 16 * mib, .alignment = 4096, .scanout = scanout }, &top));
}

test "a used top gives the lowest free block that the display can show" {
    var pages = testPool();
    var top: usize = pages.end;
    try testing.expect(pages.allocAt(pool_end - mib, mib, .{ .kind = .boot_services_data, .owner = .firmware }));
    const address = place(&pages, .{ .size = 2 * mib, .alignment = 4096 }, &top).?;
    try testing.expectEqual(@as(usize, pool_base), address);

    // The lowest free block is below the memory of this display.
    var other = testPool();
    try testing.expect(other.allocAt(pool_end - mib, mib, .{ .kind = .boot_services_data, .owner = .firmware }));
    const scanout: Range = .{ .base = pool_end - 2 * mib, .size = 2 * mib };
    const free_before = other.freeBytes();
    try testing.expectEqual(@as(?usize, null), place(&other, .{ .size = 2 * mib, .alignment = 4096, .scanout = scanout }, &top));
    try testing.expectEqual(free_before, other.freeBytes());
}
