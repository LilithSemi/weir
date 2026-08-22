//! Initrd delivery to the Linux EFI stub via the LoadFile2 protocol.
//!
//! The riscv/arm Linux EFI stub loads its initrd via a LoadFile2 protocol on the
//! well-known LINUX_EFI_INITRD_MEDIA device path. We install a handle carrying
//! that device path + a LoadFile2 that hands over the embedded initramfs, so the
//! kernel reaches a real userspace instead of panicking for lack of a rootfs.

const std = @import("std");
const uefi = std.os.uefi;
const handledb = @import("handledb.zig");

const Status = uefi.Status;

// LINUX_EFI_INITRD_MEDIA_GUID 5568e427-68fc-4f3d-ac74-ca555231cc68
pub const INITRD_MEDIA_GUID = uefi.Guid{
    .time_low = 0x5568e427,
    .time_mid = 0x68fc,
    .time_high_and_version = 0x4f3d,
    .clock_seq_high_and_reserved = 0xac,
    .clock_seq_low = 0x74,
    .node = .{ 0xca, 0x55, 0x52, 0x31, 0xcc, 0x68 },
};

// EFI_LOAD_FILE2_PROTOCOL 4006c0c1-fcb3-403e-996d-4a6c8724e06d
pub const LOAD_FILE2_GUID = uefi.Guid{
    .time_low = 0x4006c0c1,
    .time_mid = 0xfcb3,
    .time_high_and_version = 0x403e,
    .clock_seq_high_and_reserved = 0x99,
    .clock_seq_low = 0x6d,
    .node = .{ 0x4a, 0x6c, 0x87, 0x24, 0xe0, 0x6d },
};

// EFI_DEVICE_PATH_PROTOCOL 09576e91-6d3f-11d2-8e39-00a0c969723b
pub const DEVICE_PATH_GUID = uefi.Guid{
    .time_low = 0x09576e91,
    .time_mid = 0x6d3f,
    .time_high_and_version = 0x11d2,
    .clock_seq_high_and_reserved = 0x8e,
    .clock_seq_low = 0x39,
    .node = .{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
};

const LoadFile2 = extern struct {
    load_file: *const fn (
        *LoadFile2,
        *const anyopaque,
        bool,
        *usize,
        ?*anyopaque,
    ) callconv(.c) Status,
};

// Device path: Media(0x04)/Vendor(0x03) carrying INITRD_MEDIA_GUID, then End.
var device_path = [_]u8{
    0x04, 0x03, 0x14, 0x00, // Media, Vendor, length 20
    // INITRD_MEDIA_GUID, little-endian mixed form.
    0x27, 0xe4, 0x68, 0x55,
    0xfc, 0x68, 0x3d, 0x4f,
    0xac, 0x74, 0xca, 0x55,
    0x52, 0x31, 0xcc, 0x68,
    0x7f, 0xff, 0x04, 0x00, // End of device path
};
const VENDOR_NODE_LEN = 20;

// install() writes lf2 before the app can reach it.
var lf2: LoadFile2 = undefined; // zippy:ignore unsafe_undefined
var data: []const u8 = &[_]u8{};
var handle: ?*handledb.Handle = null;

fn loadFile(
    self: *LoadFile2,
    fp: *const anyopaque,
    boot_policy: bool,
    buffer_size: *usize,
    buffer: ?*anyopaque,
) callconv(.c) Status {
    _ = self;
    _ = fp;
    _ = boot_policy;
    if (buffer == null or buffer_size.* < data.len) {
        buffer_size.* = data.len;
        return Status.buffer_too_small;
    }
    @memcpy(@as([*]u8, @ptrCast(buffer.?))[0..data.len], data);
    buffer_size.* = data.len;
    return Status.success;
}

// The handle DB has room during setup, so install never returns null here.
fn addProtocol(h: *handledb.Handle, guid: *const uefi.Guid, iface: *anyopaque) void {
    _ = handledb.install(h, guid, iface); // zippy:ignore discarded_error
}

/// Install the initrd handle (Device Path + LoadFile2) so the stub finds it.
pub fn install(initrd: []const u8) void {
    data = initrd;
    lf2 = .{ .load_file = @ptrFromInt(@intFromPtr(&loadFile)) };
    const h = handledb.create() orelse return;
    addProtocol(h, &DEVICE_PATH_GUID, @ptrCast(&device_path));
    addProtocol(h, &LOAD_FILE2_GUID, @ptrCast(&lf2));
    handle = h;
}

/// The physical region the live initrd occupies, or null if none is installed.
/// The memory map reserves it and the page allocator skips it, so the OS cannot
/// allocate over the initrd before the stub has fetched it via LoadFile2.
pub fn region() ?struct { base: usize, len: usize } {
    if (handle == null or data.len == 0) return null;
    return .{ .base = @intFromPtr(data.ptr), .len = data.len };
}

/// LocateDevicePath(LoadFile2): if the initrd handle exists, return it and
/// advance the caller's device-path pointer past our vendor node.
pub fn matchLoadFile2(guid: *const uefi.Guid, dp: **const anyopaque, device: *?uefi.Handle) bool {
    if (handle == null) return false;
    if (!std.mem.eql(u8, std.mem.asBytes(guid), std.mem.asBytes(&LOAD_FILE2_GUID))) return false;
    device.* = @ptrCast(handle.?);
    dp.* = @ptrFromInt(@intFromPtr(dp.*) + VENDOR_NODE_LEN);
    return true;
}
