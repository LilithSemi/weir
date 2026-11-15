//! Bodies of the small fixed ACPI tables Weir writes: SPCR and RHCT.
//!
//! A body is the part after the 36-byte SDT header. This file has no platform
//! imports, so its tests run on the host.

const std = @import("std");
const structs = @import("structs.zig");

/// SPCR body: a full 16550 console at `uart_base`, byte-wide registers,
/// 115200 8N1, polled.
pub fn spcr(uart_base: u64) structs.SpcrBody {
    return .{
        .base_address = .{ .bit_width = 8, .access_size = 1, .address = uart_base },
        .baud_rate = 7,
        .stop_bits = 1,
    };
}

fn store(buf: []u8, off: usize, value: anytype) void {
    @memcpy(buf[off..][0..@sizeOf(@TypeOf(value))], std.mem.asBytes(&value));
}

/// Build the RHCT body into `buf`: the hart timebase, then an ISA-string node,
/// an MMU node (the paging scheme the OS needs before it can enable paging), and
/// a hart-info node that names both. Returns the used bytes.
pub fn rhct(buf: []u8, timebase: u64, isa: []const u8, mmu_type: u8) []const u8 {
    const isa_len = isa.len + 1; // with the NUL terminator
    const isa_node_len = std.mem.alignForward(usize, @sizeOf(structs.RhctIsaNode) + isa_len, 2);
    const isa_off = @sizeOf(structs.RhctBody);
    const mmu_off = isa_off + isa_node_len;
    const hart_off = mmu_off + @sizeOf(structs.RhctMmuNode);
    const body = buf[0 .. hart_off + @sizeOf(structs.RhctHartInfo)];
    @memset(body, 0);

    store(body, 0, structs.RhctBody{
        .timebase_hz = timebase,
        .node_count = 3,
        .node_offset = structs.sdt_header_len + isa_off,
    });
    store(body, isa_off, structs.RhctIsaNode{
        .header = .{ .type = .isa_string, .length = @intCast(isa_node_len) },
        .isa_length = @intCast(isa_len),
    });
    @memcpy(body[isa_off + @sizeOf(structs.RhctIsaNode) ..][0..isa.len], isa);
    store(body, mmu_off, structs.RhctMmuNode{ .mmu_type = mmu_type });
    store(body, hart_off, structs.RhctHartInfo{
        .uid = 0,
        .offsets = .{
            @intCast(structs.sdt_header_len + isa_off),
            @intCast(structs.sdt_header_len + mmu_off),
        },
    });
    return body;
}

test "the SPCR body describes a polled 16550 at the UART base" {
    const body = spcr(0x1000_0000);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, std.mem.asBytes(&body));
}

test "the RHCT body holds an ISA node, an MMU node and a hart node that names both" {
    var buf: [512]u8 = undefined;
    const body = rhct(&buf, 10_000_000, "rv64imac", 0);
    try std.testing.expectEqualSlices(u8, &.{
        // flags, time base, node count, offset of the first node
        0x00, 0x00, 0x00, 0x00, 0x80, 0x96, 0x98, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00,
        // ISA string node, 18 bytes with the pad
        0x00, 0x00, 0x12, 0x00, 0x01, 0x00, 0x09, 0x00, 'r',  'v',
        '6',  '4',  'i',  'm',  'a',  'c',  0x00, 0x00,
        // MMU node
        0x02, 0x00,
        0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
        // hart info node: UID 0, then the table offsets of the ISA and MMU nodes
        0xff, 0xff, 0x14, 0x00,
        0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00,
        0x00, 0x00, 0x4a, 0x00, 0x00, 0x00,
    }, body);
}

test "an ISA node that is already even gets no pad" {
    var buf: [512]u8 = undefined;
    const body = rhct(&buf, 1, "rv64ima", 1);
    // Node length: 8 header bytes + 7 characters + NUL = 16, already even.
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, body[22..24], .little));
    try std.testing.expectEqual(@as(usize, 20 + 16 + 8 + 20), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[20 + 16 + 7]); // MMU type: Sv48
}
