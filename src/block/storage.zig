//! Boot storage selector: brings up the platform's block device behind the
//! generic block.Device interface. Tries virtio-blk (QEMU), then a Harbor SD/MMC
//! host (River, discovered from the DTB).

const block = @import("block.zig");
const virtio = @import("../virtio/blk.zig");
const sdhci = @import("../drivers/sdhci.zig");
const platform = @import("../platform.zig");

const Kind = enum { none, virtio, sdhci };
var active: Kind = .none;

/// Bring up the boot block device. Returns false if the platform has none.
pub fn init() bool {
    if (virtio.init()) {
        active = .virtio;
        return true;
    }
    const sb = platform.sdhciBase();
    if (sb != 0 and sdhci.init(sb, platform.sdhciFreq())) {
        active = .sdhci;
        return true;
    }
    return false;
}

pub fn device() block.Device {
    return switch (active) {
        .virtio => virtio.device(),
        .sdhci => sdhci.device(),
        .none => unreachable,
    };
}
