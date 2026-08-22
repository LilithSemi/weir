//! Harbor SD-in-SPI adapter. Weir binds conduit's sd_spi driver over a Harbor
//! SPI master at a raw MMIO base. A board can wire more than one SPI master, so
//! this module is instance-oriented: `bind` returns one card and storage.zig
//! owns the instances at stable addresses. The card exposes a generic block
//! device and its identification data through methods on the returned value.

const conduit = @import("conduit");

pub const SdSpi = conduit.driver.sd_spi.SdSpi;
/// The SD/MMC CID accessor (manufacturer, product, serial, date). Shared with
/// the native SD host, so storage.zig fills one Info from either.
pub const Cid = SdSpi.Cid;
pub const Date = Cid.Date;

// DMA block reads. The earlier LBA1+ corruption traced to the marginal 33 MHz
// core clock (SPI mis-execution); at the reliable lower clock the DMA read path
// is sound and it removes the per-byte PIO overhead that dominates a slow core.
const force_pio = false;

/// Bind the SPI master at `base` and run the SD identification sequence. Read
/// `cardPresent()` on the result to learn whether a card answered. Set `dma` when
/// the controller has the block DMA engine, so block reads use it over the poll.
pub fn bind(base: usize, dma: bool) SdSpi {
    return conduit.driver.sd_spi.bind(conduit.Mmio.direct(base), .{ .dma = dma and !force_pio });
}
