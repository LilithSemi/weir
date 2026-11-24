//! Harbor SD/MMC boot storage. Thin adapter over conduit's harbor_sdio driver:
//! keeps the init/device/cardPresent surface storage.zig uses, while the SD init
//! sequence and the ADMA block transfers live once in conduit. One instance per
//! host lives in `devs`, at a stable module address so each block device's ctx
//! pointer stays valid (like the SPI cards in storage.zig).

const conduit = @import("conduit");
const soc = @import("soc");
const block = @import("../block/block.zig");

// One driver instance per native SD/MMC host. init() binds a slot before any
// accessor reads it. bind() builds the full driver state, so zero-init would
// leave an invalid device. A zero-length array when the platform has no host.
var devs: [soc.sdhci_count]conduit.driver.harbor_sdio.HarborSdio = undefined; // zippy:ignore unsafe_undefined

/// The SD/MMC CID accessor, shared with the SPI card path.
pub const Cid = conduit.driver.harbor_sdio.HarborSdio.Cid;

/// Bring up host `idx` and initialise the inserted card. Returns true on success.
pub fn init(idx: usize, base: usize, freq: u32, bus_width: u32) bool {
    devs[idx] = conduit.driver.harbor_sdio.bind(conduit.Mmio.direct(base), .{
        .freq = freq,
        .bus_width = if (bus_width == 1) .one else .four,
    });
    return devs[idx].cardPresent();
}

/// Present host `idx`'s card as a generic block device for the partition/FS layers.
pub fn device(idx: usize) block.Device {
    return devs[idx].block();
}

pub fn cardPresent(idx: usize) bool {
    return devs[idx].cardPresent();
}

/// Host `idx`'s card identity, read from its CID at bring-up.
pub fn cidInfo(idx: usize) Cid {
    return devs[idx].cidInfo();
}

/// How to address the card on host `idx`.
pub const CardAddress = struct { rca: u32, high_capacity: bool };

/// The address data from bring-up, or null when the host has no card.
pub fn cardAddress(idx: usize) ?CardAddress {
    if (soc.sdhci_count == 0) return null;
    if (!devs[idx].cardPresent()) return null;
    return .{ .rca = devs[idx].rca, .high_capacity = devs[idx].high_capacity };
}
