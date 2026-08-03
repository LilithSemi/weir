//! QEMU fw_cfg over MMIO. Used to pull QEMU's generated ACPI tables
//! (etc/acpi/tables, etc/acpi/rsdp, etc/table-loader), as EDK2/OVMF does, and
//! republish them to the OS. Only the byte-stream (non-DMA) read path is
//! implemented; the ACPI blobs are small, so throughput does not matter.

const std = @import("std");

// QEMU virt places the fw-cfg-mmio device here (DTB node fw-cfg@10100000,
// reg = <0x10100000 0x18>, compatible "qemu,fw-cfg-mmio"). The base is set from
// the DTB at discovery; 0 means no fw-cfg device exists on this platform (e.g.
// a real River SoC). Probing a hardcoded address blind faults on a bus with no
// device mapped there, so every entry point guards on base != 0.
var base_v: usize = 0;
const REG_DATA: usize = 0x00; // selected item streams out a byte at a time
const REG_SELECTOR: usize = 0x08; // 16-bit, big-endian

const SELECTOR_SIGNATURE: u16 = 0x0000; // reads "QEMU"
const SELECTOR_FILE_DIR: u16 = 0x0019;

/// Set the MMIO base from the platform's DTB discovery. Pass 0 to mark fw-cfg
/// absent (the default), which makes present() report false without any access.
pub fn setBase(base: usize) void {
    base_v = base;
}

fn selectorReg() *volatile u16 {
    return @ptrFromInt(base_v + REG_SELECTOR);
}

fn dataReg() *volatile u8 {
    return @ptrFromInt(base_v + REG_DATA);
}

/// Select an item; this also resets its read offset to zero.
fn select(key: u16) void {
    selectorReg().* = @byteSwap(key); // the selector register is big-endian
}

fn readBytes(buf: []u8) void {
    const d = dataReg();
    for (buf) |*b| b.* = d.*;
}

fn readBe32() u32 {
    var b: [4]u8 = undefined;
    readBytes(&b);
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn readBe16() u16 {
    var b: [2]u8 = undefined;
    readBytes(&b);
    return (@as(u16, b[0]) << 8) | b[1];
}

pub const File = struct { selector: u16, size: u32 };

/// Is a fw_cfg device present? Confirms by reading the "QEMU" signature, which
/// also validates our selector-register endianness.
pub fn present() bool {
    if (base_v == 0) return false; // no fw-cfg on this platform: do not poke MMIO
    select(SELECTOR_SIGNATURE);
    var sig: [4]u8 = undefined;
    readBytes(&sig);
    return std.mem.eql(u8, &sig, "QEMU");
}

/// Look a file up in the fw_cfg directory by name.
pub fn find(name: []const u8) ?File {
    select(SELECTOR_FILE_DIR);
    const count = readBe32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const size = readBe32();
        const sel = readBe16();
        _ = readBe16(); // reserved
        var namebuf: [56]u8 = undefined;
        readBytes(&namebuf);
        const n = std.mem.indexOfScalar(u8, &namebuf, 0) orelse namebuf.len;
        if (std.mem.eql(u8, namebuf[0..n], name)) return .{ .selector = sel, .size = size };
    }
    return null;
}

/// Read a file's full contents into `buf` (must be at least `file.size`).
pub fn read(file: File, buf: []u8) void {
    select(file.selector);
    readBytes(buf[0..file.size]);
}
