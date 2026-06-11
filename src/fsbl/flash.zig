//! Pull the main Weir image out of flash into DRAM.
//!
//! Header: 4-byte LE magic 'WEIR', 4-byte LE length, then raw firmware bytes
//! (built by `zig build fsbl`). XIP SPI flash makes this a plain copy; a
//! register-driven SPI controller would replace the reads here.

const uart = @import("uart");
const cfg = @import("config.zig");

const MAGIC: u32 = 0x52494557; // 'WEIR' little-endian

fn rd32(addr: usize) u32 {
    const p: *const [4]u8 = @ptrFromInt(addr);
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

/// Copy the main firmware image from flash to DRAM. Returns the image length, or
/// null if the header is missing or the length is implausible.
pub fn loadMain(con: *uart.Ns16550a) ?usize {
    const hdr = cfg.flash_base + cfg.main_offset;
    if (rd32(hdr) != MAGIC) {
        con.writeStr("[fsbl] flash: no WEIR image header at expected offset\n");
        return null;
    }
    const len = rd32(hdr + 4);
    if (len == 0 or len > cfg.main_max) {
        con.writeStr("[fsbl] flash: image length out of range\n");
        return null;
    }
    const src: [*]const u8 = @ptrFromInt(hdr + 8);
    const dst: [*]u8 = @ptrFromInt(cfg.dram_base);
    @memcpy(dst[0..len], src[0..len]);
    con.writeStr("[fsbl] flash: copied main image into DRAM\n");
    return len;
}
