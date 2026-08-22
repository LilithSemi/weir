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

/// Load a PE32+ EFI image at the fixed firmware load base. Used for the first
/// image (the bootloader) that Weir enters after it drops to S-mode.
pub fn load(image: []const u8) Error!Loaded {
    // The image must fit below the ACPI pool that follows LOAD_BASE.
    return loadAt(image, LOAD_BASE, mem.acpi_pool_base - LOAD_BASE);
}

/// The in-memory footprint (size_of_image) of a PE32+ image, from its header.
/// LoadImage needs this to size a load region before it maps the image.
pub fn sizeOf(image: []const u8) Error!usize {
    var pe = coff.Coff.init(image, false) catch return error.BadPe;
    if (!pe.is_image) return error.NotImage;
    if (pe.getHeader().machine != .RISCV64) return error.NotRiscv64;
    if (@intFromEnum(pe.getOptionalHeader().magic) != coff.IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        return error.NotPe32Plus;
    }
    return pe.getOptionalHeader64().size_of_image;
}

/// Load a PE32+ EFI image into `[load_base, load_base + max_image)` and return
/// where to enter it. A nested LoadImage passes a fresh region here so the image
/// never lands on the still-running caller at LOAD_BASE.
pub fn loadAt(image: []const u8, load_base: usize, max_image: usize) Error!Loaded {
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

    // size_of_image comes from the (untrusted) PE header, so bound it to the load
    // window before the @memset/@memcpy below can run past it into other regions.
    if (size_of_image == 0 or size_of_image > max_image) return error.BadPe;
    if (size_of_headers > size_of_image) return error.BadPe;

    const dst: [*]u8 = @ptrFromInt(load_base);

    const sections = pe.getSectionHeaders();

    // Copy the headers and each section's raw data to its virtual address, then
    // zero ONLY the bytes no copy covered (.bss tails, inter-section padding,
    // the region past the last section). Zeroing the whole image up front and
    // then copying over most of it is byte-for-byte the boot's slowest step on
    // the non-posted DDR: the covered bytes get written twice. A `Span` records
    // each copied [start, end); their complement within the image is what needs
    // zeroing.
    const Span = struct { start: usize, end: usize };
    // One span per section plus the headers. PE allows at most 96 sections, so a
    // fixed buffer is enough; if a malformed image claims more, fall back to the
    // whole-image zero rather than skip a span (which would leave copied bytes
    // in the zero complement and clobber them).
    var spans: [128]Span = undefined;
    if (sections.len + 1 > spans.len) {
        @memset(dst[0..size_of_image], 0);
    }

    @memcpy(dst[0..size_of_headers], image[0..size_of_headers]);
    var span_n: usize = 0;
    if (sections.len + 1 <= spans.len) {
        spans[span_n] = .{ .start = 0, .end = size_of_headers };
        span_n += 1;
    }
    for (sections) |*sec| {
        const vsize: usize = sec.virtual_size;
        const rsize: usize = sec.size_of_raw_data;
        const copy = @min(rsize, if (vsize == 0) rsize else vsize);
        if (copy == 0) continue;
        const src_off: usize = sec.pointer_to_raw_data;
        if (src_off + copy > image.len) return error.BadPe;
        // The section's RVA is header-supplied too: keep it inside the image.
        const va: usize = sec.virtual_address;
        if (va + copy > size_of_image) return error.BadPe;
        @memcpy(dst[va..][0..copy], image[src_off..][0..copy]);
        if (sections.len + 1 <= spans.len) {
            spans[span_n] = .{ .start = va, .end = va + copy };
            span_n += 1;
        }
    }

    if (sections.len + 1 <= spans.len) {
        // Insertion-sort the copied spans by start (span_n is small).
        var i: usize = 1;
        while (i < span_n) : (i += 1) {
            const key = spans[i];
            var j: usize = i;
            while (j > 0 and spans[j - 1].start > key.start) : (j -= 1) spans[j] = spans[j - 1];
            spans[j] = key;
        }
        // Zero the gaps between copied spans, and the tail past the last one.
        var cursor: usize = 0;
        i = 0;
        while (i < span_n) : (i += 1) {
            if (spans[i].start > cursor) @memset(dst[cursor..spans[i].start], 0);
            if (spans[i].end > cursor) cursor = spans[i].end;
        }
        if (cursor < size_of_image) @memset(dst[cursor..size_of_image], 0);
    }

    // Relocate to our actual load base.
    relocate(&pe, dst, want_base, load_base, size_of_image);

    // We just wrote executable code. Make the fetch path observe it.
    asm volatile ("fence.i" ::: .{ .memory = true });

    return .{ .entry = load_base + entry_rva, .base = load_base, .size = size_of_image };
}

/// Apply the base relocation table so absolute addresses point at LOAD_BASE.
fn relocate(
    pe: *coff.Coff,
    dst: [*]u8,
    want_base: usize,
    load_base: usize,
    size_of_image: usize,
) void {
    const delta = @as(i64, @intCast(load_base)) -% @as(i64, @intCast(want_base));
    if (delta == 0) return; // loaded at its preferred base, nothing to fix up

    const dirs = pe.getDataDirectories();
    const idx = @intFromEnum(coff.IMAGE.DIRECTORY_ENTRY.BASERELOC);
    if (idx >= dirs.len) return;
    const reloc = dirs[idx];
    // No relocation table: the image is position-independent and relocates
    // itself (e.g. the Linux kernel EFI stub). Load it as-is.
    if (reloc.size == 0 or reloc.virtual_address == 0) return;

    const hdr_size = @sizeOf(coff.BaseRelocationDirectoryEntry);
    // After mapping, the relocation table lives at its RVA in the loaded image.
    var off: usize = 0;
    while (off + hdr_size <= reloc.size) {
        const block: *align(1) const coff.BaseRelocationDirectoryEntry =
            @ptrCast(dst + reloc.virtual_address + off);
        const block_size: usize = block.block_size;
        if (block_size < hdr_size) break;

        const count = (block_size - hdr_size) / @sizeOf(u16);
        const entries: [*]align(1) const coff.BaseRelocation =
            @ptrCast(dst + reloc.virtual_address + off + hdr_size);

        for (entries[0..count]) |e| {
            const target_rva = block.page_rva + @as(usize, e.offset);
            if (target_rva >= size_of_image) continue;
            const at = dst + target_rva;
            switch (e.type) {
                .DIR64 => {
                    const p: *align(1) u64 = @ptrCast(at);
                    p.* = @bitCast(@as(i64, @bitCast(p.*)) +% delta);
                },
                .HIGHLOW => {
                    const p: *align(1) u32 = @ptrCast(at);
                    p.* = @bitCast(@as(i32, @bitCast(p.*)) +% @as(i32, @truncate(delta)));
                },
                // ABSOLUTE entries are padding. Other types do not occur:
                // riscv64 EFI images relocate through DIR64 only.
                else => {},
            }
        }

        off += block_size;
    }
}
