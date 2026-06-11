//! Flattened Device Tree (DTB) reader. Big-endian on the wire.
//!
//! Enough to validate the header the platform hands us and surface the root
//! `model`/`compatible` so we can confirm we are consuming the right DT.

const console = @import("../console/console.zig");

const FDT_MAGIC: u32 = 0xd00dfeed;

const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

const Header = struct {
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    version: u32,
    boot_cpuid_phys: u32,
};

fn be32(p: [*]const u8, off: usize) u32 {
    return (@as(u32, p[off]) << 24) |
        (@as(u32, p[off + 1]) << 16) |
        (@as(u32, p[off + 2]) << 8) |
        @as(u32, p[off + 3]);
}

// Read a NUL-terminated string at `off`, never scanning past `end` (totalsize),
// so an unterminated string yields truncation instead of running off into
// unmapped memory.
fn cstr(p: [*]const u8, off: usize, end: usize) []const u8 {
    var len: usize = 0;
    while (off + len < end and p[off + len] != 0) : (len += 1) {}
    return p[off .. off + len];
}

fn parseHeader(p: [*]const u8) ?Header {
    if (be32(p, 0) != FDT_MAGIC) return null;
    const h = Header{
        .totalsize = be32(p, 4),
        .off_dt_struct = be32(p, 8),
        .off_dt_strings = be32(p, 12),
        .version = be32(p, 20),
        .boot_cpuid_phys = be32(p, 28),
    };
    // Reject a truncated/garbage header: walkers bound on these fields, so an
    // off_dt_struct past totalsize would underflow the loop bound and an
    // out-of-range off_dt_strings would let cstr read outside the blob.
    if (h.totalsize < 64 or h.off_dt_struct >= h.totalsize or h.off_dt_strings > h.totalsize) return null;
    return h;
}

/// Total size in bytes of a valid DTB at `addr`, or null if the header is absent
/// or malformed. Lets callers copy/relocate a tree without redoing the checks.
pub fn totalSize(addr: usize) ?usize {
    if (addr == 0) return null;
    const hdr = parseHeader(@ptrFromInt(addr)) orelse return null;
    return hdr.totalsize;
}

/// Validate and print a short summary of the DTB at `addr`.
pub fn inspect(addr: usize) void {
    if (addr == 0) {
        console.writeStr("[fdt] no device tree provided\n");
        return;
    }
    const p: [*]const u8 = @ptrFromInt(addr);
    const hdr = parseHeader(p) orelse {
        console.printf("[fdt] bad magic at {x} (got {x})\n", .{ addr, be32(p, 0) });
        return;
    };

    console.printf(
        "[fdt] valid @ {x}: v{d}, {d} bytes, boot hart {d}\n",
        .{ addr, hdr.version, hdr.totalsize, hdr.boot_cpuid_phys },
    );

    walkRoot(p, hdr);
}

fn walkRoot(p: [*]const u8, hdr: Header) void {
    var off = hdr.off_dt_struct;
    const end = hdr.totalsize;
    var depth: i32 = 0;
    var nodes: usize = 0;

    while (off + 4 <= end) {
        const token = be32(p, off);
        off += 4;
        switch (token) {
            FDT_BEGIN_NODE => {
                depth += 1;
                nodes += 1;
                const name = cstr(p, off, end);
                off += @intCast(name.len + 1);
                off = align4(off);
            },
            FDT_END_NODE => {
                depth -= 1;
                if (depth <= 0) break;
            },
            FDT_PROP => {
                const len = be32(p, off);
                const nameoff = be32(p, off + 4);
                off += 8;
                const data_off = off;
                off = align4(off + len);
                // Report a couple of useful root-level properties.
                if (depth == 1 and data_off + len <= end) {
                    const pname = cstr(p, hdr.off_dt_strings + nameoff, end);
                    if (eql(pname, "model") or eql(pname, "compatible")) {
                        console.printf("[fdt]   /{s} = {s}\n", .{ pname, cstr(p, data_off, end) });
                    }
                }
            },
            FDT_NOP => {},
            FDT_END => break,
            else => break,
        }
    }

    console.printf("[fdt] walked {d} nodes\n", .{nodes});
}

fn be64(p: [*]const u8, off: usize) u64 {
    return (@as(u64, be32(p, off)) << 32) | @as(u64, be32(p, off + 4));
}

fn nameEql(name: []const u8, want: []const u8) bool {
    // Match "memory" and "memory@80000000" alike.
    if (name.len < want.len) return false;
    for (want, 0..) |c, i| if (name[i] != c) return false;
    return name.len == want.len or name[want.len] == '@';
}

/// End address (base + size) of the first `/memory` node, so the EFI memory map
/// follows whatever RAM QEMU was given (`-m`) instead of a hardcoded cap.
/// Assumes #address-cells = #size-cells = 2 (holds on virt). Null if not found.
pub fn ramEnd(addr: usize) ?usize {
    if (addr == 0) return null;
    const p: [*]const u8 = @ptrFromInt(addr);
    const hdr = parseHeader(p) orelse return null;

    var off = hdr.off_dt_struct;
    const end = hdr.totalsize;
    var in_memory = false;
    while (off + 4 <= end) {
        const token = be32(p, off);
        off += 4;
        switch (token) {
            FDT_BEGIN_NODE => {
                const name = cstr(p, off, end);
                off += @intCast(name.len + 1);
                off = align4(off);
                in_memory = nameEql(name, "memory");
            },
            FDT_END_NODE => in_memory = false,
            FDT_PROP => {
                const len = be32(p, off);
                const nameoff = be32(p, off + 4);
                off += 8;
                const data_off = off;
                off = align4(off + len);
                if (in_memory and len >= 16 and data_off + 16 <= end) {
                    const pname = cstr(p, hdr.off_dt_strings + nameoff, end);
                    if (eql(pname, "reg")) {
                        const base = be64(p, data_off);
                        const size = be64(p, data_off + 8);
                        return @intCast(base + size);
                    }
                }
            },
            FDT_NOP => {},
            FDT_END => break,
            else => break,
        }
    }
    return null;
}

fn compatibleMatches(p: [*]const u8, data_off: usize, len: u32, end: usize, wants: []const []const u8) bool {
    // `compatible` is a list of NUL-terminated strings packed into `len` bytes.
    var i: usize = 0;
    while (i < len and data_off + i < end) {
        const s = cstr(p, data_off + i, end);
        for (wants) |w| if (eql(s, w)) return true;
        i += s.len + 1;
    }
    return false;
}

/// Find the first node whose `compatible` matches any of `wants` and return the
/// base address from its `reg`. Locates a peripheral by what it IS rather than a
/// hardcoded address, so one binary works across SoC layouts. Assumes
/// #address-cells = 2 (true on QEMU virt and Harbor riscv64 SoCs). Null if not
/// found.
pub fn findCompatibleReg(addr: usize, wants: []const []const u8) ?u64 {
    if (addr == 0) return null;
    const p: [*]const u8 = @ptrFromInt(addr);
    const hdr = parseHeader(p) orelse return null;

    var off = hdr.off_dt_struct;
    const end = hdr.totalsize;
    // Direct properties of a node precede its children, so we accumulate the
    // current node's match/reg and resolve it when the node's props are done.
    var match = false;
    var reg: ?u64 = null;
    while (off + 4 <= end) {
        const token = be32(p, off);
        off += 4;
        switch (token) {
            FDT_BEGIN_NODE, FDT_END_NODE => {
                if (match) if (reg) |r| return r;
                match = false;
                reg = null;
                if (token == FDT_BEGIN_NODE) {
                    const name = cstr(p, off, end);
                    off += @intCast(name.len + 1);
                    off = align4(off);
                }
            },
            FDT_PROP => {
                const len = be32(p, off);
                const nameoff = be32(p, off + 4);
                off += 8;
                const data_off = off;
                off = align4(off + len);
                if (data_off + len > end) continue;
                const pname = cstr(p, hdr.off_dt_strings + nameoff, end);
                if (eql(pname, "compatible")) {
                    if (compatibleMatches(p, data_off, len, end, wants)) match = true;
                } else if (eql(pname, "reg") and len >= 8) {
                    reg = be64(p, data_off);
                }
            },
            FDT_NOP => {},
            FDT_END => break,
            else => break,
        }
    }
    return null;
}

/// Like findCompatibleReg, but returns a named u32 (big-endian cell) property of
/// the matching node, e.g. "clock-frequency". Returns null if not found.
pub fn findCompatibleProp(addr: usize, wants: []const []const u8, prop: []const u8) ?u32 {
    if (addr == 0) return null;
    const p: [*]const u8 = @ptrFromInt(addr);
    const hdr = parseHeader(p) orelse return null;

    var off = hdr.off_dt_struct;
    const end = hdr.totalsize;
    var match = false;
    var value: ?u32 = null;
    while (off + 4 <= end) {
        const token = be32(p, off);
        off += 4;
        switch (token) {
            FDT_BEGIN_NODE, FDT_END_NODE => {
                if (match) if (value) |v| return v;
                match = false;
                value = null;
                if (token == FDT_BEGIN_NODE) {
                    const name = cstr(p, off, end);
                    off += @intCast(name.len + 1);
                    off = align4(off);
                }
            },
            FDT_PROP => {
                const len = be32(p, off);
                const nameoff = be32(p, off + 4);
                off += 8;
                const data_off = off;
                off = align4(off + len);
                if (data_off + len > end) continue;
                const pname = cstr(p, hdr.off_dt_strings + nameoff, end);
                if (eql(pname, "compatible")) {
                    if (compatibleMatches(p, data_off, len, end, wants)) match = true;
                } else if (eql(pname, prop) and len >= 4) {
                    value = be32(p, data_off);
                }
            },
            FDT_NOP => {},
            FDT_END => break,
            else => break,
        }
    }
    return null;
}

fn align4(v: u32) u32 {
    return (v + 3) & ~@as(u32, 3);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
