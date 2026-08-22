//! EFI Block I/O Protocol over a generic block device.
//!
//! Installed on a disk handle so EFI drivers and apps can read the raw disk
//! through the standard protocol, as on real firmware. Read-only for now.

const std = @import("std");
const uefi = std.os.uefi;
const block = @import("../block/block.zig");
const blk = @import("../virtio/blk.zig");
const handledb = @import("handledb.zig");

const Status = uefi.Status;
const ok = @intFromEnum(Status.success);
const BlockIo = uefi.protocol.BlockIo;
const Media = BlockIo.BlockMedia;

// install() fills these before any EFI caller reads them.
var media: Media = undefined; // zippy:ignore unsafe_undefined
var protocol: BlockIo = undefined; // zippy:ignore unsafe_undefined
var dev: block.Device = undefined; // zippy:ignore unsafe_undefined
var disk_dp: [24]u8 = undefined;

// The handle DB has room during setup, so install never returns null here.
fn addProtocol(handle: *handledb.Handle, guid: *const uefi.Guid, iface: *anyopaque) void {
    _ = handledb.install(handle, guid, iface); // zippy:ignore discarded_error
}

// EFI_DEVICE_PATH_PROTOCOL GUID.
const DEVICE_PATH_GUID = uefi.Guid{
    .time_low = 0x09576e91,
    .time_mid = 0x6d3f,
    .time_high_and_version = 0x11d2,
    .clock_seq_high_and_reserved = 0x8e,
    .clock_seq_low = 0x39,
    .node = .{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
};

/// The disk's base device path: a Hardware/Vendor node (so a bootloader can
/// build <disk>/HD(part) and match it to the partition handle). Shared with
/// simplefs.zig, which prepends it to the Hard Drive node. setBootMedia bakes the
/// real boot device's identity into the vendor GUID, so each physical disk has a
/// distinct path rather than one shared placeholder.
pub var disk_base = [20]u8{
    0x01, 0x04, 0x14, 0x00, // Hardware, Vendor, length 20
    // Vendor GUID: "Weir" + [8]=controller kind + [12..20]=controller MMIO base.
    0x57, 0x65, 0x69, 0x72, // "Weir"
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

/// Bake the boot media's identity into the disk device path: `kind` tags the
/// controller class (virtio/sdhci/sd_spi) and `base` its MMIO address. Call
/// before publishing the disk or ESP handle so the path names the real disk.
/// Keeps a Hardware/Vendor node, so a bootloader's direct-boot detection (which
/// looks for a Media vendor or firmware-volume node) still treats it as a disk.
pub fn setBootMedia(kind: u8, base: u64) void {
    disk_base[8] = kind;
    std.mem.writeInt(u64, disk_base[12..20], base, .little);
}

fn resetDev(self: *BlockIo, extended: bool) callconv(.c) usize {
    _ = self;
    _ = extended;
    return ok;
}

fn readBlocks(
    self: *BlockIo,
    media_id: u32,
    lba: u64,
    buffer_size: usize,
    buf: [*]u8,
) callconv(.c) usize {
    _ = self;
    _ = media_id;
    if (buffer_size % dev.block_size != 0) return @intFromEnum(Status.bad_buffer_size);
    const count: u32 = @intCast(buffer_size / dev.block_size);
    if (!dev.readBlocks(lba, count, buf[0..buffer_size])) return @intFromEnum(Status.device_error);
    return ok;
}

fn writeBlocks(
    self: *BlockIo,
    media_id: u32,
    lba: u64,
    buffer_size: usize,
    buf: [*]const u8,
) callconv(.c) usize {
    _ = self;
    _ = media_id;
    _ = lba;
    _ = buffer_size;
    _ = buf;
    return @intFromEnum(Status.write_protected);
}

fn flushBlocks(self: *BlockIo) callconv(.c) usize {
    _ = self;
    return ok;
}

/// Bring up the block device and install Block I/O on a fresh handle. Returns
/// the handle, or null if there is no disk.
pub fn install() ?*handledb.Handle {
    if (!blk.init()) return null;
    dev = blk.device();

    media = .{
        .media_id = 0,
        .removable_media = false,
        .media_present = true,
        .logical_partition = false,
        .read_only = true,
        .write_caching = false,
        .block_size = dev.block_size,
        .io_align = 0,
        .last_block = if (dev.num_blocks > 0) dev.num_blocks - 1 else 0,
        .lowest_aligned_lba = 0,
        .logical_blocks_per_physical_block = 1,
        .optimal_transfer_length_granularity = 0,
    };
    protocol = .{
        .revision = 1,
        .media = &media,
        ._reset = @ptrFromInt(@intFromPtr(&resetDev)),
        ._read_blocks = @ptrFromInt(@intFromPtr(&readBlocks)),
        ._write_blocks = @ptrFromInt(@intFromPtr(&writeBlocks)),
        ._flush_blocks = @ptrFromInt(@intFromPtr(&flushBlocks)),
    };
    const h = handledb.install(null, &BlockIo.guid, @ptrCast(&protocol));
    if (h) |handle| {
        @memcpy(disk_dp[0..20], &disk_base);
        disk_dp[20] = 0x7f; // End of device path
        disk_dp[21] = 0xff;
        disk_dp[22] = 0x04;
        disk_dp[23] = 0x00;
        addProtocol(handle, &DEVICE_PATH_GUID, @ptrCast(&disk_dp));
    }
    return h;
}

// installPartition() fills these before any EFI caller reads them.
var part_media: Media = undefined; // zippy:ignore unsafe_undefined
var part_proto: BlockIo = undefined; // zippy:ignore unsafe_undefined
var part_dev: block.Partition = undefined; // zippy:ignore unsafe_undefined

fn partReset(self: *BlockIo, extended: bool) callconv(.c) usize {
    _ = self;
    _ = extended;
    return ok;
}

fn partRead(
    self: *BlockIo,
    media_id: u32,
    lba: u64,
    buffer_size: usize,
    buf: [*]u8,
) callconv(.c) usize {
    _ = self;
    _ = media_id;
    const bs = part_dev.dev.block_size;
    if (buffer_size % bs != 0) return @intFromEnum(Status.bad_buffer_size);
    const count: u32 = @intCast(buffer_size / bs);
    if (!part_dev.readBlocks(lba, count, buf[0..buffer_size])) {
        return @intFromEnum(Status.device_error);
    }
    return ok;
}

/// Install a logical-partition Block I/O on `handle` (reads partition-relative
/// blocks), so the handle is a complete volume a bootloader can match and read.
pub fn installPartition(handle: *handledb.Handle, part: block.Partition) void {
    part_dev = part;
    part_media = .{
        .media_id = 0,
        .removable_media = false,
        .media_present = true,
        // Presented as a standalone whole-disk volume (not a logical partition):
        // Limine's boot-volume match verifies LogicalPartition == (partition != 0),
        // and it treats this single-FAT device as partition 0.
        .logical_partition = false,
        .read_only = true,
        .write_caching = false,
        .block_size = part.dev.block_size,
        .io_align = 0,
        .last_block = if (part.num_blocks > 0) part.num_blocks - 1 else 0,
        .lowest_aligned_lba = 0,
        .logical_blocks_per_physical_block = 1,
        .optimal_transfer_length_granularity = 0,
    };
    part_proto = .{
        .revision = 1,
        .media = &part_media,
        ._reset = @ptrFromInt(@intFromPtr(&partReset)),
        ._read_blocks = @ptrFromInt(@intFromPtr(&partRead)),
        ._write_blocks = @ptrFromInt(@intFromPtr(&writeBlocks)),
        ._flush_blocks = @ptrFromInt(@intFromPtr(&flushBlocks)),
    };
    addProtocol(handle, &BlockIo.guid, @ptrCast(&part_proto));
}
