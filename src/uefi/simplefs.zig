//! EFI Simple File System + File protocols, backed by the built-in FAT driver.
//!
//! How a bootloader (systemd-boot, Limine) reads its config, kernel and initrd
//! off the ESP: SimpleFileSystem on the disk handle, OpenVolume to root, then
//! Open/Read/GetInfo. A future loadable EXT4 driver plugs in the same way.

const std = @import("std");
const uefi = std.os.uefi;
const fat = @import("../fs/fat.zig");
const handledb = @import("handledb.zig");
const blockio = @import("blockio.zig");
const block = @import("../block/block.zig");
const console = @import("../console/console.zig");

const Status = uefi.Status;
const ok = @intFromEnum(Status.success);
const File = uefi.protocol.File;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;

const MAX_OPEN = 16;

const Handle = struct {
    // proto MUST be the first field: a *File aliases a *Handle. alloc() sets it.
    proto: File = undefined, // zippy:ignore unsafe_undefined
    used: bool = false,
    is_dir: bool = false,
    loc: fat.Loc = .{ .root16 = false, .cluster = 0 }, // a directory's own location
    cluster: u32 = 0, // a file's start cluster
    size: u32 = 0,
    position: u64 = 0, // file byte offset, or directory entry index
    // Only name[0..name_units] holds valid units.
    name: [256]u16 = undefined, // zippy:ignore unsafe_undefined
    name_units: usize = 1,
};

var handles: [MAX_OPEN]Handle = undefined;
// install() fills sfs before the app opens a volume.
var sfs: SimpleFileSystem = undefined; // zippy:ignore unsafe_undefined
var dev_path: [66]u8 = undefined; // disk_base(20) + HardDrive(42) + End(4)
var mounted = false;

// EFI_DEVICE_PATH_PROTOCOL 09576e91-6d3f-11d2-8e39-00a0c969723b
const DEVICE_PATH_GUID = uefi.Guid{
    .time_low = 0x09576e91,
    .time_mid = 0x6d3f,
    .time_high_and_version = 0x11d2,
    .clock_seq_high_and_reserved = 0x8e,
    .clock_seq_low = 0x39,
    .node = .{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
};

fn vtable() File {
    return .{
        .revision = 0x00010000,
        ._open = @ptrFromInt(@intFromPtr(&fileOpen)),
        ._close = @ptrFromInt(@intFromPtr(&fileClose)),
        ._delete = @ptrFromInt(@intFromPtr(&fileDelete)),
        ._read = @ptrFromInt(@intFromPtr(&fileRead)),
        ._write = @ptrFromInt(@intFromPtr(&fileWrite)),
        ._get_position = @ptrFromInt(@intFromPtr(&fileGetPosition)),
        ._set_position = @ptrFromInt(@intFromPtr(&fileSetPosition)),
        ._get_info = @ptrFromInt(@intFromPtr(&fileGetInfo)),
        ._set_info = @ptrFromInt(@intFromPtr(&fileSetInfo)),
        ._flush = @ptrFromInt(@intFromPtr(&fileFlush)),
    };
}

fn alloc() ?*Handle {
    for (&handles) |*h| {
        if (!h.used) {
            h.* = .{};
            h.used = true;
            h.proto = vtable();
            return h;
        }
    }
    return null;
}

fn openVolume(self: *const SimpleFileSystem, out: **File) callconv(.c) usize {
    _ = self;
    const h = alloc() orelse return @intFromEnum(Status.out_of_resources);
    h.is_dir = true;
    h.loc = fat.rootLoc();
    h.name[0] = '\\';
    h.name[1] = 0;
    h.name_units = 2;
    out.* = &h.proto;
    return ok;
}

// --- File protocol ----------------------------------------------------------

fn fileOpen(
    self: *File,
    new: **File,
    name: [*:0]const u16,
    mode: u64,
    attr: u64,
) callconv(.c) usize {
    _ = mode;
    _ = attr;
    const h: *Handle = @ptrCast(self);
    if (!h.is_dir) return @intFromEnum(Status.not_found);

    // Start at root for an absolute path, else at this directory.
    var loc = h.loc;
    var i: usize = 0;
    if (name[0] == '\\' or name[0] == '/') {
        loc = fat.rootLoc();
        i = 1;
    }

    var last: fat.DirEnt = .{};
    var is_dir = true;
    var resolved = false;
    while (name[i] != 0) {
        // Extract the next component (ASCII subset).
        var comp: [256]u8 = undefined;
        var c: usize = 0;
        while (name[i] != 0 and name[i] != '\\' and name[i] != '/') : (i += 1) {
            if (c < comp.len) {
                comp[c] = if (name[i] < 0x80) @intCast(name[i]) else '?';
                c += 1;
            }
        }
        while (name[i] == '\\' or name[i] == '/') i += 1;
        if (c == 0) continue;
        if (c == 1 and comp[0] == '.') continue;

        if (!fat.lookupComponent(loc, comp[0..c], &last)) return @intFromEnum(Status.not_found);
        resolved = true;
        is_dir = last.is_dir;
        if (name[i] != 0) {
            if (!last.is_dir) return @intFromEnum(Status.not_found);
            loc = .{ .root16 = false, .cluster = last.cluster };
        }
    }

    const nh = alloc() orelse return @intFromEnum(Status.out_of_resources);
    if (!resolved) {
        // Opened the directory itself (e.g. trailing separators).
        nh.is_dir = true;
        nh.loc = loc;
        nh.name[0] = '\\';
        nh.name[1] = 0;
        nh.name_units = 2;
    } else {
        nh.is_dir = is_dir;
        nh.cluster = last.cluster;
        nh.size = last.size;
        nh.loc = .{ .root16 = false, .cluster = last.cluster };
        @memcpy(nh.name[0..last.name_units], last.name[0..last.name_units]);
        nh.name_units = last.name_units;
    }
    new.* = &nh.proto;
    return ok;
}

fn fileClose(self: *File) callconv(.c) usize {
    const h: *Handle = @ptrCast(self);
    h.used = false;
    return ok;
}

fn fileDelete(self: *File) callconv(.c) usize {
    _ = self;
    return @intFromEnum(Status.unsupported);
}

fn fileRead(self: *File, buffer_size: *usize, buffer: [*]u8) callconv(.c) usize {
    const h: *Handle = @ptrCast(self);
    if (h.is_dir) {
        var ent: fat.DirEnt = .{};
        if (!fat.enumerate(h.loc, @intCast(h.position), &ent)) {
            buffer_size.* = 0; // end of directory
            return ok;
        }
        const st = writeFileInfo(
            buffer[0..buffer_size.*],
            buffer_size,
            ent.name[0..ent.name_units],
            ent.size,
            ent.is_dir,
        );
        if (st == ok) h.position += 1;
        return st;
    }
    const size: usize = @intCast(h.size);
    const at: usize = @intCast(@min(h.position, h.size));
    const want = @min(buffer_size.*, size -| at);
    const n = fat.readRegion(h.cluster, h.size, h.position, buffer[0..want]);
    h.position += n;
    buffer_size.* = n;
    return ok;
}

fn fileWrite(self: *File, buffer_size: *usize, buffer: [*]const u8) callconv(.c) usize {
    _ = self;
    _ = buffer_size;
    _ = buffer;
    return @intFromEnum(Status.write_protected);
}

fn fileGetPosition(self: *const File, pos: *u64) callconv(.c) usize {
    const h: *const Handle = @ptrCast(self);
    pos.* = h.position;
    return ok;
}

fn fileSetPosition(self: *File, pos: u64) callconv(.c) usize {
    const h: *Handle = @ptrCast(self);
    // 0xffffffffffffffff means seek to end of file.
    h.position = if (pos == 0xffffffffffffffff) h.size else pos;
    return ok;
}

fn fileGetInfo(
    self: *const File,
    guid: *align(8) const uefi.Guid,
    size: *usize,
    buffer: ?[*]u8,
) callconv(.c) usize {
    const h: *const Handle = @ptrCast(self);
    if (!std.mem.eql(u8, std.mem.asBytes(guid), std.mem.asBytes(&File.Info.File.guid))) {
        return @intFromEnum(Status.unsupported);
    }
    const buf = if (buffer) |b| b[0..size.*] else {
        size.* = 80 + h.name_units * 2;
        return @intFromEnum(Status.buffer_too_small);
    };
    return writeFileInfo(buf, size, h.name[0..h.name_units], h.size, h.is_dir);
}

fn fileSetInfo(
    self: *File,
    guid: *align(8) const uefi.Guid,
    size: usize,
    buffer: [*]const u8,
) callconv(.c) usize {
    _ = self;
    _ = guid;
    _ = size;
    _ = buffer;
    return @intFromEnum(Status.write_protected);
}

fn fileFlush(self: *File) callconv(.c) usize {
    _ = self;
    return ok;
}

/// Write an EFI_FILE_INFO into `buf`.
fn writeFileInfo(buf: []u8, size: *usize, name: []const u16, file_size: u32, is_dir: bool) usize {
    const needed = 80 + name.len * 2;
    if (buf.len < needed) {
        size.* = needed;
        return @intFromEnum(Status.buffer_too_small);
    }
    @memset(buf[0..needed], 0);
    std.mem.writeInt(u64, buf[0..8], needed, .little); // Size
    std.mem.writeInt(u64, buf[8..16], file_size, .little); // FileSize
    std.mem.writeInt(u64, buf[16..24], file_size, .little); // PhysicalSize
    // create/access/mod times left zero (24..72)
    std.mem.writeInt(u64, buf[72..80], if (is_dir) 0x10 else 0, .little); // Attribute
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        std.mem.writeInt(u16, buf[80 + i * 2 ..][0..2], name[i], .little);
    }
    size.* = needed;
    return ok;
}

// The handle DB has room during setup, so install never returns null here.
fn addProtocol(handle: *handledb.Handle, guid: *const uefi.Guid, iface: *anyopaque) void {
    _ = handledb.install(handle, guid, iface); // zippy:ignore discarded_error
}

/// Mount FAT on `part` and install Simple File System + a Device Path on
/// `handle`. The Hard Drive device path node lets a bootloader match its boot
/// device to this volume.
pub fn install(handle: *handledb.Handle, part: block.Partition) bool {
    if (fat.mount(part) == null) return false;
    for (&handles) |*h| h.used = false;
    sfs = .{ .revision = 0x00010000, ._open_volume = @ptrFromInt(@intFromPtr(&openVolume)) };

    // <disk base>/HardDrive(part)/End so it matches the disk handle's prefix.
    @memcpy(dev_path[0..20], &blockio.disk_base);
    dev_path[20] = 0x04; // Media
    dev_path[21] = 0x01; // Hard Drive
    std.mem.writeInt(u16, dev_path[22..24], 42, .little);
    std.mem.writeInt(u32, dev_path[24..28], part.number, .little);
    std.mem.writeInt(u64, dev_path[28..36], part.base_lba, .little);
    std.mem.writeInt(u64, dev_path[36..44], part.num_blocks, .little);
    @memcpy(dev_path[44..60], &part.signature);
    dev_path[60] = 0x02; // MBR type: GPT
    dev_path[61] = 0x02; // signature type: GUID
    dev_path[62] = 0x7f; // End of device path
    dev_path[63] = 0xff;
    std.mem.writeInt(u16, dev_path[64..66], 4, .little);

    mounted = true;
    addProtocol(handle, &DEVICE_PATH_GUID, @ptrCast(&dev_path));
    blockio.installPartition(handle, part); // a complete volume: Block I/O too
    addProtocol(handle, &SimpleFileSystem.guid, @ptrCast(&sfs));
    return true;
}
