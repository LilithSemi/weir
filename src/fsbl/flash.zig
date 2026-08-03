//! Pull the main Weir image out of flash into DRAM.
//!
//! Header: 4-byte LE magic 'WEIR', 4-byte LE length, then raw firmware bytes
//! (built by `zig build fsbl`). XIP SPI flash makes this a plain copy; a
//! register-driven SPI controller would replace the reads here.

const uart = @import("uart");
const cfg = @import("config.zig");

const MAGIC: u32 = 0x52494557; // 'WEIR' little-endian

fn rd32(addr: usize) u32 {
    const p: *const volatile [4]u8 = @ptrFromInt(addr);
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

fn wr32(addr: usize, v: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = v;
}

fn hex32(con: *uart.Ns16550a, v: u32) void {
    const digits = "0123456789ABCDEF";
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        con.putc(digits[@intCast((v >> @intCast(i * 4)) & 0xF)]);
    }
}

/// Copy the main firmware image from flash to DRAM, word by word, verifying each
/// store with a read-back and retrying on mismatch. The DLL-off static DDR write
/// path has a small metastable per-word margin, and one bad instruction word
/// makes main fault silently. The read path is solid, so a retry until the
/// read-back matches lands every word. Reports the uncorrectable count (words
/// still wrong after the retry budget, i.e. a hard fault, not metastability).
/// Returns the image length, or null if the header is missing or implausible.
pub fn loadMain(con: *uart.Ns16550a) ?usize {
    const hdr = cfg.flash_base + cfg.mainOffset();
    if (rd32(hdr) != MAGIC) {
        con.writeStr("[fsbl] flash: no WEIR image header at expected offset\n");
        return null;
    }
    const len = rd32(hdr + 4);
    if (len == 0 or len > cfg.mainMax()) {
        con.writeStr("[fsbl] flash: image length out of range\n");
        return null;
    }
    const src_base = hdr + 8;
    const nwords = (len + 3) / 4;
    var bad: u32 = 0;
    var i: usize = 0;
    while (i < nwords) : (i += 1) {
        const s = rd32(src_base + i * 4);
        const daddr = cfg.dram_base + i * 4;
        var tries: usize = 0;
        while (tries < 16) : (tries += 1) {
            wr32(daddr, s);
            if (rd32(daddr) == s) break;
        }
        if (rd32(daddr) != s) bad += 1;
    }
    con.writeStr("[fsbl] flash: copied main image into DRAM, uncorrectable=0x");
    hex32(con, bad);
    con.putc('\n');
    return len;
}
