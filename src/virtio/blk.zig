//! virtio-blk boot storage. A thin adapter over conduit's virtio_blk driver:
//! Weir keeps the QEMU virtio-mmio slot scan and the init()/device()/readImage()
//! surface its consumers expect, while the transport/virtqueue logic lives once,
//! in conduit. The device DMAs into the module-level `dev`, which is at a stable
//! address, so conduit's two-step bind()+start() is safe here.

const conduit = @import("conduit");
const block = @import("../block/block.zig");

// QEMU virt lays out 8 virtio-mmio transports at 0x1000_1000, 4 KiB apart.
const MMIO_BASE: usize = 0x10001000;
const MMIO_STRIDE: usize = 0x1000;
const MMIO_SLOTS: usize = 8;

var dev: conduit.driver.virtio_blk.Virtio = undefined;
var present = false;

/// Probe the virtio-mmio slots for a block device and bring it up. Idempotent.
pub fn init() bool {
    if (present) return true;
    var i: usize = 0;
    while (i < MMIO_SLOTS) : (i += 1) {
        const base = MMIO_BASE + i * MMIO_STRIDE;
        dev = conduit.driver.virtio_blk.bind(conduit.Mmio.direct(base));
        if (dev.start()) {
            present = true;
            return true;
        }
    }
    return false;
}

/// Disk capacity in 512-byte sectors.
pub fn capacity() u64 {
    return dev.capacity();
}

/// Present the disk as a generic block device for the partition/FS layers.
pub fn device() block.Device {
    return dev.block();
}

/// Read `len` bytes (rounded up to a sector) from the start of the disk into
/// `buf`. Returns the number of bytes read, or null on error.
pub fn readImage(buf: []u8, len: usize) ?usize {
    if (!present) return null;
    const d = dev.block();
    var sectors: u64 = (len + 511) / 512;
    if (sectors > d.num_blocks) sectors = d.num_blocks;
    if (sectors * 512 > buf.len) sectors = buf.len / 512;
    if (!d.readBlocks(0, @intCast(sectors), buf)) return null;
    return @intCast(sectors * 512);
}
