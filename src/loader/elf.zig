//! Minimal ELF64 loader for RISC-V S-mode payloads.
//!
//! Copies PT_LOAD segments to their physical addresses, zeroes any trailing
//! .bss, and returns the entry point. The caller enters it in S-mode.

pub const Error = error{
    Truncated,
    BadMagic,
    Unsupported,
};

const PT_LOAD = 1;

fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}

fn rd32(b: []const u8, o: usize) u32 {
    var v: u32 = 0;
    inline for (0..4) |i| v |= @as(u32, b[o + i]) << (8 * i);
    return v;
}

fn rd64(b: []const u8, o: usize) u64 {
    var v: u64 = 0;
    inline for (0..8) |i| v |= @as(u64, b[o + i]) << (8 * i);
    return v;
}

/// Load an ELF64 image into memory and return its entry point.
pub fn load(image: []const u8) Error!usize {
    if (image.len < 64) return error.Truncated;
    if (!(image[0] == 0x7f and image[1] == 'E' and image[2] == 'L' and image[3] == 'F')) {
        return error.BadMagic;
    }
    if (image[4] != 2 or image[5] != 1) return error.Unsupported; // 64-bit, little-endian

    const e_entry = rd64(image, 24);
    const e_phoff = rd64(image, 32);
    const e_phentsize = rd16(image, 54);
    const e_phnum = rd16(image, 56);

    var i: usize = 0;
    while (i < e_phnum) : (i += 1) {
        const ph = @as(usize, @intCast(e_phoff)) + i * e_phentsize;
        if (ph + 56 > image.len) return error.Truncated;
        if (rd32(image, ph) != PT_LOAD) continue;

        const p_offset: usize = @intCast(rd64(image, ph + 8));
        const p_paddr: usize = @intCast(rd64(image, ph + 24));
        const p_filesz: usize = @intCast(rd64(image, ph + 32));
        const p_memsz: usize = @intCast(rd64(image, ph + 40));
        if (p_offset + p_filesz > image.len) return error.Truncated;

        const dst: [*]u8 = @ptrFromInt(p_paddr);
        @memcpy(dst[0..p_filesz], image[p_offset .. p_offset + p_filesz]);
        if (p_memsz > p_filesz) @memset(dst[p_filesz..p_memsz], 0);
    }

    // The payload is freshly written code; make the I-fetch path see it.
    asm volatile ("fence.i" ::: .{ .memory = true });
    return @intCast(e_entry);
}
