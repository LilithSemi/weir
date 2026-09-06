//! MADT ("APIC") body construction for a RISC-V platform with a PLIC.
//!
//! The body follows the 36-byte SDT header. It starts with an 8-byte fixed part
//! and continues with a list of interrupt controller structures, each one a
//! type/length record. Weir emits one RINTC per hart and one PLIC structure.
//! Both layouts are from ACPI 6.6: "RISC-V Interrupt Controller (RINTC)
//! Structure" (type 0x18) and "RISC-V Platform-Level Interrupt Controller
//! (PLIC) Structure" (type 0x1B).
//!
//! On the ACPI path an OS gets the PLIC's GSI base, source count and register
//! window from this table, not from the DSDT. The DSDT only holds the device
//! with its `RSCV0001` _HID and its `_GSB`, and the OS ties the two together by
//! the GSI base. So the values here must agree with the hardware.
//!
//! This file has no dependencies on the platform, so its tests run on the host.

const std = @import("std");

/// MADT subtable type: RISC-V Interrupt Controller.
pub const type_rintc: u8 = 0x18;
/// MADT subtable type: RISC-V Platform-Level Interrupt Controller.
pub const type_plic: u8 = 0x1b;

pub const rintc_len: u8 = 36;
pub const plic_len: u8 = 36;

/// The fixed part of the body: the local interrupt controller address and the
/// multiple-APIC flags. Both are zero on RISC-V.
pub const fixed_len: usize = 8;

/// MADT revision. ACPI 6.6 is the first revision that defines the RISC-V
/// structures this file writes, and its MADT revision is 7. An older claimed
/// revision would describe a table that cannot hold a type 0x18 or 0x1B record.
pub const revision: u8 = 7;

/// RISC-V local interrupt causes, from the privileged specification. A PLIC
/// context drives exactly one of them on one hart.
pub const cause_supervisor_external: u32 = 9;
pub const cause_machine_external: u32 = 11;

/// One PLIC context, in the order the PLIC declares its contexts. The index in
/// that list is the context number the PLIC decodes in its register space.
pub const Context = struct {
    hart_id: u64,
    cause: u32,
};

/// A hart, as one RINTC record.
///
/// Emit exactly one RINTC per hart. An OS counts the RINTC records to count the
/// CPUs, and counts the ones that name a given PLIC to count that PLIC's
/// contexts. A second RINTC for the same hart would make the OS see a second
/// CPU that does not exist.
pub const Hart = struct {
    hart_id: u64,
    /// ACPI processor UID, the value a DSDT processor device's `_UID` must have.
    uid: u32,
    /// The PLIC context that interrupts this hart, or null when it has none.
    context: ?u16,
};

pub const Plic = struct {
    /// PLIC ID. The RINTC records name this value to link a hart to this PLIC.
    id: u8 = 0,
    /// Hardware ID. It is informational, and no OS driver reads it today.
    hw_id: [8]u8 = @splat(0),
    /// Number of external interrupt sources the PLIC implements (`riscv,ndev`
    /// in the device tree). An OS sizes its interrupt domain from it, so too
    /// large a value makes the OS write to registers that do not exist.
    num_irqs: u16,
    /// Highest interrupt priority the PLIC accepts.
    max_priority: u16,
    /// Size of the PLIC register space.
    size: u32,
    base: u64,
    /// First global system interrupt this PLIC owns. It must equal the `_GSB`
    /// of the DSDT device for the same PLIC. The OS matches the two to attach
    /// this record to that device.
    gsi_base: u32 = 0,
};

/// Bytes `build` writes for `hart_count` harts.
pub fn bodyLen(hart_count: usize) usize {
    return fixed_len + hart_count * rintc_len + plic_len;
}

/// The PLIC context that interrupts `hart_id` at its supervisor external
/// interrupt, or null when the PLIC declares none for that hart.
///
/// An OS runs in S-mode, so this is the context its RINTC must name. Weir keeps
/// the machine context of the same hart for itself.
pub fn supervisorContext(contexts: []const Context, hart_id: u64) ?u16 {
    for (contexts, 0..) |c, i| {
        if (c.hart_id != hart_id or c.cause != cause_supervisor_external) continue;
        // The field is 16 bits wide. A larger index cannot be encoded.
        if (i > std.math.maxInt(u16)) return null;
        return @intCast(i);
    }
    return null;
}

/// The RINTC external interrupt controller ID: which PLIC interrupts the hart,
/// and through which of that PLIC's contexts. Linux reads the low 16 bits as
/// the context number and bits 31:24 as the PLIC ID (drivers/irqchip/
/// irq-riscv-intc.c, `struct rintc_data`).
pub fn extIntcId(plic_id: u8, context: u16) u32 {
    return (@as(u32, plic_id) << 24) | context;
}

/// Write the MADT body into `buf` and return the bytes written. `buf` must hold
/// at least `bodyLen(harts.len)` bytes.
pub fn build(buf: []u8, harts: []const Hart, plic: Plic) []const u8 {
    std.debug.assert(buf.len >= bodyLen(harts.len));
    const body = buf[0..bodyLen(harts.len)];
    @memset(body, 0);
    // body[0..4] local interrupt controller address and body[4..8] flags stay
    // zero. RISC-V has no such controller and no PC-AT compatibility.
    var off: usize = fixed_len;
    for (harts) |h| {
        const r = body[off..][0..rintc_len];
        r[0] = type_rintc;
        r[1] = rintc_len;
        r[2] = 1; // version
        std.mem.writeInt(u32, r[4..8], 1, .little); // flags: enabled
        std.mem.writeInt(u64, r[8..16], h.hart_id, .little);
        std.mem.writeInt(u32, r[16..20], h.uid, .little);
        const ext: u32 = if (h.context) |c| extIntcId(plic.id, c) else 0;
        std.mem.writeInt(u32, r[20..24], ext, .little);
        // r[24..32] IMSIC base and r[32..36] IMSIC size stay zero. A PLIC
        // system has no IMSIC.
        off += rintc_len;
    }
    const p = body[off..][0..plic_len];
    p[0] = type_plic;
    p[1] = plic_len;
    p[2] = 1; // version
    p[3] = plic.id;
    @memcpy(p[4..12], &plic.hw_id);
    std.mem.writeInt(u16, p[12..14], plic.num_irqs, .little);
    std.mem.writeInt(u16, p[14..16], plic.max_priority, .little);
    // p[16..20] flags: ACPI 6.6 defines none.
    std.mem.writeInt(u32, p[20..24], plic.size, .little);
    std.mem.writeInt(u64, p[24..32], plic.base, .little);
    std.mem.writeInt(u32, p[32..36], plic.gsi_base, .little);
    return body;
}

// The delta_v1 hardware, from its generated device tree. The tests below pin the
// bytes Weir must emit for that board.
const delta_contexts = [_]Context{
    .{ .hart_id = 0, .cause = cause_machine_external },
    .{ .hart_id = 0, .cause = cause_supervisor_external },
};
const delta_plic = Plic{
    .num_irqs = 5,
    .max_priority = 7,
    .size = 0x0400_0000,
    .base = 0x0400_0000,
};

test "the supervisor context is chosen over the machine context of the same hart" {
    try std.testing.expectEqual(@as(?u16, 1), supervisorContext(&delta_contexts, 0));
}

test "a hart with no context in the list has no supervisor context" {
    try std.testing.expectEqual(@as(?u16, null), supervisorContext(&delta_contexts, 1));
}

test "a PLIC with only a machine context yields no supervisor context" {
    const only_machine = [_]Context{.{ .hart_id = 0, .cause = cause_machine_external }};
    try std.testing.expectEqual(@as(?u16, null), supervisorContext(&only_machine, 0));
}

test "extIntcId packs the PLIC id above the context number" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), extIntcId(0, 1));
    try std.testing.expectEqual(@as(u32, 0x0200_0003), extIntcId(2, 3));
}

test "the body is the fixed part plus one RINTC per hart plus one PLIC" {
    try std.testing.expectEqual(@as(usize, 8 + 36 + 36), bodyLen(1));
    try std.testing.expectEqual(@as(usize, 8 + 2 * 36 + 36), bodyLen(2));
}

test "the delta RINTC names PLIC 0 context 1, the supervisor context" {
    var buf: [256]u8 = undefined;
    const harts = [_]Hart{.{ .hart_id = 0, .uid = 0, .context = supervisorContext(&delta_contexts, 0) }};
    const body = build(&buf, &harts, delta_plic);

    try std.testing.expectEqual(@as(usize, 80), body.len);
    try std.testing.expectEqual(type_rintc, body[8]);
    try std.testing.expectEqual(rintc_len, body[9]);
    try std.testing.expectEqual(@as(u8, 1), body[10]); // version
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[12..16], .little)); // enabled
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[16..24], .little)); // hart id
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[24..28], .little)); // UID
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[28..32], .little));
    // No IMSIC on a PLIC system.
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[32..40], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[40..44], .little));
}

test "the delta PLIC structure carries the device tree's base, size and ndev" {
    var buf: [256]u8 = undefined;
    const harts = [_]Hart{.{ .hart_id = 0, .uid = 0, .context = 1 }};
    const body = build(&buf, &harts, delta_plic);
    const p = body[44..80];

    try std.testing.expectEqual(type_plic, p[0]);
    try std.testing.expectEqual(plic_len, p[1]);
    try std.testing.expectEqual(@as(u8, 1), p[2]); // version
    try std.testing.expectEqual(@as(u8, 0), p[3]); // PLIC id
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, p[12..14], .little));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, p[14..16], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, p[16..20], .little)); // flags
    try std.testing.expectEqual(@as(u32, 0x0400_0000), std.mem.readInt(u32, p[20..24], .little));
    try std.testing.expectEqual(@as(u64, 0x0400_0000), std.mem.readInt(u64, p[24..32], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, p[32..36], .little)); // GSI base
}

test "a hart with no supervisor context gets a zero external controller id" {
    var buf: [256]u8 = undefined;
    const harts = [_]Hart{.{ .hart_id = 3, .uid = 3, .context = null }};
    const body = build(&buf, &harts, delta_plic);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, body[28..32], .little));
}

test "walking the subtables consumes the body exactly, as an OS does" {
    var buf: [512]u8 = undefined;
    const harts = [_]Hart{
        .{ .hart_id = 0, .uid = 0, .context = 1 },
        .{ .hart_id = 1, .uid = 1, .context = 3 },
    };
    const body = build(&buf, &harts, delta_plic);

    var off: usize = fixed_len;
    var rintcs: usize = 0;
    var plics: usize = 0;
    while (off < body.len) {
        // An OS reads the 2-byte type/length prefix and steps by the length. A
        // zero length would make it loop forever.
        try std.testing.expect(off + 2 <= body.len);
        const len = body[off + 1];
        try std.testing.expect(len >= 2);
        try std.testing.expect(off + len <= body.len);
        switch (body[off]) {
            type_rintc => rintcs += 1,
            type_plic => plics += 1,
            else => return error.UnexpectedSubtable,
        }
        off += len;
    }
    try std.testing.expectEqual(body.len, off);
    try std.testing.expectEqual(@as(usize, 2), rintcs);
    try std.testing.expectEqual(@as(usize, 1), plics);
}

test "each hart gets its own RINTC with its own hart id and context" {
    var buf: [512]u8 = undefined;
    const harts = [_]Hart{
        .{ .hart_id = 0, .uid = 0, .context = 1 },
        .{ .hart_id = 1, .uid = 1, .context = 3 },
    };
    const body = build(&buf, &harts, delta_plic);

    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[16..24], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[28..32], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, body[52..60], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, body[60..64], .little)); // UID
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, body[64..68], .little));
}
