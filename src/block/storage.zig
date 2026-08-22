//! Boot storage. Weir builds an ordered list of every block device the platform
//! has: virtio-blk (QEMU), then a Harbor SD/MMC host (River), then an SD card on
//! each SPI master the device tree declares. The boot manager walks the list and
//! boots the first device that holds a bootable ESP.

const soc = @import("soc");
const block = @import("block.zig");
const virtio = @import("../virtio/blk.zig");
const sdhci = @import("../drivers/sdhci.zig");
const sd_spi = @import("../drivers/sd_spi.zig");
const platform = @import("../platform.zig");

pub const Kind = enum { virtio, sdhci, sd_spi };

/// Human-facing identity for a device, the usual metadata a disk carries. SD and
/// MMC cards fill it from their CID register. A transport with no such register,
/// like virtio, leaves it unknown.
pub const Info = struct {
    pub const Date = struct { year: u16 = 0, month: u8 = 0 };
    pub const Revision = struct { major: u8 = 0, minor: u8 = 0 };
    /// SD manufacturer ID (CID byte 0). 0 means the device gave no identity.
    manufacturer_id: u8 = 0,
    /// OEM/application ID, 2 ASCII characters.
    oem: [2]u8 = .{ 0, 0 },
    /// Product name, 5 ASCII characters.
    product: [5]u8 = .{ 0, 0, 0, 0, 0 },
    /// Product revision (major.minor).
    revision: Revision = .{},
    /// Product serial number.
    serial: u32 = 0,
    /// Manufacture date. A year of 0 means unknown.
    date: Date = .{},

    /// True when the device reported identity metadata.
    pub fn known(self: Info) bool {
        return self.manufacturer_id != 0;
    }
    /// The manufacturer name for manufacturer_id, or "unknown".
    pub fn manufacturer(self: Info) []const u8 {
        return manufacturerName(self.manufacturer_id);
    }
};

/// One discovered block device, with the metadata the boot flow needs. Every
/// consumer walks the list `devices()` returns, so a virtio transport, a native
/// SD/MMC host, and an SD card in SPI mode all look the same. The device tree
/// alone decides which of these exist.
pub const Device = struct {
    kind: Kind,
    /// The generic block device the partition, filesystem, and image layers use.
    dev: block.Device,
    /// The controller's MMIO base, so a device path can identify the real disk.
    base: u64 = 0,
    /// Manufacturer, product, and date. Unknown for a transport with no such
    /// register, like virtio.
    info: Info = .{},
};

/// Well-known SD Card Association manufacturer IDs (CID byte 0).
fn manufacturerName(mid: u8) []const u8 {
    return switch (mid) {
        0x01 => "Panasonic",
        0x02 => "Toshiba/Kioxia",
        0x03 => "SanDisk",
        0x1b => "Samsung",
        0x1d => "ADATA",
        0x27 => "Phison",
        0x28 => "Lexar",
        0x31 => "Silicon Power",
        0x41 => "Kingston",
        0x74 => "Transcend",
        0x76 => "Patriot",
        0x82 => "Sony",
        0x9c => "Angelbird/Hoodman",
        else => "unknown",
    };
}

/// Build the generic Info from an SD/MMC CID. Every card kind (SPI or native)
/// shares this, so the identity fields decode in one place (conduit's device/sd).
fn infoFromCid(cid: sd_spi.Cid) Info {
    const rev = cid.revision();
    const date = cid.manufactureDate();
    return .{
        .manufacturer_id = cid.manufacturerId(),
        .oem = cid.oemId(),
        .product = cid.productName(),
        .revision = .{ .major = rev.major, .minor = rev.minor },
        .serial = cid.serialNumber(),
        .date = .{ .year = date.year, .month = date.month },
    };
}

// One SdSpi per SPI master, at a stable module address so each block device's
// ctx pointer stays valid. Array var-decls are filled before any read. The slice
// lets the probe loop index a runtime value even when no SPI master exists.
var spi_cards_arr: [soc.spi_count]sd_spi.SdSpi = undefined;
const spi_cards: []sd_spi.SdSpi = &spi_cards_arr;
// virtio transports + one per native SD/MMC host + one card per SPI master, all
// from the device tree. A build with no device tree declares no block device;
// the min of 1 keeps append() compilable (an index into a zero-length array is a
// compile error), and count_v stays 0 so devices() is still empty.
var entries: [@max(1, soc.virtio_count + soc.sdhci_count + soc.spi_count)]Device = undefined;
var count_v: usize = 0;
var inited = false;

fn append(dev_kind: Kind, dev: block.Device, base: u64, info: Info) void {
    entries[count_v] = .{ .kind = dev_kind, .dev = dev, .base = base, .info = info };
    count_v += 1;
}

/// Discover every block device, in boot order. Returns true if the platform has
/// at least one. Idempotent: the first call probes, later calls reuse the list.
pub fn init() bool {
    if (inited) return count_v > 0;
    inited = true;
    count_v = 0;

    // virtio-blk has no CID-style identity register, so it reports no metadata.
    if (virtio.init()) append(.virtio, virtio.device(), virtio.mmioBase(), .{});

    // Every native SD/MMC host the tree declares, probed in order. A `for` over
    // the slice is safe even when there are none. The host reads the card CID at
    // bring-up, so its identity metadata is populated too.
    for (soc.sdhci_controllers, 0..) |ctrl, idx| {
        if (sdhci.init(idx, ctrl.base, ctrl.freq))
            append(.sdhci, sdhci.device(idx), ctrl.base, infoFromCid(sdhci.cidInfo(idx)));
    }

    // Pair each SPI master with its card slot. A `for` over the slices is safe
    // even when the tree declares no SPI master.
    for (soc.spi_controllers, spi_cards) |ctrl, *slot| {
        switch (ctrl.ip) {
            .harbor => {
                slot.* = sd_spi.bind(ctrl.base, ctrl.dma);
                if (slot.cardPresent()) append(.sd_spi, slot.block(), ctrl.base, infoFromCid(slot.cidInfo()));
            },
        }
    }

    return count_v > 0;
}

/// Every discovered block device, in boot order. Call init() first. The boot
/// manager and the storage report both walk this one list, so no code needs to
/// know which transports the tree declared.
pub fn devices() []const Device {
    return entries[0..count_v];
}
