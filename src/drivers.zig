//! Harbor peripheral drivers, provided by conduit and re-exported for Weir's
//! River boot path. Register interfaces live once in conduit's driver/ tree;
//! SDHCI keeps a thin Weir-side adapter (drivers/sdhci.zig) for the generic
//! block.Device and a module-level init.

const conduit = @import("conduit");

pub const gpio = conduit.driver.harbor_gpio;
pub const spi = conduit.driver.harbor_spi;
pub const i2c = conduit.driver.harbor_i2c;
pub const sdhci = @import("drivers/sdhci.zig");
