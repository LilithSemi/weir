//! Load QEMU's generated ACPI tables through fw_cfg and link them in memory.
//!
//! QEMU hands firmware three fw_cfg files: etc/acpi/tables (concatenated SDTs),
//! etc/acpi/rsdp (the Root System Description Pointer), and etc/table-loader (a
//! command script). The script tells Weir to allocate each blob, patch the
//! cross-table pointers to the chosen addresses, and recompute the checksums.
//! The result is a self-consistent RSDP to publish to the OS. This mirrors
//! EDK2/OVMF.

const std = @import("std");
const almanac = @import("conduit").almanac;
const fwcfg = @import("../fwcfg/fwcfg.zig");
const console = @import("../console/console.zig");
const mem = @import("../mem.zig");
const platform = @import("../platform.zig");

// Marked EfiACPIReclaimMemory in the EFI map so the OS maps then reclaims the
// tables. Sits below the page pool (see mem.zig), clear of the loaded PE.
pub const POOL_BASE: usize = mem.acpi_pool_base;
pub const POOL_SIZE: usize = mem.acpi_pool_size; // far more than the tables need

var pool_next: usize = POOL_BASE;
var rsdp_addr: usize = 0;

const Blob = struct {
    name: [56]u8 = [_]u8{0} ** 56,
    name_len: usize = 0,
    buf: []u8 = &.{},
};

var blobs: [16]Blob = undefined;
var blob_count: usize = 0;

fn poolAlloc(size: usize, alignment: usize) ?[]u8 {
    const a = if (alignment < 1) 1 else alignment;
    const start = (pool_next + a - 1) & ~(a - 1);
    if (start + size > POOL_BASE + POOL_SIZE) return null;
    pool_next = start + size;
    const p: [*]u8 = @ptrFromInt(start);
    return p[0..size];
}

fn blobByName(name: []const u8) ?*Blob {
    for (blobs[0..blob_count]) |*b| {
        if (std.mem.eql(u8, b.name[0..b.name_len], name)) return b;
    }
    return null;
}

fn nameLen(field: []const u8) usize {
    return std.mem.indexOfScalar(u8, field, 0) orelse field.len;
}

// table-loader command opcodes.
const CMD_ALLOCATE: u32 = 1;
const CMD_ADD_POINTER: u32 = 2;
const CMD_ADD_CHECKSUM: u32 = 3;
// Opcode 4 is WRITE_POINTER. It asks the host to write a blob address back into
// a fw_cfg file. Weir does not need it, so the loop below skips it (else prong).
const CMD_WRITE_POINTER: u32 = 4; // zippy:ignore unused_decl -- documents the loader opcode set

const ENTRY_SIZE = 128;

/// Pull QEMU's ACPI tables and link them. Returns the RSDP physical address, or
/// null if fw_cfg or the ACPI files are absent (e.g. QEMU started without ACPI).
pub fn loadTables() ?usize {
    if (rsdp_addr != 0) return rsdp_addr; // idempotent
    fwcfg.setBase(platform.fwcfgBase()); // 0 on a real River SoC: present()==false
    if (!fwcfg.present()) return null;

    const loader_file = fwcfg.find("etc/table-loader") orelse return null;
    // Fail early if either ACPI blob is missing. table-loader names them again.
    _ = fwcfg.find("etc/acpi/tables") orelse return null; // zippy:ignore discarded_error
    _ = fwcfg.find("etc/acpi/rsdp") orelse return null; // zippy:ignore discarded_error

    // The loader script itself lives in a scratch buffer, not the ACPI pool.
    var loader_buf: [8192]u8 = undefined;
    if (loader_file.size > loader_buf.len) {
        console.err.writeAll("[acpi] table-loader too large\n") catch {};
        return null;
    }
    fwcfg.read(loader_file, &loader_buf);

    pool_next = POOL_BASE;
    blob_count = 0;

    var off: usize = 0;
    while (off + ENTRY_SIZE <= loader_file.size) : (off += ENTRY_SIZE) {
        const e = loader_buf[off..][0..ENTRY_SIZE];
        const cmd = std.mem.readInt(u32, e[0..4], .little);
        switch (cmd) {
            CMD_ALLOCATE => if (!doAllocate(e)) return null,
            CMD_ADD_POINTER => doAddPointer(e),
            CMD_ADD_CHECKSUM => doAddChecksum(e),
            else => {}, // WRITE_POINTER is host-notify, others are zero padding
        }
    }

    const rsdp_blob = blobByName("etc/acpi/rsdp") orelse return null;
    rsdp_addr = @intFromPtr(rsdp_blob.buf.ptr);
    console.out.print(
        "[acpi] fw_cfg tables linked: RSDP @ {x}, {d} blobs, {d} bytes used\n",
        .{ rsdp_addr, blob_count, pool_next - POOL_BASE },
    ) catch {};
    return rsdp_addr;
}

fn doAllocate(e: []const u8) bool {
    // struct { char file[56]; u32 alignment; u8 zone; }
    const name = e[4..60];
    const alignment = std.mem.readInt(u32, e[60..64], .little);
    const len = nameLen(name);

    const file = fwcfg.find(name[0..len]) orelse {
        console.out.print("[acpi] ALLOCATE: missing file '{s}'\n", .{name[0..len]}) catch {};
        return false;
    };
    const buf = poolAlloc(file.size, alignment) orelse {
        console.err.writeAll("[acpi] ACPI pool exhausted\n") catch {};
        return false;
    };
    fwcfg.read(file, buf);

    if (blob_count >= blobs.len) return false;
    var b = &blobs[blob_count];
    @memcpy(b.name[0..len], name[0..len]);
    b.name_len = len;
    b.buf = buf;
    blob_count += 1;
    return true;
}

fn doAddPointer(e: []const u8) void {
    // struct { char dest_file[56]; char src_file[56]; u32 offset; u8 size; }
    const dest_name = e[4..60];
    const src_name = e[60..116];
    const ptr_off = std.mem.readInt(u32, e[116..120], .little);
    const size = e[120];

    const dest = blobByName(dest_name[0..nameLen(dest_name)]) orelse return;
    const src = blobByName(src_name[0..nameLen(src_name)]) orelse return;

    // The offset and size come from the loader script. Clamp them to the
    // destination blob so a malformed command cannot write past it into the ACPI
    // pool.
    if (size > 8 or @as(usize, ptr_off) + size > dest.buf.len) {
        console.err.writeAll("[acpi] ADD_POINTER out of range\n") catch {};
        return;
    }

    // Read the current relative value, add the src blob's base, write it back.
    var val: u64 = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) val |= @as(u64, dest.buf[ptr_off + i]) << @intCast(8 * i);
    val += @intFromPtr(src.buf.ptr);
    i = 0;
    while (i < size) : (i += 1) dest.buf[ptr_off + i] = @truncate(val >> @intCast(8 * i));
}

fn doAddChecksum(e: []const u8) void {
    // struct { char file[56]; u32 offset; u32 start; u32 length; }
    const name = e[4..60];
    const csum_off = std.mem.readInt(u32, e[60..64], .little);
    const start = std.mem.readInt(u32, e[64..68], .little);
    const length = std.mem.readInt(u32, e[68..72], .little);

    const b = blobByName(name[0..nameLen(name)]) orelse return;
    // Offsets are from the loader script: keep the checksum slot and the summed
    // range inside the blob.
    if (csum_off >= b.buf.len or start > b.buf.len or length > b.buf.len - start) {
        console.err.writeAll("[acpi] ADD_CHECKSUM out of range\n") catch {};
        return;
    }
    b.buf[csum_off] = 0;
    b.buf[csum_off] = almanac.checksum.compute(b.buf[start .. start + length]);
}

/// The linked RSDP address, or 0 if tables were never loaded.
pub fn rsdp() usize {
    return rsdp_addr;
}

/// Register an RSDP built elsewhere (acpi.zig's own tables on a real SoC), so the
/// one RSDP accessor and the UEFI config-table publish path cover both sources.
pub fn setRsdp(addr: usize) void {
    rsdp_addr = addr;
}

/// Recompute an in-place ACPI checksum: zero the slot, then stamp the byte that
/// makes the whole buffer sum to zero. The Builder does this for tables it lays
/// down. Use this to patch tables already in memory.
fn writeChecksum(buf: []u8, csum_index: usize) void {
    buf[csum_index] = 0;
    buf[csum_index] = almanac.checksum.compute(buf);
}

const OEM_ID = "LILSMI";

/// QEMU's RISC-V virt ACPI emits no TPM2 table. When a TPM is present, Weir
/// synthesizes one (plus the event-log area it points at), appends it to a
/// rebuilt XSDT, and re-points the RSDP. Returns the log area for the event log.
pub fn injectTpm2(tis_base: u64) ?struct { addr: usize, len: usize } {
    if (rsdp_addr == 0) return null;
    const rsdp_blob = blobByName("etc/acpi/rsdp") orelse return null;
    const rsdp_buf = rsdp_blob.buf;

    // Event log area (in the ACPI-reclaim pool, so the OS maps it).
    const LOG_LEN: usize = 65536;
    const log = poolAlloc(LOG_LEN, 4096) orelse return null;
    @memset(log, 0);

    // Build the TPM2 table (TCG ACPI, memory-mapped TIS, with a log area).
    // phys == virt here, so base_phys is just the slice addr.
    _ = tis_base; // the DSDT device _CRS (River's AML) carries the TIS base
    const t = poolAlloc(64, 8) orelse return null;
    var tb = almanac.Builder.init(t, @intFromPtr(t.ptr));
    tb.oem_id = OEM_ID.*;
    tb.oem_table_id = "WEIR    ".*;
    tb.creator_id = "WEIR".*;
    const tpm2_phys = tb.tpm2(.{
        .platform_class = 0, // client
        .control_address = 0, // CRB control area unused for TIS
        .start_method = 6, // memory-mapped I/O (TIS)
        .log_area_length = @intCast(LOG_LEN),
        .log_area_start = @intFromPtr(log.ptr),
    }) catch return null;

    // Rebuild the XSDT with one extra entry for the new TPM2 table. Keep the
    // original OEM identity. The RSDP's XSDT pointer lives inside the
    // etc/acpi/tables blob. Validate that it points there and its declared length
    // fits, so the entry-copy loop cannot read past the blob on a garbage header.
    const tables_blob = blobByName("etc/acpi/tables") orelse return null;
    const tbl_start = @intFromPtr(tables_blob.buf.ptr);
    const tbl_end = tbl_start + tables_blob.buf.len;
    const old_xsdt: usize = @intCast(std.mem.readInt(u64, rsdp_buf[24..32], .little));
    if (old_xsdt < tbl_start or old_xsdt + 8 > tbl_end) return null;
    const old_ptr: [*]u8 = @ptrFromInt(old_xsdt);
    const old_len = std.mem.readInt(u32, old_ptr[4..8], .little);
    if (old_len < 36 or old_xsdt + old_len > tbl_end) return null;
    const old_count = (old_len - 36) / 8;
    var entries: [32]u64 = undefined;
    if (old_count + 1 > entries.len) return null;
    var i: usize = 0;
    while (i < old_count) : (i += 1) {
        entries[i] = std.mem.readInt(u64, old_ptr[36 + i * 8 ..][0..8], .little);
    }
    entries[old_count] = tpm2_phys;

    const x = poolAlloc(36 + (old_count + 1) * 8, 8) orelse return null;
    var xb = almanac.Builder.init(x, @intFromPtr(x.ptr));
    @memcpy(&xb.oem_id, old_ptr[10..16]);
    @memcpy(&xb.oem_table_id, old_ptr[16..24]);
    xb.oem_revision = std.mem.readInt(u32, old_ptr[24..28], .little);
    @memcpy(&xb.creator_id, old_ptr[28..32]);
    xb.creator_revision = std.mem.readInt(u32, old_ptr[32..36], .little);
    const xsdt_phys = xb.xsdt(entries[0 .. old_count + 1]) catch return null;

    // Re-point the RSDP at the new XSDT and refresh both its checksums.
    std.mem.writeInt(u64, rsdp_buf[24..32], xsdt_phys, .little);
    writeChecksum(rsdp_buf[0..20], 8); // ACPI 1.0 checksum
    writeChecksum(rsdp_buf[0..36], 32); // extended checksum

    console.out.print(
        "[acpi] injected TPM2 table, event log @ {x} ({d} bytes)\n",
        .{ @intFromPtr(log.ptr), LOG_LEN },
    ) catch {};
    return .{ .addr = @intFromPtr(log.ptr), .len = LOG_LEN };
}

/// Locate the event-log area QEMU's TPM2 table designates (its LASA/LAML, patched
/// to point at an allocated log blob), so Weir can write its event log there and
/// the OS finds it through that table. Returns null if there is no TPM2 table.
pub fn tpm2LogArea() ?struct { addr: usize, len: usize } {
    const tbl = blobByName("etc/acpi/tables") orelse return null;
    const buf = tbl.buf;
    var i: usize = 0;
    while (i + 8 <= buf.len) : (i += 1) {
        if (almanac.signature.matches(buf[i..][0..4], "TPM2")) {
            const len = std.mem.readInt(u32, buf[i + 4 ..][0..4], .little);
            // Log-bearing TPM2 tables carry LAML(u32) then LASA(u64) at the end.
            if (len >= 64 and i + len <= buf.len) {
                const laml = std.mem.readInt(u32, buf[i + len - 12 ..][0..4], .little);
                const lasa = std.mem.readInt(u64, buf[i + len - 8 ..][0..8], .little);
                if (lasa != 0 and laml >= 512) return .{ .addr = @intCast(lasa), .len = laml };
            }
        }
    }
    return null;
}
