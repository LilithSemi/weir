//! Minimal PE32+ (COFF) loader for RISC-V UEFI applications.
//!
//! Zig 0.16 cannot emit riscv64 PE, but it can read one: std.coff parses the
//! headers and section table of a real EFI binary (e.g. Limine's
//! BOOTRISCV64.EFI). We map the headers and sections to a fixed load base, apply
//! base relocations, fence the I-cache, and return the entry point. The caller
//! enters it in S-mode under a UEFI System Table, exactly like an EFI loader.

const std = @import("std");
const coff = std.coff;
const mem = @import("../mem.zig");

pub const Error = error{
    BadPe,
    NotImage,
    NotPe32Plus,
    NotRiscv64,
};

/// A loaded PE image: where it landed and how big its in-memory footprint is.
pub const Loaded = struct {
    entry: usize,
    base: usize,
    size: usize,
};

/// Fixed load base for EFI images: 32 MiB above ram_base, well clear of the
/// firmware (which carries the embedded image in rodata) and the per-hart
/// stacks. See mem.zig.
pub const LOAD_BASE: usize = mem.load_base;

/// Load a PE32+ EFI image into memory and return where to enter it.
pub fn load(image: []const u8) Error!Loaded {
    var pe = coff.Coff.init(image, false) catch return error.BadPe;
    if (!pe.is_image) return error.NotImage;

    if (pe.getHeader().machine != .RISCV64) return error.NotRiscv64;
    if (@intFromEnum(pe.getOptionalHeader().magic) != coff.IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        return error.NotPe32Plus;
    }

    const opt = pe.getOptionalHeader64();
    const want_base: usize = @intCast(opt.image_base);
    const size_of_image: usize = opt.size_of_image;
    const size_of_headers: usize = opt.size_of_headers;
    const entry_rva: usize = pe.getOptionalHeader().address_of_entry_point;

    // The image lands at LOAD_BASE and must fit below the ACPI pool that follows
    // it; size_of_image comes from the (untrusted) PE header, so bound it before
    // the @memset/@memcpy below can run past the load window into other regions.
    const max_image = mem.acpi_pool_base - LOAD_BASE;
    if (size_of_image == 0 or size_of_image > max_image) return error.BadPe;
    if (size_of_headers > size_of_image) return error.BadPe;

    const dst: [*]u8 = @ptrFromInt(LOAD_BASE);

    // Zero first so .bss and inter-section padding start clean.
    @memset(dst[0..size_of_image], 0);

    // Headers, then each section to its virtual address.
    @memcpy(dst[0..size_of_headers], image[0..size_of_headers]);
    for (pe.getSectionHeaders()) |*sec| {
        const vsize: usize = sec.virtual_size;
        const rsize: usize = sec.size_of_raw_data;
        const copy = @min(rsize, if (vsize == 0) rsize else vsize);
        if (copy == 0) continue;
        const src_off: usize = sec.pointer_to_raw_data;
        if (src_off + copy > image.len) return error.BadPe;
        // The section's RVA is header-supplied too: keep it inside the image.
        if (@as(usize, sec.virtual_address) + copy > size_of_image) return error.BadPe;
        @memcpy(dst[sec.virtual_address..][0..copy], image[src_off..][0..copy]);
    }

    // Relocate to our actual load base.
    try relocate(&pe, dst, want_base, LOAD_BASE, size_of_image);

    // We just wrote executable code; make the fetch path observe it.
    asm volatile ("fence.i" ::: .{ .memory = true });

    return .{ .entry = LOAD_BASE + entry_rva, .base = LOAD_BASE, .size = size_of_image };
}

/// Apply the base relocation table so absolute addresses point at LOAD_BASE.
fn relocate(pe: *coff.Coff, dst: [*]u8, want_base: usize, load_base: usize, size_of_image: usize) Error!void {
    const delta = @as(i64, @intCast(load_base)) -% @as(i64, @intCast(want_base));
    if (delta == 0) return; // loaded at its preferred base, nothing to fix up

    const dirs = pe.getDataDirectories();
    const idx = @intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.BASERELOC);
    if (idx >= dirs.len) return;
    const reloc = dirs[idx];
    // No relocation table: the image is position-independent and relocates
    // itself (e.g. the Linux kernel EFI stub). Load it as-is.
    if (reloc.size == 0 or reloc.virtual_address == 0) return;

    // After mapping, the relocation table lives at its RVA in the loaded image.
    var off: usize = 0;
    while (off + @sizeOf(coff.BaseRelocationDirectoryEntry) <= reloc.size) {
        const block: *align(1) const coff.BaseRelocationDirectoryEntry =
            @ptrCast(dst + reloc.virtual_address + off);
        const block_size: usize = block.block_size;
        if (block_size < @sizeOf(coff.BaseRelocationDirectoryEntry)) break;

        const count = (block_size - @sizeOf(coff.BaseRelocationDirectoryEntry)) / @sizeOf(u16);
        const entries: [*]align(1) const coff.BaseRelocation =
            @ptrCast(dst + reloc.virtual_address + off + @sizeOf(coff.BaseRelocationDirectoryEntry));

        for (entries[0..count]) |e| {
            const target_rva = block.page_rva + @as(usize, e.offset);
            if (target_rva >= size_of_image) continue;
            const at = dst + target_rva;
            switch (e.type) {
                .ABSOLUTE => {}, // padding, skip
                .DIR64 => {
                    const p: *align(1) u64 = @ptrCast(at);
                    p.* = @bitCast(@as(i64, @bitCast(p.*)) +% delta);
                },
                .HIGHLOW => {
                    const p: *align(1) u32 = @ptrCast(at);
                    p.* = @bitCast(@as(i32, @bitCast(p.*)) +% @as(i32, @truncate(delta)));
                },
                else => {}, // riscv64 EFI images relocate via DIR64 only
            }
        }

        off += block_size;
    }
}
