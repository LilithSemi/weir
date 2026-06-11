//! Harbor SD/MMC boot storage. Thin adapter over conduit's sdhci driver: keeps
//! the init/device/cardPresent surface storage.zig uses, while the SD init
//! sequence and PIO live once in conduit. The block device's ctx points at the
//! module-level `dev` for a stable address.

const conduit = @import("conduit");
const block = @import("../block/block.zig");

var dev: conduit.driver.sdhci.Sdhci = undefined;

/// Bring up the host and initialise the inserted card. Returns true on success.
pub fn init(base: usize, freq: u32) bool {
    dev = conduit.driver.sdhci.bind(conduit.Mmio.direct(base), .{ .freq = freq });
    return dev.cardPresent();
}

/// Present the SD card as a generic block device for the partition/FS layers.
pub fn device() block.Device {
    return dev.block();
}

pub fn cardPresent() bool {
    return dev.cardPresent();
}
