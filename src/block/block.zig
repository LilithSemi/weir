//! Generic block-device abstraction.
//!
//! `Device` is conduit's `Block` contract (a vtable over anything that reads
//! fixed-size logical blocks: virtio-blk, SDHCI, ...). Re-exported so Weir's
//! consumers keep their `block.Device` type while the contract lives once, in
//! conduit.

const conduit = @import("conduit");

pub const Device = conduit.device.Block;

/// A view over a sub-range of a Device (e.g. one partition), so filesystems read
/// without knowing the partition's absolute placement on the disk.
pub const Partition = struct {
    dev: *const Device,
    base_lba: u64,
    num_blocks: u64,
    /// 1-based partition number and the GPT unique partition GUID, used to build
    /// the Hard Drive device path node so a bootloader can match its boot volume.
    number: u32 = 1,
    signature: [16]u8 = .{0} ** 16,

    pub fn blockSize(self: *const Partition) u32 {
        return self.dev.block_size;
    }

    /// Read `count` blocks relative to the partition start.
    pub fn readBlocks(self: *const Partition, lba: u64, count: u32, buf: []u8) bool {
        if (lba + count > self.num_blocks) return false;
        return self.dev.readBlocks(self.base_lba + lba, count, buf);
    }
};
