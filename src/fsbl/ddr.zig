//! DDR controller bring-up.
//!
//! Harbor's controller does JEDEC init in hardware, so the FSBL only does
//! CPU-driven read training on an ECP5: walk the read-tap delay, read the MPR
//! pattern (0xFFFF0000) back at each tap to find the valid eye, park the tap at
//! its centre. The MMIO control window sits above the DRAM array; its registers
//! are 8-byte strided: RDTAP_TARGET (0x00), CTL (0x08, bit0 = SET), RDSLACK
//! (0x10), STATUS (0x18, bit0 = busy, bits[8:1] = current tap). See Harbor
//! ddr.dart / ddr_train_test.dart.
//!
//! MPR DEPENDENCY (load-bearing, hard-won):
//!  1. The 0xFFFF0000 readback is only valid on an `mprDebug` bitstream, which
//!     pins the part in MPR (MR3) read mode (ddr_sequencer.dart).
//!  2. MR3 is fixed at elaboration, so firmware cannot toggle MPR; a non-mprDebug
//!     build returns ordinary data and the sweep finds no eye.
//!  3. On no-eye the FSBL halts rather than run from unvalidated DRAM (the caller
//!     treats a false return as fatal). On mprDebug OrangeCrab silicon the DELAYF
//!     taps are physical, so the sweep measures the true read eye.
//!  4. RDSLACK is left at its reset value, Harbor's proven static window position
//!     (s==0 opens at CL). Full tap-by-slack centering is future work needing a
//!     Harbor-side target value.

const uart = @import("uart");
const cfg = @import("config.zig");

const RDTAP_TARGET = 0x00;
const CTL = 0x08;
const STATUS = 0x18;
const CTL_SET: u32 = 0x1;

const MPR_PATTERN: u32 = 0xffff0000; // what a read returns in MPR mode
const MAX_TAP: u7 = 0x7f; // RDTAP_TARGET is 7-bit
const POLL_LIMIT = 1_000_000;

fn r32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
fn w32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// Walk the read tap to `tap` and wait until the controller is idle.
fn walkTap(tap: u7) void {
    w32(cfg.ddr_train_base + RDTAP_TARGET, tap);
    w32(cfg.ddr_train_base + CTL, CTL_SET);
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (r32(cfg.ddr_train_base + STATUS) & 0x1 == 0) break; // busy clear
    }
}

/// Does the part read back its MPR training pattern at the current tap?
fn tapPasses() bool {
    return r32(cfg.dram_base) == MPR_PATTERN;
}

/// Bring up DRAM: if the controller exposes a read-training window, find the
/// read eye and centre the tap. Returns true once dram_base is usable, false if
/// no valid eye was found (caller must not run from DRAM).
pub fn init(con: *uart.Ns16550a) bool {
    if (cfg.ddr_train_base == 0) {
        con.writeStr("[fsbl] ddr: hardware-initialised, no read training needed\n");
        return true;
    }

    // The longest contiguous run of passing taps is the read eye.
    var best_start: u7 = 0;
    var best_len: u9 = 0;
    var run_start: u7 = 0;
    var run_len: u9 = 0;
    var tap: u9 = 0;
    while (tap <= MAX_TAP) : (tap += 1) {
        walkTap(@intCast(tap));
        if (tapPasses()) {
            if (run_len == 0) run_start = @intCast(tap);
            run_len += 1;
            if (run_len > best_len) {
                best_len = run_len;
                best_start = run_start;
            }
        } else {
            run_len = 0;
        }
    }

    if (best_len == 0) {
        // No eye, or a non-mprDebug bitstream (see MPR DEPENDENCY above). Report
        // failure so the caller halts rather than trust unvalidated DRAM.
        con.writeStr("[fsbl] ddr: read training found no valid eye (mprDebug bitstream required)\n");
        return false;
    }
    const center: u7 = @intCast(best_start + best_len / 2);
    walkTap(center);
    // RDSLACK is intentionally left at its reset (the proven static slack).
    con.writeStr("[fsbl] ddr: read training centred the tap; DRAM ready\n");
    return true;
}
