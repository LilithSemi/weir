//! Facts about a device tree node that is found by its compatible. Each function
//! takes the blob bytes, so the firmware calls it at comptime and host tests
//! call it at run time.

const std = @import("std");
const conduit = @import("conduit");

pub const Region = struct { base: u64, size: u64 };

const max_depth = 16;
const cell_bytes = 4;

const Frame = struct {
    // The cells this node declares for its children.
    addr_cells: u32 = 2,
    size_cells: u32 = 1,
    reg: []const u8 = &.{},
    prop: ?[]const u8 = null,
    compatible: bool = false,
    phandle: ?u32 = null,
};

const Node = struct {
    reg: []const u8,
    addr_cells: u32,
    size_cells: u32,
    prop: ?[]const u8,
    /// The first `reg` entry of the parent node.
    parent: ?Region = null,

    fn region(node: Node) ?Region {
        if (node.addr_cells == 0 or node.addr_cells > 2 or node.size_cells > 2) return null;
        const addr_len = node.addr_cells * cell_bytes;
        const len = addr_len + node.size_cells * cell_bytes;
        if (node.reg.len < len) return null;
        return .{
            .base = readCells(node.reg[0..addr_len]),
            .size = readCells(node.reg[addr_len..len]),
        };
    }
};

const Match = union(enum) {
    /// The node number `index` of the nodes with the compatible `id`.
    compatible: struct { id: []const u8, index: usize },
    phandle: u32,
};

fn readCells(bytes: []const u8) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += cell_bytes) {
        value = (value << 32) | std.mem.readInt(u32, bytes[i..][0..cell_bytes], .big);
    }
    return value;
}

fn hasString(list: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, 0);
    while (it.next()) |s| if (std.mem.eql(u8, s, want)) return true;
    return false;
}

/// The node that `match` selects, with the value of its property `want`.
fn find(dtb: []const u8, match: Match, want: []const u8) ?Node {
    var rd = conduit.dtree.Reader.initBuffer(dtb) catch return null;
    var it = rd.nodeIterator();
    var stack: [max_depth]Frame = @splat(.{});
    var sp: usize = 0;
    var seen: usize = 0;
    while (it.next() catch return null) |event| switch (event) {
        .begin => {
            if (sp + 1 >= max_depth) return null;
            sp += 1;
            stack[sp] = .{};
        },
        .prop => |p| {
            const node = &stack[sp];
            if (std.mem.eql(u8, p.name, "#address-cells") and p.value.len >= cell_bytes) {
                node.addr_cells = std.mem.readInt(u32, p.value[0..cell_bytes], .big);
            } else if (std.mem.eql(u8, p.name, "#size-cells") and p.value.len >= cell_bytes) {
                node.size_cells = std.mem.readInt(u32, p.value[0..cell_bytes], .big);
            } else if (std.mem.eql(u8, p.name, "reg")) {
                node.reg = p.value;
            } else if (std.mem.eql(u8, p.name, "phandle") and p.value.len == cell_bytes) {
                node.phandle = std.mem.readInt(u32, p.value[0..cell_bytes], .big);
            } else if (std.mem.eql(u8, p.name, "compatible")) {
                switch (match) {
                    .compatible => |c| node.compatible = hasString(p.value, c.id),
                    .phandle => {},
                }
            }
            if (std.mem.eql(u8, p.name, want)) node.prop = p.value;
        },
        .end => {
            const node = stack[sp];
            const parent = stack[sp - 1];
            sp -= 1;
            const hit = switch (match) {
                .compatible => |c| blk: {
                    if (!node.compatible) break :blk false;
                    seen += 1;
                    break :blk seen == c.index + 1;
                },
                .phandle => |want_handle| node.phandle == want_handle,
            };
            if (!hit) continue;
            const above: Frame = if (sp > 0) stack[sp - 1] else .{};
            const parent_node: Node = .{
                .reg = parent.reg,
                .addr_cells = above.addr_cells,
                .size_cells = above.size_cells,
                .prop = null,
            };
            return .{
                .reg = node.reg,
                .addr_cells = parent.addr_cells,
                .size_cells = parent.size_cells,
                .prop = node.prop,
                .parent = parent_node.region(),
            };
        },
    };
    return null;
}

/// The first `reg` entry of the first node with this compatible. Null when no
/// node matches or the entry does not decode.
pub fn first(dtb: []const u8, compatible: []const u8) ?Region {
    return nth(dtb, compatible, 0);
}

/// The first `reg` entry of node number `index` of the nodes with this
/// compatible, in the order of their ends in the tree.
pub fn nth(dtb: []const u8, compatible: []const u8, index: usize) ?Region {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = index } }, "") orelse return null;
    return node.region();
}

/// The number of nodes with this compatible.
pub fn count(dtb: []const u8, compatible: []const u8) usize {
    var total: usize = 0;
    while (find(dtb, .{ .compatible = .{ .id = compatible, .index = total } }, "") != null) total += 1;
    return total;
}

/// The first `reg` entry of the node with this phandle.
pub fn byPhandle(dtb: []const u8, phandle: u32) ?Region {
    const node = find(dtb, .{ .phandle = phandle }, "") orelse return null;
    return node.region();
}

/// The first `reg` entry of the parent of the first node with this compatible.
pub fn parentOf(dtb: []const u8, compatible: []const u8) ?Region {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = 0 } }, "") orelse return null;
    return node.parent;
}

/// A one cell property of the first node with this compatible.
pub fn propU32(dtb: []const u8, compatible: []const u8, name: []const u8) ?u32 {
    return nthPropU32(dtb, compatible, 0, name);
}

/// A one cell property of node number `index` of the nodes with this compatible.
pub fn nthPropU32(dtb: []const u8, compatible: []const u8, index: usize, name: []const u8) ?u32 {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = index } }, name) orelse return null;
    const value = node.prop orelse return null;
    if (value.len != cell_bytes) return null;
    return std.mem.readInt(u32, value[0..cell_bytes], .big);
}

/// True when node number `index` of the nodes with this compatible has the
/// property, with any value or none.
pub fn nthHasProp(dtb: []const u8, compatible: []const u8, index: usize, name: []const u8) bool {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = index } }, name) orelse return false;
    return node.prop != null;
}

/// Cell number `index` of a property of the first node with this compatible.
pub fn propCell(dtb: []const u8, compatible: []const u8, name: []const u8, index: usize) ?u32 {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = 0 } }, name) orelse return null;
    const value = node.prop orelse return null;
    const start = index * cell_bytes;
    if (value.len < start + cell_bytes) return null;
    return std.mem.readInt(u32, value[start..][0..cell_bytes], .big);
}

/// A property with one address and size pair, in the cells of the parent, of
/// node number `index` of the nodes with this compatible.
pub fn nthPropRegion(dtb: []const u8, compatible: []const u8, index: usize, name: []const u8) ?Region {
    const node = find(dtb, .{ .compatible = .{ .id = compatible, .index = index } }, name) orelse return null;
    const pair: Node = .{
        .reg = node.prop orelse return null,
        .addr_cells = node.addr_cells,
        .size_cells = node.size_cells,
        .prop = null,
    };
    return pair.region();
}

const testing = std.testing;

fn tree(gpa: std.mem.Allocator, cells: u32) ![]u8 {
    var b = conduit.dtree.Builder.init(gpa);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", 2);
    try b.propU32("#size-cells", 2);
    try b.beginNode("soc");
    try b.propU32("#address-cells", cells);
    try b.propU32("#size-cells", cells);
    try b.beginNode("uart@10000000");
    try b.propString("compatible", "ns16550a");
    try b.propU32("reg-shift", 2);
    try b.prop("no-loopback-test", "");
    try b.propCells("reg", if (cells == 2) &.{ 0, 0x10000000, 0, 0x100 } else &.{ 0x10000000, 0x100 });
    try b.endNode();
    try b.beginNode("unit-id@10050000");
    try b.propCells("reg", if (cells == 2) &.{ 1, 0x10050000, 0, 0x1000 } else &.{ 0x10050000, 0x1000 });
    try b.prop("compatible", "harbor,unit-id\x00vendor,other\x00");
    try b.endNode();
    try b.endNode();
    try b.endNode();
    return b.finish();
}

test "a node under a one cell bus" {
    const dtb = try tree(testing.allocator, 1);
    defer testing.allocator.free(dtb);
    const r = first(dtb, "harbor,unit-id").?;
    try testing.expectEqual(@as(u64, 0x10050000), r.base);
    try testing.expectEqual(@as(u64, 0x1000), r.size);
}

test "a node under a two cell bus" {
    const dtb = try tree(testing.allocator, 2);
    defer testing.allocator.free(dtb);
    const r = first(dtb, "vendor,other").?;
    try testing.expectEqual(@as(u64, 0x1_10050000), r.base);
    try testing.expectEqual(@as(u64, 0x1000), r.size);
}

test "no node with the compatible" {
    const dtb = try tree(testing.allocator, 1);
    defer testing.allocator.free(dtb);
    try testing.expect(first(dtb, "harbor,unit") == null);
    try testing.expect(first(&.{}, "harbor,unit-id") == null);
}

test "a one cell property" {
    const dtb = try tree(testing.allocator, 1);
    defer testing.allocator.free(dtb);
    try testing.expectEqual(@as(?u32, 2), propU32(dtb, "ns16550a", "reg-shift"));
    try testing.expectEqual(@as(?u32, null), propU32(dtb, "ns16550a", "reg-io-width"));
    try testing.expectEqual(@as(?u32, null), propU32(dtb, "harbor,unit-id", "reg-shift"));
    try testing.expectEqual(@as(?u32, null), propU32(dtb, "ns16550a", "compatible"));
}

test "one cell of a property" {
    const dtb = try displayTree(testing.allocator);
    defer testing.allocator.free(dtb);
    try testing.expectEqual(@as(?u32, 0x80000000), propCell(dtb, "harbor,display", "harbor,scanout-memory", 0));
    try testing.expectEqual(@as(?u32, 0x2000000), propCell(dtb, "harbor,display", "harbor,scanout-memory", 1));
    try testing.expectEqual(@as(?u32, null), propCell(dtb, "harbor,display", "harbor,scanout-memory", 2));
    try testing.expectEqual(@as(?u32, null), propCell(dtb, "harbor,display", "none", 0));
}

test "the parent of a node" {
    var b = conduit.dtree.Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 1);
    try b.beginNode("reset@10009000");
    try b.propCells("reg", &.{ 0x10009000, 0x1000 });
    try b.beginNode("reboot");
    try b.propString("compatible", "syscon-reboot");
    try b.endNode();
    try b.endNode();
    try b.beginNode("poweroff");
    try b.propString("compatible", "syscon-poweroff");
    try b.endNode();
    try b.endNode();
    const dtb = try b.finish();
    defer testing.allocator.free(dtb);
    try testing.expectEqual(@as(u64, 0x10009000), parentOf(dtb, "syscon-reboot").?.base);
    try testing.expect(parentOf(dtb, "syscon-poweroff") == null);
    try testing.expect(parentOf(dtb, "syscon-none") == null);
}

fn displayTree(gpa: std.mem.Allocator) ![]u8 {
    var b = conduit.dtree.Builder.init(gpa);
    defer b.deinit();
    try b.beginNode("");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 1);
    try b.beginNode("reserved-memory");
    try b.propU32("#address-cells", 1);
    try b.propU32("#size-cells", 1);
    try b.beginNode("framebuffer@81e00000");
    try b.propCells("reg", &.{ 0x81e00000, 0x200000 });
    try b.propU32("phandle", 7);
    try b.endNode();
    try b.endNode();
    try b.beginNode("display@10003000");
    try b.propString("compatible", "harbor,display");
    try b.propCells("reg", &.{ 0x10003000, 0x1000 });
    try b.propU32("memory-region", 7);
    try b.propCells("harbor,scanout-memory", &.{ 0x80000000, 0x2000000 });
    try b.endNode();
    try b.beginNode("display@10004000");
    try b.propString("compatible", "harbor,display");
    try b.propCells("reg", &.{ 0x10004000, 0x1000 });
    try b.endNode();
    try b.endNode();
    return b.finish();
}

test "each node with the same compatible has its own number" {
    const dtb = try displayTree(testing.allocator);
    defer testing.allocator.free(dtb);
    try testing.expectEqual(@as(usize, 2), count(dtb, "harbor,display"));
    try testing.expectEqual(@as(usize, 0), count(dtb, "harbor,none"));
    try testing.expectEqual(@as(u64, 0x10003000), nth(dtb, "harbor,display", 0).?.base);
    try testing.expectEqual(@as(u64, 0x10004000), nth(dtb, "harbor,display", 1).?.base);
    try testing.expect(nth(dtb, "harbor,display", 2) == null);
    try testing.expectEqual(@as(?u32, 7), nthPropU32(dtb, "harbor,display", 0, "memory-region"));
    try testing.expectEqual(@as(?u32, null), nthPropU32(dtb, "harbor,display", 1, "memory-region"));
    const scanout = nthPropRegion(dtb, "harbor,display", 0, "harbor,scanout-memory").?;
    try testing.expectEqual(@as(u64, 0x80000000), scanout.base);
    try testing.expectEqual(@as(u64, 0x2000000), scanout.size);
    try testing.expect(nthPropRegion(dtb, "harbor,display", 1, "harbor,scanout-memory") == null);
    try testing.expect(nthPropRegion(dtb, "harbor,display", 0, "memory-region") == null);
}

test "a node is found by its phandle" {
    const dtb = try displayTree(testing.allocator);
    defer testing.allocator.free(dtb);
    const r = byPhandle(dtb, 7).?;
    try testing.expectEqual(@as(u64, 0x81e00000), r.base);
    try testing.expectEqual(@as(u64, 0x200000), r.size);
    try testing.expect(byPhandle(dtb, 8) == null);
}

test "a property with no value is present" {
    const dtb = try tree(testing.allocator, 1);
    defer testing.allocator.free(dtb);
    try testing.expect(nthHasProp(dtb, "ns16550a", 0, "no-loopback-test"));
    try testing.expect(nthHasProp(dtb, "ns16550a", 0, "reg-shift"));
    try testing.expect(!nthHasProp(dtb, "ns16550a", 0, "cap-sd-highspeed"));
    try testing.expect(!nthHasProp(dtb, "ns16550a", 1, "reg-shift"));
}
