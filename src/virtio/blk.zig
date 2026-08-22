//! virtio-blk boot storage. A thin adapter over conduit's virtio_blk driver:
//! Weir probes the virtio-mmio transports the device tree declares (soc.zig) and
//! keeps the init()/device() surface its consumers expect, while the
//! transport/virtqueue logic lives once, in conduit. The device DMAs into the
//! module-level `dev`, at a stable address, so bind()+start() is safe here.

const conduit = @import("conduit");
const block = @import("../block/block.zig");
const soc = @import("soc");

// init() binds dev before any accessor reads it. bind() builds the full driver
// state, so zero-init would leave an invalid device.
var dev: conduit.driver.virtio_blk.Virtio = undefined; // zippy:ignore unsafe_undefined
var present = false;
var base_addr: usize = 0;

/// Probe the virtio-mmio slots for a block device and bring it up. Idempotent.
pub fn init() bool {
    if (present) return true;
    // Probe every virtio-mmio transport the device tree declares. A transport
    // with no device (or a non-block device) fails start(), so skip to the next.
    for (soc.virtio_devices) |vd| {
        dev = conduit.driver.virtio_blk.bind(conduit.Mmio.direct(vd.base));
        if (dev.start()) {
            present = true;
            base_addr = vd.base;
            return true;
        }
    }
    return false;
}

/// The MMIO base of the transport the block device bound to. Identifies the disk.
pub fn mmioBase() usize {
    return base_addr;
}

/// Disk capacity in 512-byte sectors.
pub fn capacity() u64 {
    return dev.capacity();
}

/// Present the disk as a generic block device for the partition/FS layers.
pub fn device() block.Device {
    return dev.block();
}
