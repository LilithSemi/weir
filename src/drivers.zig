//! Harbor peripheral drivers. conduit provides them, and Weir re-exports them
//! for its River boot path. The register interfaces live once, in conduit's
//! driver tree. The SD/SDIO host keeps a thin Weir-side adapter in
//! drivers/sdhci.zig for the generic block.Device and a module-level init.

const conduit = @import("conduit");

pub const gpio = conduit.driver.harbor_gpio;
pub const spi = conduit.driver.harbor_spi;
pub const i2c = conduit.driver.harbor_i2c;
pub const sdio = @import("drivers/sdhci.zig");
/// Deprecated spelling of [sdio]. The controller is Harbor's own register map,
/// not the SD Host Controller Standard one.
pub const sdhci = sdio;
