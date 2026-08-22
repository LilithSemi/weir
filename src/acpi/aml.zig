//! A tiny AML encoder for the DSDT Weir builds from the device tree when the
//! platform supplies no AML. It translates each device-tree node into a
//! `PRP0001` ACPI device: the node's `reg` and `interrupts` become the `_CRS`,
//! and its `compatible` and other properties become the `_DSD`. Linux then binds
//! the same driver it would from the device tree (the PRP0001 / _DSD "compatible"
//! bridge). The byte encoding matches iasl, so the result disassembles cleanly.
//!
//! This is not a general AML compiler. It emits only the fixed device shape
//! above. See the test vectors (from iasl) at the end.

const std = @import("std");

/// A device-tree property value, as it will appear in `_DSD`.
pub const Value = union(enum) {
    int: u64,
    str: []const u8,
    /// A list of strings, encoded as a package (used for `compatible`).
    strs: []const []const u8,
};

pub const Prop = struct { key: []const u8, value: Value };
pub const MemRegion = struct { base: u32, size: u32 };

/// One device translated from a device-tree node. Most nodes become a `PRP0001`
/// device whose driver matches on the `_DSD` "compatible" property. An interrupt
/// controller instead uses its native RISC-V ACPI HID (RSCV0001 PLIC / RSCV0002
/// APLIC) and a `_GSB` (global system interrupt base), with no `_DSD`, so the
/// kernel registers its irqchip and can map device interrupts.
pub const Device = struct {
    /// Four-character NameSeg, for example "D000".
    name: [4]u8,
    uid: u8,
    /// ACPI _HID. "PRP0001" is the device-tree bridge; a native HID (e.g.
    /// "RSCV0001") is used for a controller the kernel binds directly.
    hid: []const u8 = "PRP0001",
    /// _GSB (global system interrupt base) for an interrupt controller, else null.
    gsb: ?u32 = null,
    mem: []const MemRegion,
    irqs: []const u32,
    /// The node's properties, including "compatible". Emitted as `_DSD` when not
    /// empty. An interrupt controller has none (it uses the native HID + _GSB).
    props: []const Prop = &.{},
};

// The ACPI device-properties UUID (daffd814-6eba-4d8c-8a91-bc9bbf4aa301) as the
// 16 mixed-endian bytes ToUUID emits.
const props_uuid = [16]u8{
    0x14, 0xd8, 0xff, 0xda, 0xba, 0x6e, 0x8c, 0x4d,
    0x8a, 0x91, 0xbc, 0x9b, 0xbf, 0x4a, 0xa3, 0x01,
};

// A bounded byte appender over a caller buffer.
const W = struct {
    buf: []u8,
    len: usize = 0,
    fn byte(self: *W, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }
    fn bytes(self: *W, bs: []const u8) void {
        @memcpy(self.buf[self.len..][0..bs.len], bs);
        self.len += bs.len;
    }
    fn u32le(self: *W, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }
    fn slice(self: *W) []u8 {
        return self.buf[0..self.len];
    }
};

// The number of bytes a PkgLength field takes for `content` content bytes. The
// field's value counts the field itself, so it is self-referential.
fn pkgLenSize(content: usize) usize {
    if (content + 1 <= 0x3F) return 1;
    if (content + 2 <= 0xFFF) return 2;
    if (content + 3 <= 0xFFFFF) return 3;
    return 4;
}

fn emitPkgLength(w: *W, content: usize) void {
    const sz = pkgLenSize(content);
    const val = content + sz;
    switch (sz) {
        1 => w.byte(@intCast(val)),
        2 => {
            w.byte(0x40 | @as(u8, @intCast(val & 0x0F)));
            w.byte(@intCast((val >> 4) & 0xFF));
        },
        3 => {
            w.byte(0x80 | @as(u8, @intCast(val & 0x0F)));
            w.byte(@intCast((val >> 4) & 0xFF));
            w.byte(@intCast((val >> 12) & 0xFF));
        },
        else => {
            w.byte(0xC0 | @as(u8, @intCast(val & 0x0F)));
            w.byte(@intCast((val >> 4) & 0xFF));
            w.byte(@intCast((val >> 12) & 0xFF));
            w.byte(@intCast((val >> 20) & 0xFF));
        },
    }
}

// An integer constant, encoded as iasl does: the smallest form that holds it.
fn emitInteger(w: *W, v: u64) void {
    if (v == 0) {
        w.byte(0x00);
    } else if (v == 1) {
        w.byte(0x01);
    } else if (v <= 0xFF) {
        w.byte(0x0A);
        w.byte(@intCast(v));
    } else if (v <= 0xFFFF) {
        w.byte(0x0B);
        w.byte(@intCast(v & 0xFF));
        w.byte(@intCast((v >> 8) & 0xFF));
    } else if (v <= 0xFFFFFFFF) {
        w.byte(0x0C);
        w.u32le(@intCast(v));
    } else {
        w.byte(0x0E);
        std.mem.writeInt(u64, w.buf[w.len..][0..8], v, .little);
        w.len += 8;
    }
}

fn emitString(w: *W, s: []const u8) void {
    w.byte(0x0D);
    w.bytes(s);
    w.byte(0x00);
}

// PackageOp, PkgLength, NumElements, then the pre-built element bytes.
fn emitPackage(w: *W, num_elements: u8, elements: []const u8) void {
    w.byte(0x12);
    emitPkgLength(w, 1 + elements.len);
    w.byte(num_elements);
    w.bytes(elements);
}

// A buffer object: BufferOp, PkgLength, buffer-size term, then the raw data.
fn emitBuffer(w: *W, data: []const u8) void {
    w.byte(0x11);
    // size term: a byte constant (all Weir buffers are small).
    emitPkgLength(w, 2 + data.len);
    w.byte(0x0A);
    w.byte(@intCast(data.len));
    w.bytes(data);
}

fn emitValue(w: *W, v: Value) void {
    switch (v) {
        .int => |n| emitInteger(w, n),
        .str => |s| emitString(w, s),
        .strs => |list| {
            var tmp: [512]u8 = undefined;
            var tw = W{ .buf = &tmp };
            for (list) |s| emitString(&tw, s);
            emitPackage(w, @intCast(list.len), tw.slice());
        },
    }
}

// Name (_CRS, ResourceTemplate () { Memory32Fixed...; Interrupt... }).
fn emitCrs(w: *W, mem: []const MemRegion, irqs: []const u32) void {
    var res_buf: [512]u8 = undefined;
    var rw = W{ .buf = &res_buf };
    for (mem) |m| {
        // Memory32Fixed (large item 0x86, 9 data bytes), writeable.
        rw.byte(0x86);
        rw.byte(0x09);
        rw.byte(0x00);
        rw.byte(0x01);
        rw.u32le(m.base);
        rw.u32le(m.size);
    }
    for (irqs) |irq| {
        // Extended interrupt (large item 0x89): consumer, level, active-high,
        // one interrupt.
        rw.byte(0x89);
        rw.byte(0x06);
        rw.byte(0x00);
        rw.byte(0x01);
        rw.byte(0x01);
        rw.u32le(irq);
    }
    // End tag (small item 0x0F), checksum 0 (not checked).
    rw.byte(0x79);
    rw.byte(0x00);
    const res = rw.slice();

    w.byte(0x08); // NameOp
    w.bytes("_CRS");
    emitBuffer(w, res);
}

// Name (_DSD, Package () { ToUUID(...), Package () { {key, value}... } }).
fn emitDsd(w: *W, props: []const Prop) void {
    // The inner package of property packages.
    var inner_buf: [2048]u8 = undefined;
    var iw = W{ .buf = &inner_buf };
    for (props) |p| {
        var pair_buf: [1024]u8 = undefined;
        var pw = W{ .buf = &pair_buf };
        emitString(&pw, p.key);
        emitValue(&pw, p.value);
        emitPackage(&iw, 2, pw.slice());
    }
    var inner_pkg_buf: [2048]u8 = undefined;
    var ipw = W{ .buf = &inner_pkg_buf };
    emitPackage(&ipw, @intCast(props.len), iw.slice());

    // The outer package: ToUUID buffer, then the inner package.
    var outer_buf: [2200]u8 = undefined;
    var ow = W{ .buf = &outer_buf };
    emitBuffer(&ow, &props_uuid);
    ow.bytes(ipw.slice());

    w.byte(0x08); // NameOp
    w.bytes("_DSD");
    emitPackage(w, 2, ow.slice());
}

// One PRP0001 Device object.
fn emitDevice(w: *W, dev: Device) void {
    var body_buf: [3072]u8 = undefined;
    var bw = W{ .buf = &body_buf };
    // _HID: "PRP0001" (the PnP-over-ACPI bridge; the driver matches on the _DSD
    // "compatible") or a native id for a controller the kernel binds directly.
    bw.byte(0x08);
    bw.bytes("_HID");
    emitString(&bw, dev.hid);
    // _UID.
    bw.byte(0x08);
    bw.bytes("_UID");
    emitInteger(&bw, dev.uid);
    // _STA: present, enabled, functioning (0x0F).
    bw.byte(0x08);
    bw.bytes("_STA");
    emitInteger(&bw, 0x0F);
    // _GSB: an interrupt controller's global system interrupt base.
    if (dev.gsb) |g| {
        bw.byte(0x08);
        bw.bytes("_GSB");
        emitInteger(&bw, g);
    }
    emitCrs(&bw, dev.mem, dev.irqs);
    if (dev.props.len > 0) emitDsd(&bw, dev.props);
    const body = bw.slice();

    w.byte(0x5B); // ExtOpPrefix
    w.byte(0x82); // DeviceOp
    emitPkgLength(w, dev.name.len + body.len);
    w.bytes(&dev.name);
    w.bytes(body);
}

// The scope body (all devices), built before the scope header can be written,
// since the scope PkgLength needs the total length. Module-level to keep it off
// the stack; ACPI setup is single-threaded.
var scope_scratch: [16384]u8 = undefined;

/// Build the DSDT AML body: a `Scope (\_SB)` holding one PRP0001 device per
/// entry. The result goes straight into a "DSDT" table body (the 36-byte header
/// is added by the table builder). Returns the used slice of `buf`.
pub fn buildScope(buf: []u8, devices: []const Device) []u8 {
    var inner = W{ .buf = &scope_scratch };
    for (devices) |d| emitDevice(&inner, d);
    const inner_slice = inner.slice();

    var w = W{ .buf = buf };
    w.byte(0x10); // ScopeOp
    emitPkgLength(&w, 4 + inner_slice.len); // "_SB_"(4) + inner
    w.bytes("_SB_");
    w.bytes(inner_slice);
    return w.slice();
}

test "buildScope matches iasl for a PRP0001 device with _CRS and _DSD" {
    // From iasl (ref3.asl): Scope(\_SB){ Device(D000){ _HID PRP0001, _UID 0,
    // _STA 0x0F, _CRS(Memory32Fixed(0x10000000,0x1000), Interrupt{10}),
    // _DSD{ compatible={"ns16550a"}, clock-frequency=0x016E3600 } } }.
    const expected = [_]u8{
        0x10, 0x4e, 0x09, 0x5f, 0x53, 0x42, 0x5f, 0x5b, 0x82, 0x46, 0x09, 0x44,
        0x30, 0x30, 0x30, 0x08, 0x5f, 0x48, 0x49, 0x44, 0x0d, 0x50, 0x52, 0x50,
        0x30, 0x30, 0x30, 0x31, 0x00, 0x08, 0x5f, 0x55, 0x49, 0x44, 0x00, 0x08,
        0x5f, 0x53, 0x54, 0x41, 0x0a, 0x0f, 0x08, 0x5f, 0x43, 0x52, 0x53, 0x11,
        0x1a, 0x0a, 0x17, 0x86, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x10, 0x00, 0x00, 0x89, 0x06, 0x00, 0x01, 0x01, 0x0a, 0x00, 0x00, 0x00,
        0x79, 0x00, 0x08, 0x5f, 0x44, 0x53, 0x44, 0x12, 0x4f, 0x04, 0x02, 0x11,
        0x13, 0x0a, 0x10, 0x14, 0xd8, 0xff, 0xda, 0xba, 0x6e, 0x8c, 0x4d, 0x8a,
        0x91, 0xbc, 0x9b, 0xbf, 0x4a, 0xa3, 0x01, 0x12, 0x37, 0x02, 0x12, 0x1b,
        0x02, 0x0d, 0x63, 0x6f, 0x6d, 0x70, 0x61, 0x74, 0x69, 0x62, 0x6c, 0x65,
        0x00, 0x12, 0x0c, 0x01, 0x0d, 0x6e, 0x73, 0x31, 0x36, 0x35, 0x35, 0x30,
        0x61, 0x00, 0x12, 0x18, 0x02, 0x0d, 0x63, 0x6c, 0x6f, 0x63, 0x6b, 0x2d,
        0x66, 0x72, 0x65, 0x71, 0x75, 0x65, 0x6e, 0x63, 0x79, 0x00, 0x0c, 0x00,
        0x36, 0x6e, 0x01,
    };
    const compat = [_][]const u8{"ns16550a"};
    var buf: [1024]u8 = undefined;
    const got = buildScope(&buf, &.{.{
        .name = .{ 'D', '0', '0', '0' },
        .uid = 0,
        .mem = &.{.{ .base = 0x10000000, .size = 0x1000 }},
        .irqs = &.{10},
        .props = &.{
            .{ .key = "compatible", .value = .{ .strs = &compat } },
            .{ .key = "clock-frequency", .value = .{ .int = 0x016E3600 } },
        },
    }});
    try std.testing.expectEqualSlices(u8, &expected, got);
}
