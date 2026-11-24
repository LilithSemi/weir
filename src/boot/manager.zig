//! UEFI-style boot manager.
//!
//! Mounts the ESP (GPT, or whole disk as a bare filesystem) and resolves what to
//! boot: the BootOrder / Boot#### EFI variables if present, else a kernel from
//! an extlinux configuration, else the removable-media fallback path
//! \EFI\BOOT\BOOTRISCV64.EFI. The chosen PE is handed to the PE loader.

const std = @import("std");
const storage = @import("../block/storage.zig");
const block = @import("../block/block.zig");
const gpt = @import("../block/gpt.zig");
const fat = @import("../fs/fat.zig");
const fs = @import("../fs/fs.zig");
const pe = @import("../loader/pe.zig");
const extlinux = @import("extlinux.zig");
const var_store = @import("../var/store.zig");
const rt = @import("../uefi/rt.zig");
const uefi = @import("../uefi/uefi.zig");
const initrd = @import("../uefi/initrd.zig");
const simplefs = @import("../uefi/simplefs.zig");
const blockio = @import("../uefi/blockio.zig");
const handledb = @import("../uefi/handledb.zig");
const console = @import("../console/console.zig");
const mem = @import("../mem.zig");
const tpm = @import("../tpm/tpm.zig");

// Kernel and initrd read into high RAM, not a small firmware buffer: a NixOS
// kernel + initramfs are tens of MiB (use -m 2G on QEMU). The layout comes
// from the RAM size (see mem.zig).

/// The part of a staging buffer that lies inside RAM. Empty when none does.
fn staging(base: usize, size: usize) []u8 {
    const end = mem.usable_end;
    const len = if (base < end) @min(size, end - base) else 0;
    return @as([*]u8, @ptrFromInt(base))[0..len];
}

/// Log a file at `path` that does not fit in `capacity` bytes. Returns true
/// when it logged.
fn reportTooLarge(path: []const u8, capacity: usize) bool {
    const size = fat.fileSize(path) orelse return false;
    if (size <= capacity) return false;
    console.err.print(
        "[boot] {s} is {d} bytes, the staging buffer holds {d}\n",
        .{ path, size, capacity },
    ) catch {};
    return true;
}

// EFI global variable namespace GUID (BootOrder, Boot####), on-disk bytes.
const GLOBAL_GUID = [16]u8{
    0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11,
    0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c,
};

const FALLBACK_PATH = "\\EFI\\BOOT\\BOOTRISCV64.EFI";

// loadBootImage() sets dev before findEsp reads it. block.Device is a vtable, so
// zero-init would leave null function pointers.
var dev: block.Device = undefined; // zippy:ignore unsafe_undefined

/// Walk every block device in boot order and load the first bootable image.
/// Returns null when no device holds one.
pub fn loadBootImage() ?pe.Loaded {
    return loadBootImageFrom(0);
}

/// The same, without the devices before the index `first`.
pub fn loadBootImageFrom(first: usize) ?pe.Loaded {
    const buf = staging(mem.kernel_read_base, mem.kernel_read_size);
    if (!storage.init()) {
        console.out.writeAll("[boot] no block device found\n") catch {};
        return null;
    }

    for (storage.devices(), 0..) |sd, i| {
        if (i < first) continue;
        if (tryDevice(sd, i, buf)) |loaded| return loaded;
        console.out.print(
            "[boot] device {d} has no bootable image, trying the next\n",
            .{i},
        ) catch {};
    }
    console.out.writeAll("[boot] no device held a bootable image\n") catch {};
    return null;
}

/// Try to load a bootable image from `sd` (device index `i`, for logs). Mount the
/// ESP, resolve the boot target, and read it. Returns null to let the caller try
/// the next device. Weir measures and publishes only once it commits to a device,
/// so a device it skips leaves no trace in the TPM.
fn tryDevice(sd: storage.Device, i: usize, buf: []u8) ?pe.Loaded {
    dev = sd.dev;

    const part = gpt.findEsp(&dev) orelse blk: {
        console.out.print("[boot] device {d}: no GPT ESP, using the whole disk\n", .{i}) catch {};
        break :blk block.Partition{ .dev = &dev, .base_lba = 0, .num_blocks = dev.num_blocks };
    };
    const filesystem = fat.mount(part) orelse {
        console.out.print("[boot] device {d}: no FAT filesystem\n", .{i}) catch {};
        return null;
    };

    var path_buf: [256]u8 = undefined;
    if (bootEntryPath(&path_buf)) |path| return loadEfiFile(sd, i, part, filesystem, path, buf);
    if (loadExtlinux(sd, part, filesystem, buf)) |loaded| return loaded;
    return loadEfiFile(sd, i, part, filesystem, FALLBACK_PATH, buf);
}

/// Name the disk in the device path after the real boot media (controller kind
/// and MMIO base), so the ESP handle carries a distinct path a boot loader can
/// match. Then publish the ESP via Simple File System so the loaded image reads
/// its files.
fn publish(sd: storage.Device, part: block.Partition) void {
    blockio.setBootMedia(@backingInt(sd.kind), sd.base);
    if (handledb.create()) |h| {
        if (simplefs.install(h, part))
            console.out.writeAll("[boot] ESP published via Simple File System\n") catch {};
    }
}

fn loadEfiFile(
    sd: storage.Device,
    i: usize,
    part: block.Partition,
    filesystem: fs.Fs,
    path: []const u8,
    buf: []u8,
) ?pe.Loaded {
    const n = filesystem.readFile(path, buf) orelse {
        if (reportTooLarge(path, buf.len)) return null;
        console.out.print("[boot] device {d}: {s} not found on the ESP\n", .{ i, path }) catch {};
        return null;
    };
    console.out.print(
        "[boot] booting {s} from device {d}, read {d} bytes\n",
        .{ path, i, n },
    ) catch {};

    publish(sd, part);

    // The boot path is part of the measured boot configuration.
    tpm.measure(tpm.PCR_BOOT_CONFIG, path, "boot path");
    // Measure the boot loader into PCR 4 before Weir runs it. This is the root of
    // the measured-boot chain Weir contributes. The loader then measures what it
    // loads through the TCG2 protocol.
    tpm.measure(tpm.PCR_BOOT_LOADER, buf[0..n], "boot loader");

    // Optional initramfs from the ESP, served to the kernel stub via LoadFile2.
    // The small layout has no initrd staging buffer.
    const initrd_path = "\\EFI\\BOOT\\initrd";
    const initrd_buf = staging(mem.initrd_base, mem.initrd_size);
    if (initrd_buf.len != 0) {
        if (filesystem.readFile(initrd_path, initrd_buf)) |in| {
            console.out.print("[boot] initrd: {d} bytes from {s}\n", .{ in, initrd_path }) catch {};
            tpm.measure(tpm.PCR_BOOT_LOADER, initrd_buf[0..in], "initrd");
            initrd.install(initrd_buf[0..in]);
        } else {
            _ = reportTooLarge(initrd_path, initrd_buf.len);
        }
    }

    return pe.load(buf[0..n]) catch |e| {
        console.err.print("[boot] PE load failed: {s}\n", .{@errorName(e)}) catch {};
        return null;
    };
}

const extlinux_paths = [_][]const u8{
    "\\extlinux\\extlinux.conf",
    "\\boot\\extlinux\\extlinux.conf",
};

// The `append` line as UTF-16 with a terminator. The kernel reads it through
// its loaded image protocol, so it lives in the firmware.
var kernel_cmdline: [extlinux.max_append + 1]u16 = undefined;

const two_mib = 2 << 20;

/// Boot a kernel with an EFI stub from an extlinux configuration on the ESP.
/// Returns null, after a log line, when there is no configuration or its entry
/// cannot be used.
fn loadExtlinux(sd: storage.Device, part: block.Partition, filesystem: fs.Fs, buf: []u8) ?pe.Loaded {
    const config_path = for (extlinux_paths) |p| {
        if (fat.fileSize(p) != null) break p;
    } else return null;
    if (buf.len <= extlinux.max_file) return null;

    // The configuration stays at the top of the staging buffer while the kernel
    // is read below it.
    const text_buf = buf[buf.len - extlinux.max_file ..];
    const kernel_buf = buf[0 .. buf.len - extlinux.max_file];
    const text_len = filesystem.readFile(config_path, text_buf) orelse {
        console.err.print(
            "[boot] extlinux: {s} cannot be read or is larger than {d} bytes\n",
            .{ config_path, extlinux.max_file },
        ) catch {};
        return null;
    };
    const text = text_buf[0..text_len];

    var paths: extlinux.Paths = .{};
    const entry = extlinux.parse(text, config_path, &paths) catch |e| {
        console.err.print("[boot] extlinux: {s} cannot be used, {s}\n", .{ config_path, parseError(e) }) catch {};
        return null;
    };
    console.out.print("[boot] extlinux: {s}, label {s}\n", .{ config_path, entry.label }) catch {};
    if (entry.include)
        console.out.writeAll("[boot] extlinux: include is not supported, the include lines are ignored\n") catch {};
    if (entry.extra_initrds)
        console.out.writeAll("[boot] extlinux: only the first initrd is used, the others are ignored\n") catch {};
    if (entry.fdt)
        console.out.writeAll("[boot] extlinux: the device tree keys are ignored, Weir passes its own tree\n") catch {};

    var options: ?[:0]u16 = null;
    if (entry.append) |args| {
        std.debug.assert(args.len <= extlinux.max_append);
        const len = std.unicode.utf8ToUtf16Le(&kernel_cmdline, args) catch {
            console.err.writeAll("[boot] extlinux: the append line is not valid UTF-8\n") catch {};
            return null;
        };
        kernel_cmdline[len] = 0;
        options = kernel_cmdline[0..len :0];
    }

    const kernel_len = filesystem.readFile(entry.kernel, kernel_buf) orelse {
        if (fat.fileSize(entry.kernel)) |size| {
            if (size <= kernel_buf.len) {
                console.err.print("[boot] extlinux: the read of {s} failed\n", .{entry.kernel}) catch {};
            } else console.err.print(
                "[boot] extlinux: {s} is {d} bytes, the staging buffer holds {d}\n",
                .{ entry.kernel, size, kernel_buf.len },
            ) catch {};
        } else {
            console.err.print("[boot] extlinux: {s} not found\n", .{entry.kernel}) catch {};
        }
        return null;
    };
    console.out.print("[boot] extlinux: kernel {s}, {d} bytes\n", .{ entry.kernel, kernel_len }) catch {};
    const kernel = kernel_buf[0..kernel_len];
    const loaded = loadKernel(entry.kernel, kernel) orelse return null;

    publish(sd, part);
    uefi.setLoadOptions(options);
    tpm.measure(tpm.PCR_BOOT_CONFIG, config_path, "boot path");
    tpm.measure(tpm.PCR_BOOT_CONFIG, text, "extlinux config");
    if (entry.append) |args| tpm.measure(tpm.PCR_BOOT_CONFIG, args, "kernel command line");
    tpm.measure(tpm.PCR_BOOT_LOADER, kernel, "kernel");

    if (entry.append) |args|
        console.out.print("[boot] extlinux: append {s}\n", .{args}) catch {};
    // The staging buffer is free now. The initrd read can overwrite it, and
    // the configuration text with it.
    if (entry.initrd) |path| loadInitrd(filesystem, path, loaded);
    return loaded;
}

fn parseError(e: extlinux.Error) []const u8 {
    return switch (e) {
        error.FileTooLarge => "the file is too large",
        error.LineTooLong => "a line is longer than 1024 bytes",
        error.PathTooLong => "a path is longer than 256 bytes",
        error.BadPath => "a path has no file name or goes above the root",
        error.MissingValue => "a key has no value",
        error.NoLabel => "it has no label",
        error.NoKernel => "the label has no kernel",
    };
}

/// Load the kernel in the first image window. When it does not fit there, the
/// large layout loads it above the file staging buffer, in the page pool.
fn loadKernel(path: []const u8, kernel: []const u8) ?pe.Loaded {
    const size = pe.sizeOf(kernel) catch {
        console.err.print("[boot] extlinux: {s} is not an EFI image\n", .{path}) catch {};
        return null;
    };
    const window = mem.load_limit - mem.load_base;
    const result = if (size <= window) pe.load(kernel) else blk: {
        if (mem.small_layout) {
            console.err.print(
                "[boot] extlinux: {s} needs {d} bytes, the load window holds {d}\n",
                .{ path, size, window },
            ) catch {};
            return null;
        }
        const base = std.mem.alignForward(usize, mem.kernel_read_base + mem.kernel_read_size, two_mib);
        const end = std.math.add(usize, base, size) catch mem.usable_end + 1;
        if (end > mem.usable_end) {
            console.err.print("[boot] extlinux: {s} needs {d} bytes and does not fit in RAM\n", .{ path, size }) catch {};
            return null;
        }
        break :blk pe.loadAt(kernel, base, size);
    };
    return result catch |e| {
        console.err.print("[boot] extlinux: {s} did not load, {s}\n", .{ path, @errorName(e) }) catch {};
        return null;
    };
}

/// Read the initrd to the first 2 MiB boundary after the kernel and serve it
/// through LoadFile2. uefi.prepare takes it out of the page pool. On failure
/// the kernel boots without an initrd.
fn loadInitrd(filesystem: fs.Fs, path: []const u8, kernel: pe.Loaded) void {
    // A kernel in the first image window of the large layout ends below the
    // ACPI pool, so the initrd starts at the page pool.
    const after = std.mem.alignForward(usize, kernel.base + kernel.size, two_mib);
    const base = @max(after, mem.page_pool_base orelse 0);
    const room = if (base < mem.usable_end) mem.usable_end - base else 0;
    const dst = @as([*]u8, @ptrFromInt(base))[0..room];
    const n = filesystem.readFile(path, dst) orelse {
        if (fat.fileSize(path)) |size| {
            if (size <= room) {
                console.err.print("[boot] extlinux: the read of initrd {s} failed, booting without it\n", .{path}) catch {};
            } else console.err.print(
                "[boot] extlinux: initrd {s} is {d} bytes, {d} bytes of RAM are free after the kernel, booting without it\n",
                .{ path, size, room },
            ) catch {};
        } else {
            console.err.print("[boot] extlinux: initrd {s} not found, booting without it\n", .{path}) catch {};
        }
        return;
    };
    console.out.print("[boot] extlinux: initrd {s}, {d} bytes\n", .{ path, n }) catch {};
    tpm.measure(tpm.PCR_BOOT_LOADER, dst[0..n], "initrd");
    initrd.install(dst[0..n]);
}

/// Resolve a file path from the BootOrder / Boot#### EFI variables. Returns null
/// to fall back to the removable-media path.
fn bootEntryPath(out: []u8) ?[]const u8 {
    if (!var_store.available()) return null;

    var order: [256]u8 = undefined;
    var order_size: usize = order.len;
    if (rt.getVariable(uefiName("BootOrder"), &GLOBAL_GUID, null, &order_size, &order) != 0)
        return null;

    var i: usize = 0;
    while (i + 2 <= order_size) : (i += 2) {
        const num = std.mem.readInt(u16, order[i..][0..2], .little);
        var name_buf: [11]u8 = undefined; // "Boot####\0" as UTF-16 below
        const var_name = bootVarName(num, &name_buf);
        var opt: [1024]u8 = undefined;
        var opt_size: usize = opt.len;
        if (rt.getVariable(var_name, &GLOBAL_GUID, null, &opt_size, &opt) != 0) continue;
        if (loadOptionPath(opt[0..opt_size], out)) |p| {
            console.out.print("[boot] Boot{x:0>4} selected\n", .{num}) catch {};
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
