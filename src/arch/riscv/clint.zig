//! CLINT (Core-Local Interruptor). It provides the machine timer and inter-hart
//! software interrupts. A thin adapter over conduit's clint driver. It reads the
//! base from platform.clintBase() on each call, so it follows runtime discovery.

const conduit = @import("conduit");
const platform = @import("../../platform.zig");

fn dev() conduit.driver.clint.Clint {
    return conduit.driver.clint.bind(conduit.Mmio.direct(platform.clintBase()));
}

/// True after M-mode confirms the Sstc extension is usable. menvcfg.STCE stays
/// set on readback. When false, set_timer must arm the machine timer through the
/// CLINT. The M-mode timer IRQ then relays to S-mode as STIP. A minimal core
/// without Sstc, like creek, needs that path. mode.enter() sets this once.
pub var sstc: bool = false;

/// Current value of the global timer.
pub fn time() u64 {
    return dev().time();
}

/// Program the machine timer compare for `hart`. A machine timer interrupt
/// fires when `time() >= value`.
pub fn setTimecmp(hart: usize, value: u64) void {
    dev().setTimecmp(hart, value);
}

/// Raise a machine software interrupt on `hart`.
pub fn sendIpi(hart: usize) void {
    dev().sendIpi(hart);
}

/// Acknowledge (clear) the machine software interrupt on `hart`.
pub fn clearIpi(hart: usize) void {
    dev().clearIpi(hart);
}
