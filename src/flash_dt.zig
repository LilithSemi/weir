//! Flash facts read from a device tree blob: the SPI flash controller ports, the
//! partition list and the CFI banks. Every function takes the blob bytes, so the
//! firmware calls them at comptime and host tests call them at run time.

const std = @import("std");
const conduit = @import("conduit");

pub const Region = struct { base: u64, size: u64 };
pub const Partition = struct { label: []const u8, offset: u64, size: u64, read_only: bool };
pub const max_partitions = 32;

const max_depth = 16;
const default_addr_cells = 2;
const default_size_cells = 1;
const cell_bytes = 4;

const Reg = struct {
    bytes: []const u8 = &.{},
    addr_cells: u32 = default_addr_cells,
    size_cells: u32 = default_size_cells,

    fn entry(reg: Reg, index: usize) ?Region {
        if (reg.addr_cells == 0 or reg.addr_cells > 2 or reg.size_cells > 2) return null;
        const len = (reg.addr_cells + reg.size_cells) * cell_bytes;
        if ((index + 1) * len > reg.bytes.len) return null;
        const e = reg.bytes[index * len ..][0..len];
        return .{
            .base = readCells(e[0 .. reg.addr_cells * cell_bytes]),
            .size = readCells(e[reg.addr_cells * cell_bytes ..]),
        };
    }
};

/// Everything the lookups need, gathered in one walk of the tree.
pub const Scan = struct {
    nor_reg: Reg = .{},
    nor_names: []const u8 = &.{},
    cfi_reg: Reg = .{},
    /// Number of partitions found. It can exceed `max_partitions`.
    count: usize = 0,
    /// True when a partition node has a `reg` that does not decode.
    malformed: bool = false,
    parts: [max_partitions]Partition = @splat(.{ .label = "", .offset = 0, .size = 0, .read_only = false }),

    pub fn norRegion(found: *const Scan, name: []const u8) ?Region {
        var index: usize = 0;
        var names = std.mem.splitScalar(u8, found.nor_names, 0);
        while (names.next()) |n| : (index += 1) {
            if (n.len == 0) break;
            if (std.mem.eql(u8, n, name)) return found.nor_reg.entry(index);
        }
        return null;
    }

    pub fn cfiBank(found: *const Scan, index: usize) ?Region {
        return found.cfi_reg.entry(index);
    }

    /// The stored partitions, in device tree order.
    pub fn partitions(found: *const Scan) []const Partition {
        return found.parts[0..@min(found.count, max_partitions)];
    }
};

const Frame = struct {
    name: []const u8 = "",
    // The cells this node declares for its children.
    addr_cells: u32 = default_addr_cells,
    size_cells: u32 = default_size_cells,
    // The cells of the parent, which decode this node's `reg`.
    reg_addr_cells: u32 = default_addr_cells,
    reg_size_cells: u32 = default_size_cells,
    reg: []const u8 = &.{},
    reg_names: []const u8 = &.{},
    label: []const u8 = "",
    read_only: bool = false,
    is_nor: bool = false,
    is_cfi: bool = false,
    is_fixed_partitions: bool = false,
};

fn readCells(bytes: []const u8) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += cell_bytes) {
        const cell = std.mem.readInt(u32, bytes[i..][0..cell_bytes], .big);
        value = (value << 32) | cell;
    }
    return value;
}

fn hasString(list: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, 0);
    while (it.next()) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}

fn cString(value: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, value, 0)) |end| value[0..end] else value;
}

/// Walk the tree once. A tree that fails to parse gives what was found before
/// the failure.
pub fn scan(dtb: []const u8) Scan {
    var out: Scan = .{};
    var rd = conduit.dtree.Reader.initBuffer(dtb) catch return out;
    var it = rd.nodeIterator();
    var stack: [max_depth]Frame = @splat(.{});
    var sp: usize = 0;
    var nor_taken = false;
    var cfi_taken = false;
    while (it.next() catch return out) |event| switch (event) {
        .begin => |bg| {
            if (sp + 1 >= max_depth) return out;
            const parent = stack[sp];
            sp += 1;
            stack[sp] = .{
                .name = bg.name,
                .reg_addr_cells = parent.addr_cells,
                .reg_size_cells = parent.size_cells,
            };
        },
        .prop => |p| {
            const node = &stack[sp];
            if (std.mem.eql(u8, p.name, "#address-cells") and p.value.len >= cell_bytes) {
                node.addr_cells = std.mem.readInt(u32, p.value[0..cell_bytes], .big);
            } else if (std.mem.eql(u8, p.name, "#size-cells") and p.value.len >= cell_bytes) {
                node.size_cells = std.mem.readInt(u32, p.value[0..cell_bytes], .big);
            } else if (std.mem.eql(u8, p.name, "reg")) {
                node.reg = p.value;
            } else if (std.mem.eql(u8, p.name, "reg-names")) {
                node.reg_names = p.value;
            } else if (std.mem.eql(u8, p.name, "label")) {
                node.label = cString(p.value);
            } else if (std.mem.eql(u8, p.name, "read-only")) {
                node.read_only = true;
            } else if (std.mem.eql(u8, p.name, "compatible")) {
                if (!nor_taken and hasString(p.value, "jedec,spi-nor")) {
                    node.is_nor = true;
                    nor_taken = true;
                }
                if (!cfi_taken and hasString(p.value, "cfi-flash")) {
                    node.is_cfi = true;
                    cfi_taken = true;
                }
                node.is_fixed_partitions = hasString(p.value, "fixed-partitions");
            }
        },
        .end => {
            const node = stack[sp];
            const parent = stack[sp - 1];
            const grandparent = stack[if (sp >= 2) sp - 2 else 0];
            const reg: Reg = .{
                .bytes = node.reg,
                .addr_cells = node.reg_addr_cells,
                .size_cells = node.reg_size_cells,
            };
            if (node.is_nor) {
                out.nor_reg = reg;
                out.nor_names = node.reg_names;
            }
            if (node.is_cfi) out.cfi_reg = reg;
            const under_flash = parent.is_nor or
                (parent.is_fixed_partitions and sp >= 2 and grandparent.is_nor);
            if (under_flash and std.mem.startsWith(u8, node.name, "partition@")) {
                // A partition that does not decode keeps its slot, so the later
                // indices stay equal to the hardware bit numbers.
                const r = reg.entry(0) orelse blk: {
                    out.malformed = true;
                    break :blk Region{ .base = 0, .size = 0 };
                };
                if (out.count < max_partitions) out.parts[out.count] = .{
                    .label = node.label,
                    .offset = r.base,
                    .size = r.size,
                    .read_only = node.read_only,
                };
                out.count += 1;
            }
            sp -= 1;
        },
    };
    return out;
}

/// Index of the first partition with this label.
pub fn findPartition(parts: []const Partition, label: []const u8) ?usize {
    for (parts, 0..) |p, i| if (std.mem.eql(u8, p.label, label)) return i;
    return null;
}

const testing = std.testing;
const dtree = conduit.dtree;

const Shape = struct {
    cells: u32 = 2,
    swapped: bool = false,
    names: bool = true,
    nested: bool = true,
    vars: bool = true,
};

fn addPartition(b: *dtree.Builder, name: []const u8, label: []const u8, offset: u32, size: u32, read_only: bool) !void {
    try b.beginNode(name);
    try b.propString("label", label);
    try b.propCells("reg", &.{ offset, size });
    if (read_only) try b.propEmpty("read-only");
    try b.endNode();
}

fn flashTree(gpa: std.mem.Allocator, shape: Shape) ![]u8 {
    var b = dtree.Builder.init(gpa);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", shape.cells);
    try b.propU32("#size-cells", shape.cells);
    try b.beginNode("flash@20000000");
    try b.propString("compatible", "jedec,spi-nor");
    const xip: []const u32 = if (shape.cells == 2)
        &.{ 0, 0x20000000, 0, 0x1000000 }
    else
        &.{ 0x20000000, 0x1000000 };
    const ctrl: []const u32 = if (shape.cells == 2)
        &.{ 0, 0x10030000, 0, 0x1000 }
    else
        &.{ 0x10030000, 0x1000 };
    var reg: [8]u32 = undefined;
    const first, const second = if (shape.swapped) .{ ctrl, xip } else .{ xip, ctrl };
    @memcpy(reg[0..first.len], first);
    @memcpy(reg[first.len..][0..second.len], second);
    if (shape.names) {
        try b.propCells("reg", reg[0 .. first.len + second.len]);
        try b.prop("reg-names", if (shape.swapped) "ctrl\x00xip\x00" else "xip\x00ctrl\x00");
    } else {
        try b.propCells("reg", first);
    }
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 1);
    if (shape.nested) {
        try b.beginNode("partitions");
        try b.propString("compatible", "fixed-partitions");
        try b.propU32("#address-cells", 1);
        try b.propU32("#size-cells", 1);
    }
    try addPartition(&b, "partition@0", "fpga-bitstream", 0, 0x400000, false);
    try addPartition(&b, "partition@400000", "river-fsbl", 0x400000, 0x10000, false);
    try addPartition(&b, "partition@410000", "river-firmware", 0x410000, 0x3f0000, false);
    if (shape.vars) try addPartition(&b, "partition@800000", "river-vars", 0x800000, 0x40000, true);
    if (shape.nested) try b.endNode();
    try b.endNode();
    try b.endNode();
    return b.finish();
}

fn expectRegion(want_base: u64, want_size: u64, got: ?Region) !void {
    const r = got orelse return error.TestExpectedRegion;
    try testing.expectEqual(want_base, r.base);
    try testing.expectEqual(want_size, r.size);
}

fn expectFlashLayout(dtb: []const u8) !void {
    const found = scan(dtb);
    try expectRegion(0x20000000, 0x1000000, found.norRegion("xip"));
    try expectRegion(0x10030000, 0x1000, found.norRegion("ctrl"));
    try testing.expect(found.norRegion("other") == null);
    try testing.expectEqual(@as(usize, 4), found.count);
    const want = [_]Partition{
        .{ .label = "fpga-bitstream", .offset = 0, .size = 0x400000, .read_only = false },
        .{ .label = "river-fsbl", .offset = 0x400000, .size = 0x10000, .read_only = false },
        .{ .label = "river-firmware", .offset = 0x410000, .size = 0x3f0000, .read_only = false },
        .{ .label = "river-vars", .offset = 0x800000, .size = 0x40000, .read_only = true },
    };
    for (want, 0..) |w, i| {
        if (i >= found.partitions().len) return error.TestExpectedPartition;
        const got = found.parts[i];
        try testing.expectEqualStrings(w.label, got.label);
        try testing.expectEqual(w.offset, got.offset);
        try testing.expectEqual(w.size, got.size);
        try testing.expectEqual(w.read_only, got.read_only);
    }
    try testing.expectEqual(@as(usize, 4), found.partitions().len);
}

test "two cell parent gives both ports and four partitions" {
    const dtb = try flashTree(testing.allocator, .{});
    defer testing.allocator.free(dtb);
    try expectFlashLayout(dtb);
}

test "one cell parent gives both ports and four partitions" {
    const dtb = try flashTree(testing.allocator, .{ .cells = 1 });
    defer testing.allocator.free(dtb);
    try expectFlashLayout(dtb);
}

test "reg-names order decides which entry is which" {
    for ([_]u32{ 1, 2 }) |cells| {
        const dtb = try flashTree(testing.allocator, .{ .cells = cells, .swapped = true });
        defer testing.allocator.free(dtb);
        try expectFlashLayout(dtb);
    }
}

test "one reg entry and no reg-names has no ctrl port" {
    const dtb = try flashTree(testing.allocator, .{ .names = false });
    defer testing.allocator.free(dtb);
    try testing.expect(scan(dtb).norRegion("ctrl") == null);
    try testing.expect(scan(dtb).norRegion("xip") == null);
    try testing.expectEqual(@as(usize, 4), scan(dtb).count);
}

test "a tree without river-vars has no vars index" {
    const dtb = try flashTree(testing.allocator, .{ .vars = false });
    defer testing.allocator.free(dtb);
    const found = scan(dtb);
    try testing.expectEqual(@as(usize, 3), found.partitions().len);
    try testing.expect(findPartition(found.partitions(), "river-vars") == null);
    try testing.expectEqual(@as(?usize, 1), findPartition(found.partitions(), "river-fsbl"));
}

test "river-vars index is found in a full tree" {
    const dtb = try flashTree(testing.allocator, .{});
    defer testing.allocator.free(dtb);
    const found = scan(dtb);
    try testing.expectEqual(@as(?usize, 3), findPartition(found.partitions(), "river-vars"));
}

test "partitions as direct children of the flash node" {
    for ([_]u32{ 1, 2 }) |cells| {
        const dtb = try flashTree(testing.allocator, .{ .cells = cells, .nested = false });
        defer testing.allocator.free(dtb);
        try expectFlashLayout(dtb);
    }
}

test "qemu virt tree has two cfi banks and no spi flash" {
    var b = dtree.Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.beginNode("flash@20000000");
    try b.propString("compatible", "cfi-flash");
    try b.propCells("reg", &.{ 0, 0x20000000, 0, 0x2000000, 0, 0x22000000, 0, 0x2000000 });
    try b.propU32("bank-width", 4);
    try b.endNode();
    try b.endNode();
    const dtb = try b.finish();
    defer testing.allocator.free(dtb);
    try expectRegion(0x20000000, 0x2000000, scan(dtb).cfiBank(0));
    try expectRegion(0x22000000, 0x2000000, scan(dtb).cfiBank(1));
    try testing.expect(scan(dtb).cfiBank(2) == null);
    try testing.expect(scan(dtb).norRegion("ctrl") == null);
    try testing.expectEqual(@as(usize, 0), scan(dtb).count);
}

test "a spi flash tree has no cfi bank" {
    const dtb = try flashTree(testing.allocator, .{});
    defer testing.allocator.free(dtb);
    try testing.expect(scan(dtb).cfiBank(0) == null);
}

test "a partition with a truncated reg is flagged and keeps its slot" {
    var b = dtree.Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginNode("");
    try b.beginNode("flash@0");
    try b.propString("compatible", "jedec,spi-nor");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 1);
    try addPartition(&b, "partition@0", "first", 0, 0x1000, false);
    try b.beginNode("partition@1000");
    try b.propString("label", "broken");
    try b.propU32("reg", 0x1000);
    try b.endNode();
    try addPartition(&b, "partition@2000", "last", 0x2000, 0x1000, false);
    try b.endNode();
    try b.endNode();
    const dtb = try b.finish();
    defer testing.allocator.free(dtb);
    try testing.expect(scan(dtb).malformed);
    try testing.expectEqual(@as(usize, 3), scan(dtb).count);
    const found = scan(dtb);
    try testing.expectEqualStrings("last", found.parts[2].label);
    try testing.expectEqual(@as(u64, 0), found.parts[1].size);
}

test "a good tree is not flagged" {
    const dtb = try flashTree(testing.allocator, .{});
    defer testing.allocator.free(dtb);
    try testing.expect(!scan(dtb).malformed);
}

test "cells above 32 bits decode for reg and cfi banks" {
    var b = dtree.Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.beginNode("flash@120000000");
    try b.propString("compatible", "jedec,spi-nor");
    try b.propCells("reg", &.{ 1, 0x20000000, 1, 0x80000000, 0, 0x10030000, 0, 0x1000 });
    try b.prop("reg-names", "xip\x00ctrl\x00");
    try b.endNode();
    try b.beginNode("cfi@130000000");
    try b.propString("compatible", "cfi-flash");
    try b.propCells("reg", &.{ 1, 0x30000000, 2, 0, 1, 0x40000000, 2, 0x10 });
    try b.endNode();
    try b.endNode();
    const dtb = try b.finish();
    defer testing.allocator.free(dtb);
    try expectRegion(0x1_2000_0000, 0x1_8000_0000, scan(dtb).norRegion("xip"));
    try expectRegion(0x1_3000_0000, 0x2_0000_0000, scan(dtb).cfiBank(0));
    try expectRegion(0x1_4000_0000, 0x2_0000_0010, scan(dtb).cfiBank(1));
}

const comptime_dtb = blk: {
    @setEvalBranchQuota(200_000);
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var b = dtree.Builder.init(fba.allocator());
    b.beginNode("") catch unreachable;
    b.beginNode("flash@0") catch unreachable;
    b.propString("compatible", "jedec,spi-nor") catch unreachable;
    b.propU32("#address-cells", 1) catch unreachable;
    b.propU32("#size-cells", 1) catch unreachable;
    addPartition(&b, "partition@0", "alpha", 0, 0x1000, false) catch unreachable;
    addPartition(&b, "partition@1000", "beta", 0x1000, 0x2000, true) catch unreachable;
    b.endNode() catch unreachable;
    b.endNode() catch unreachable;
    const made = b.finish() catch unreachable;
    var out: [made.len]u8 = undefined;
    @memcpy(&out, made);
    break :blk out;
};

const comptime_parts = blk: {
    @setEvalBranchQuota(200_000);
    const found = scan(&comptime_dtb);
    std.debug.assert(!found.malformed);
    std.debug.assert(found.count == 2);
    std.debug.assert(std.mem.eql(u8, found.parts[1].label, "beta"));
    std.debug.assert(found.parts[1].offset == 0x1000);
    std.debug.assert(found.parts[1].read_only);
    std.debug.assert(!found.parts[0].read_only);
    var arr: [found.partitions().len]Partition = undefined;
    for (found.partitions(), 0..) |p, i| arr[i] = p;
    break :blk arr;
};

test "partitions scanned at comptime are usable at run time" {
    const slice: []const Partition = &comptime_parts;
    try testing.expectEqual(@as(usize, 2), slice.len);
    try testing.expectEqualStrings("alpha", slice[0].label);
    try testing.expectEqual(@as(u64, 0x2000), slice[1].size);
}
