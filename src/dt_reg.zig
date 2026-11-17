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
    matched: bool = false,
};

const Node = struct {
    reg: []const u8,
    addr_cells: u32,
    size_cells: u32,
    prop: ?[]const u8,
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

/// The first node with this compatible, with the value of its property `want`.
fn find(dtb: []const u8, compatible: []const u8, want: []const u8) ?Node {
    var rd = conduit.dtree.Reader.initBuffer(dtb) catch return null;
    var it = rd.nodeIterator();
    var stack: [max_depth]Frame = @splat(.{});
    var sp: usize = 0;
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
            } else if (std.mem.eql(u8, p.name, "compatible")) {
                node.matched = hasString(p.value, compatible);
            }
            if (std.mem.eql(u8, p.name, want)) node.prop = p.value;
        },
        .end => {
            const node = stack[sp];
            const parent = stack[sp - 1];
            sp -= 1;
            if (!node.matched) continue;
            return .{
                .reg = node.reg,
                .addr_cells = parent.addr_cells,
                .size_cells = parent.size_cells,
                .prop = node.prop,
            };
        },
    };
    return null;
}

/// The first `reg` entry of the first node with this compatible. Null when no
/// node matches or the entry does not decode.
pub fn first(dtb: []const u8, compatible: []const u8) ?Region {
    const node = find(dtb, compatible, "") orelse return null;
    if (node.addr_cells == 0 or node.addr_cells > 2 or node.size_cells > 2) return null;
    const addr_len = node.addr_cells * cell_bytes;
    const len = addr_len + node.size_cells * cell_bytes;
    if (node.reg.len < len) return null;
    return .{
        .base = readCells(node.reg[0..addr_len]),
        .size = readCells(node.reg[addr_len..len]),
    };
}

/// A one cell property of the first node with this compatible.
pub fn propU32(dtb: []const u8, compatible: []const u8, name: []const u8) ?u32 {
    const node = find(dtb, compatible, name) orelse return null;
    const value = node.prop orelse return null;
    if (value.len != cell_bytes) return null;
    return std.mem.readInt(u32, value[0..cell_bytes], .big);
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
