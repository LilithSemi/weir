//! Pull the main Weir image out of flash into DRAM.
//!
//! Header: 4-byte LE magic 'WEIR', 4-byte LE length, then raw firmware bytes
//! (built by `zig build fsbl`). XIP SPI flash makes this a plain copy. A
//! register-driven SPI controller would replace the reads here.

const std = @import("std");
const cfg = @import("config.zig");

const MAGIC: u32 = 0x52494557; // 'WEIR' little-endian

/// Copy the main firmware image from flash to DRAM and return its length, or
/// null if the header is bad. The marginal DLL-off DDR write path can drop a
/// word, so each chunk is block-copied then re-copied until it compares equal.
pub fn loadMain(con: *std.Io.Writer) ?usize {
    const hdr = cfg.flash_base + cfg.mainOffset();
    if (@as(*const volatile u32, @ptrFromInt(hdr)).* != MAGIC) {
        con.writeAll("[fsbl] flash: no WEIR image header at expected offset\n") catch {};
        return null;
    }
    const len = @as(*const volatile u32, @ptrFromInt(hdr + 4)).*;
    if (len == 0 or len > cfg.mainMax()) {
        con.writeAll("[fsbl] flash: image length out of range\n") catch {};
        return null;
    }
    const src_base = hdr + 8;
    // Round the copy up to a whole word so the verify pass covers the last word.
    const nbytes = (len + 3) & ~@as(usize, 3);
    const src = @as([*]const u8, @ptrFromInt(src_base));
    const dst = @as([*]u8, @ptrFromInt(cfg.dram_base));

    con.writeAll("[fsbl] flash: copy start len=0x") catch {};
    con.print("{X}", .{len}) catch {};
    con.writeByte('\n') catch {};

    const CHUNK = 0x10000; // 64 KiB per block copy
    var bad: u32 = 0;
    var off: usize = 0;
    while (off < nbytes) {
        // DIAG: a progress marker per chunk localises a copy hang.
        con.writeAll("[fsbl] flash: at 0x") catch {};
        con.print("{X}", .{off}) catch {};
        con.writeByte('\n') catch {};

        const n = @min(@as(usize, CHUNK), nbytes - off);
        const d = dst[off .. off + n];
        const s = src[off .. off + n];
        // Block copy the chunk, then compare it. Retry the whole chunk while it
        // differs, up to the budget, so a marginal DDR word gets rewritten.
        @memcpy(d, s);
        var tries: usize = 0;
        while (!std.mem.eql(u8, d, s) and tries < 16) : (tries += 1) @memcpy(d, s);
        if (!std.mem.eql(u8, d, s)) bad += 1;
        off += n;
    }

    con.writeAll("[fsbl] flash: copied main image into DRAM, uncorrectable chunks=0x") catch {};
    con.print("{X:0>8}", .{bad}) catch {};
    con.writeByte('\n') catch {};
    return len;
}
