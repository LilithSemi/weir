//! Harbor SD/MMC boot storage. Thin adapter over conduit's harbor_sdio driver:
//! keeps the init/device/cardPresent surface storage.zig uses, while the SD init
//! sequence and the ADMA block transfers live once in conduit. One instance per
//! host lives in `devs`, at a stable module address so each block device's ctx
//! pointer stays valid (like the SPI cards in storage.zig).

const conduit = @import("conduit");
const soc = @import("soc");
const block = @import("../block/block.zig");
const clint = @import("../arch/riscv/clint.zig");

// One driver instance per native SD/MMC host. init() binds a slot before any
// accessor reads it. bind() builds the full driver state, so zero-init would
// leave an invalid device. A zero-length array when the platform has no host.
var devs: [soc.sdhci_count]conduit.driver.harbor_sdio.HarborSdio = undefined; // zippy:ignore unsafe_undefined

/// The SD/MMC CID accessor, shared with the SPI card path.
pub const Cid = conduit.driver.harbor_sdio.HarborSdio.Cid;

/// Bring up host `idx` and initialise the inserted card. Returns true on success.
pub fn init(idx: usize, host: soc.SdhciController) bool {
    devs[idx] = conduit.driver.harbor_sdio.bind(conduit.Mmio.direct(host.base), .{
        .freq = host.freq,
        .bus_width = if (host.bus_width == 1) .one else .four,
        .now_us = nowUs,
        .high_speed = host.high_speed,
        .max_hz = host.max_hz,
    });
    return devs[idx].cardPresent();
}

fn nowUs() u64 {
    const ticks_per_us = comptime @max(1, soc.timebase_hz / 1_000_000);
    return clint.time() / ticks_per_us;
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

/// The interrupt status and the card status of the last failed write on host
/// `idx`. The card status is 0xffffffff when the card did not answer.
pub fn fault(idx: usize) [2]u32 {
    if (soc.sdhci_count == 0) unreachable;
    const f = devs[idx].fault;
    return .{ f.int_status, f.card_status orelse 0xffff_ffff };
}

/// The bus mode of the card on host `idx`.
pub const Speed = struct { high_speed: bool, clock_hz: u32, bus_width: u8 };

pub fn speed(idx: usize) Speed {
    if (soc.sdhci_count == 0) unreachable;
    const dev = &devs[idx];
    return .{
        .high_speed = dev.in_high_speed,
        .clock_hz = dev.clock_hz,
        .bus_width = if (dev.bus_width == .four) 4 else 1,
    };
}
