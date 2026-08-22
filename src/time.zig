//! Wall-clock time for the UEFI runtime services (GetTime / SetTime).
//!
//! When the platform has an RTC, time comes from it: GetTime reads it and
//! SetTime writes it. With no RTC, Weir keeps a software clock that starts at
//! the UNIX epoch (1970-01-01 UTC) and advances with the CLINT timer. SetTime
//! then syncs it, so an OS or a time agent can correct it. Weir keeps time in
//! UTC and does not track a timezone.

const conduit = @import("conduit");
const soc = @import("soc");
const clint = @import("arch/riscv/clint.zig");

pub const DateTime = conduit.device.Rtc.DateTime;

// The RTC, bound in init when the platform has one. Null selects the software
// clock. The goldfish instance is stored here so the Rtc ctx pointer stays valid.
var rtc: ?conduit.device.Rtc = null;
// zippy:ignore unsafe_undefined
var goldfish: conduit.driver.goldfish_rtc.Goldfish = undefined;

// Software clock: a UNIX-epoch base and the CLINT tick when it was set. The wall
// clock reads base_unix + (clint.time() - base_tick) / soc.timebase_hz.
var base_unix: i64 = 0;
var base_tick: u64 = 0;

pub fn init() void {
    if (soc.rtc_present) {
        goldfish = conduit.driver.goldfish_rtc.bind(conduit.Mmio.direct(soc.rtc_base));
        rtc = goldfish.rtc();
    } else {
        // No RTC. Start at the UNIX epoch and let SetTime sync the clock.
        base_unix = 0;
        base_tick = clint.time();
    }
}

/// Current wall-clock time (UTC).
pub fn now() DateTime {
    if (rtc) |r| return r.now();
    return conduit.device.Rtc.fromUnix(base_unix + elapsedSecs());
}

/// Set the wall-clock time (UTC). Writes the RTC when present, else syncs the
/// software clock. Returns false only when a present RTC is read-only.
pub fn set(dt: DateTime) bool {
    if (rtc) |r| return r.set(dt);
    base_unix = conduit.device.Rtc.toUnix(dt);
    base_tick = clint.time();
    return true;
}

fn elapsedSecs() i64 {
    const ticks = clint.time() -% base_tick;
    return @intCast(ticks / soc.timebase_hz);
}
