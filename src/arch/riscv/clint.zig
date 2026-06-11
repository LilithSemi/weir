//! CLINT (Core-Local Interruptor): machine timer and inter-hart software
//! interrupts. Thin adapter over conduit's clint driver; reads the base from
//! platform.clintBase() on each call so it follows runtime discovery.

const conduit = @import("conduit");
const platform = @import("../../platform.zig");

fn dev() conduit.driver.clint.Clint {
    return conduit.driver.clint.bind(conduit.Mmio.direct(platform.clintBase()));
}

/// Current value of the global timer.
pub fn time() u64 {
    return dev().time();
}

/// Program the machine timer compare for `hart`. A machine timer interrupt
/// fires once `time() >= value`.
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
