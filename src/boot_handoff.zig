//! Handoff record the FSBL leaves for main Weir in DRAM.
//!
//! For a real root of trust the FSBL (not Weir) measures the main firmware into
//! PCR 0 before running it, recording the digest here so main Weir logs that
//! exact event into the TCG2 log instead of re-measuring itself (which would
//! leave PCR 0 unaccounted for in the log).
//!
//! Lives in the last page of the reserved firmware region, above Weir's image
//! and stacks, so neither stage clobbers it. Shared by main and FSBL builds.

/// "WFSB" little-endian: marks a valid FSBL handoff.
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

/// Read side: return the FSBL's PCR 0 digest if it measured us, else null.
pub fn fsblPcr0(ram_base: usize) ?[32]u8 {
    const r: *const Record = @ptrFromInt(ram_base + OFFSET);
    if (r.magic == MAGIC and r.pcr0_valid != 0) return r.pcr0_digest;
    return null;
}
