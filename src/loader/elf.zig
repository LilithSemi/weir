//! Minimal ELF64 loader for RISC-V S-mode payloads.
//!
//! Copies PT_LOAD segments to their physical addresses, zeroes any trailing
//! .bss, and returns the entry point. The caller enters it in S-mode.

const std = @import("std");

pub const Error = error{
    Truncated,
    BadMagic,
    Unsupported,
};

const PT_LOAD = 1;

/// Load an ELF64 image into memory and return its entry point.
pub fn load(image: []const u8) Error!usize {
    if (image.len < 64) return error.Truncated;
    if (!(image[0] == 0x7f and image[1] == 'E' and image[2] == 'L' and image[3] == 'F')) {
        return error.BadMagic;
    }
    if (image[4] != 2 or image[5] != 1) return error.Unsupported; // 64-bit, little-endian

    const e_entry = std.mem.readInt(u64, image[24..][0..8], .little);
    const e_phoff = std.mem.readInt(u64, image[32..][0..8], .little);
    const e_phentsize = std.mem.readInt(u16, image[54..][0..2], .little);
    const e_phnum = std.mem.readInt(u16, image[56..][0..2], .little);

    var i: usize = 0;
    while (i < e_phnum) : (i += 1) {
        const ph = @as(usize, @intCast(e_phoff)) + i * e_phentsize;
        if (ph + 56 > image.len) return error.Truncated;
        if (std.mem.readInt(u32, image[ph..][0..4], .little) != PT_LOAD) continue;

        const p_offset: usize = @intCast(std.mem.readInt(u64, image[ph + 8 ..][0..8], .little));
        const p_paddr: usize = @intCast(std.mem.readInt(u64, image[ph + 24 ..][0..8], .little));
        const p_filesz: usize = @intCast(std.mem.readInt(u64, image[ph + 32 ..][0..8], .little));
        const p_memsz: usize = @intCast(std.mem.readInt(u64, image[ph + 40 ..][0..8], .little));
        if (p_offset + p_filesz > image.len) return error.Truncated;

        const dst: [*]u8 = @ptrFromInt(p_paddr);
        @memcpy(dst[0..p_filesz], image[p_offset .. p_offset + p_filesz]);
        if (p_memsz > p_filesz) @memset(dst[p_filesz..p_memsz], 0);
    }

    // The payload is freshly written code. Make the I-fetch path see it.
    asm volatile ("fence.i" ::: .{ .memory = true });
    return @intCast(e_entry);
}
