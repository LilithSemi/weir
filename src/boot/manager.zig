//! UEFI-style boot manager.
//!
//! Mounts the ESP (GPT, or whole disk as a bare filesystem) and resolves what to
//! boot: the BootOrder / Boot#### EFI variables if present, else the removable-
//! media fallback path \EFI\BOOT\BOOTRISCV64.EFI. The chosen PE is handed to the
//! PE loader.

const std = @import("std");
const storage = @import("../block/storage.zig");
const block = @import("../block/block.zig");
const gpt = @import("../block/gpt.zig");
const fat = @import("../fs/fat.zig");
const pe = @import("../loader/pe.zig");
const varstore = @import("../uefi/varstore.zig");
const initrd = @import("../uefi/initrd.zig");
const simplefs = @import("../uefi/simplefs.zig");
const handledb = @import("../uefi/handledb.zig");
const console = @import("../console/console.zig");
const mem = @import("../mem.zig");
const tpm = @import("../tpm/tpm.zig");

// Kernel and initrd read into high RAM, not a small firmware buffer: a NixOS
// kernel + initramfs are tens of MiB (use -m 2G on QEMU). Bases derive from
// ram_base (see mem.zig).
const KERNEL_READ_BASE: usize = mem.kernel_read_base;
const KERNEL_READ_MAX: usize = 64 << 20;
const INITRD_BASE: usize = mem.initrd_base;
const INITRD_MAX: usize = 512 << 20;

// EFI global variable namespace GUID (BootOrder, Boot####), on-disk bytes.
const GLOBAL_GUID = [16]u8{ 0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11, 0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c };

const FALLBACK_PATH = "\\EFI\\BOOT\\BOOTRISCV64.EFI";

var dev: block.Device = undefined;

/// Find the block device, mount the ESP, resolve the boot target, and load it.
pub fn loadBootImage() ?pe.Loaded {
    const buf = @as([*]u8, @ptrFromInt(KERNEL_READ_BASE))[0..KERNEL_READ_MAX];
    if (!storage.init()) {
        console.writeStr("[boot] no block device found\n");
        return null;
    }
    dev = storage.device();

    const part = gpt.findEsp(&dev) orelse blk: {
        console.writeStr("[boot] no GPT ESP; treating whole disk as a filesystem\n");
        break :blk block.Partition{ .dev = &dev, .base_lba = 0, .num_blocks = dev.num_blocks };
    };
    const filesystem = fat.mount(part) orelse {
        console.writeStr("[boot] could not mount a FAT filesystem\n");
        return null;
    };

    // Publish the ESP via Simple File System so the loaded bootloader reads its
    // own config/kernel/initrd through the standard protocol.
    if (handledb.create()) |h| {
        if (simplefs.install(h, part)) console.writeStr("[boot] ESP published via Simple File System\n");
    }

    var path_buf: [256]u8 = undefined;
    const path = bootEntryPath(&path_buf) orelse FALLBACK_PATH;
    console.printf("[boot] booting {s}\n", .{path});
    // The boot path is part of the measured boot configuration.
    tpm.measure(tpm.PCR_BOOT_CONFIG, path, "boot path");

    const n = filesystem.readFile(path, buf) orelse {
        console.printf("[boot] {s} not found on the ESP\n", .{path});
        return null;
    };
    console.printf("[boot] read {d} bytes, loading PE\n", .{n});

    // Measure the boot loader into PCR 4 before running it: the root of the
    // measured-boot chain Weir contributes (the loader then measures what it
    // loads via the TCG2 protocol).
    tpm.measure(tpm.PCR_BOOT_LOADER, buf[0..n], "boot loader");

    // Optional initramfs from the ESP, served to the kernel stub via LoadFile2.
    const initrd_buf = @as([*]u8, @ptrFromInt(INITRD_BASE))[0..INITRD_MAX];
    if (filesystem.readFile("\\EFI\\BOOT\\initrd", initrd_buf)) |in| {
        console.printf("[boot] initrd: {d} bytes from \\EFI\\BOOT\\initrd\n", .{in});
        tpm.measure(tpm.PCR_BOOT_LOADER, initrd_buf[0..in], "initrd");
        initrd.install(initrd_buf[0..in]);
    }

    return pe.load(buf[0..n]) catch |e| {
        console.printf("[boot] PE load failed: {s}\n", .{@errorName(e)});
        return null;
    };
}

/// Resolve a file path from the BootOrder / Boot#### EFI variables. Returns null
/// to fall back to the removable-media path.
fn bootEntryPath(out: []u8) ?[]const u8 {
    if (!varstore.available()) return null;

    var order: [256]u8 = undefined;
    var order_size: usize = order.len;
    if (varstore.get(uefiName("BootOrder"), &GLOBAL_GUID, null, &order_size, &order) != .success) return null;

    var i: usize = 0;
    while (i + 2 <= order_size) : (i += 2) {
        const num = std.mem.readInt(u16, order[i..][0..2], .little);
        var name_buf: [11]u8 = undefined; // "Boot####\0" as UTF-16 below
        const var_name = bootVarName(num, &name_buf);
        var opt: [1024]u8 = undefined;
        var opt_size: usize = opt.len;
        if (varstore.get(var_name, &GLOBAL_GUID, null, &opt_size, &opt) != .success) continue;
        if (loadOptionPath(opt[0..opt_size], out)) |p| {
            console.printf("[boot] Boot{x:0>4} selected\n", .{num});
            return p;
        }
    }
    return null;
}

/// Parse an EFI_LOAD_OPTION and pull the FilePath (Media/FilePath node) out as
/// an ASCII path into `out`.
fn loadOptionPath(opt: []const u8, out: []u8) ?[]const u8 {
    if (opt.len < 6) return null;
    const fp_len = std.mem.readInt(u16, opt[4..6], .little);
    // Skip the null-terminated CHAR16 Description.
    var p: usize = 6;
    while (p + 2 <= opt.len) : (p += 2) {
        if (opt[p] == 0 and opt[p + 1] == 0) {
            p += 2;
            break;
        }
    }
    const dp_end = p + fp_len;
    // Walk device-path nodes looking for Media(4)/FilePath(4).
    while (p + 4 <= dp_end and p + 4 <= opt.len) {
        const dtype = opt[p];
        const subtype = opt[p + 1];
        const len = std.mem.readInt(u16, opt[p + 2 ..][0..2], .little);
        if (len < 4) break;
        if (dtype == 0x7f) break; // end of device path
        if (dtype == 0x04 and subtype == 0x04) {
            // CHAR16 path follows the 4-byte header.
            var n: usize = 0;
            var q: usize = p + 4;
            while (q + 2 <= p + len and n + 1 < out.len) : (q += 2) {
                const ch = @as(u16, opt[q]) | (@as(u16, opt[q + 1]) << 8);
                if (ch == 0) break;
                out[n] = if (ch < 0x80) @intCast(ch) else '?';
                n += 1;
            }
            return out[0..n];
        }
        p += len;
    }
    return null;
}

// "Boot####" variable name as a null-terminated UTF-16 string in a static buffer.
var name_storage: [9]u16 = undefined;
fn bootVarName(num: u16, scratch: []u8) [*:0]const u16 {
    _ = scratch;
    const hex = "0123456789ABCDEF";
    const prefix = "Boot";
    inline for (prefix, 0..) |c, idx| name_storage[idx] = c;
    name_storage[4] = hex[(num >> 12) & 0xf];
    name_storage[5] = hex[(num >> 8) & 0xf];
    name_storage[6] = hex[(num >> 4) & 0xf];
    name_storage[7] = hex[num & 0xf];
    name_storage[8] = 0;
    return @ptrCast(&name_storage);
}

// Compile-time UTF-16 literal for fixed variable names.
fn uefiName(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}
