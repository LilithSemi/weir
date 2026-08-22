//! Handoff record the FSBL leaves for main Weir in DRAM.
//!
//! For a real root of trust, the FSBL measures the main firmware into PCR 0
//! before it runs, not Weir. The FSBL records the digest here. Main Weir then
//! logs that exact event into the TCG2 log, instead of measuring itself. A
//! self-measure would leave PCR 0 unaccounted for in the log.
//!
//! The record lives in the last page of the reserved firmware region, above
//! Weir's image and stacks, so neither stage clobbers it. The main and FSBL
//! builds share it.

/// "WFSB" little-endian. Marks a valid FSBL handoff.
pub const MAGIC: u32 = 0x42534657;

/// Offset of the record within the firmware's RAM region.
pub const OFFSET: usize = 0x01fff000;

pub const Record = extern struct {
    magic: u32,
    pcr0_valid: u32,
    pcr0_digest: [32]u8,
};

pub fn record(ram_base: usize) *volatile Record {
    return @ptrFromInt(ram_base + OFFSET);
}

/// Read side. Return the FSBL's PCR 0 digest if it measured Weir, else null.
pub fn fsblPcr0(ram_base: usize) ?[32]u8 {
    const r: *const Record = @ptrFromInt(ram_base + OFFSET);
    if (r.magic == MAGIC and r.pcr0_valid != 0) return r.pcr0_digest;
    return null;
}
