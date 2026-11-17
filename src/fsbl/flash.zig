//! Pull the main Weir image out of flash into DRAM.
//!
//! Header: 4-byte LE magic 'WEIR', 4-byte LE length, then raw firmware bytes
//! (built by `zig build fsbl`). XIP SPI flash makes this a plain copy. A
//! register-driven SPI controller would replace the reads here.

const std = @import("std");
const cfg = @import("config.zig");

const MAGIC: u32 = 0x52494557; // 'WEIR' little-endian

const word = @sizeOf(u64);

// The pointers are volatile so that each loop stays a loop of word moves. The
// compiler does not change it into a call to memcpy, which stores bytes.
fn copyWords(dst: [*]volatile u64, src: [*]const volatile u64, count: usize) void {
    for (0..count) |i| dst[i] = src[i];
}

fn sameWords(a: [*]const volatile u64, b: [*]const volatile u64, count: usize) bool {
    for (0..count) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

/// Copy one chunk and compare it with its source. Both addresses and the
/// length are multiples of 8 bytes.
fn copyChunk(dst: usize, src: usize, len: usize) bool {
    const count = len / word;
    copyWords(@ptrFromInt(dst), @ptrFromInt(src), count);
    return sameWords(@ptrFromInt(dst), @ptrFromInt(src), count);
}

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
    if ((src_base | cfg.dram_base) % word != 0) {
        con.writeAll("[fsbl] flash: image is not at a multiple of 8 bytes\n") catch {};
        return null;
    }
    // Round the copy up to a whole word so the verify pass covers the last word.
    const nbytes = (len + word - 1) & ~@as(usize, word - 1);

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
        // Copy the chunk, then compare it. Retry the whole chunk while it
        // differs, up to the budget, so a marginal DDR word gets rewritten.
        var tries: usize = 0;
        const good = while (tries <= 16) : (tries += 1) {
            if (copyChunk(cfg.dram_base + off, src_base + off, n)) break true;
        } else false;
        if (!good) bad += 1;
        off += n;
    }

    con.writeAll("[fsbl] flash: copied main image into DRAM, uncorrectable chunks=0x") catch {};
    con.print("{X:0>8}", .{bad}) catch {};
    con.writeByte('\n') catch {};
    return len;
}
