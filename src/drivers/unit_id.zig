//! Harbor unit ID block: a number from the FPGA that is different for each unit.

const soc = @import("soc");

const id_lo = 0x00;
const id_hi = 0x08;
const info = 0x10;
const info_valid: u32 = 1 << 0;

fn reg(base: usize, off: usize) u32 {
    const ptr: *const volatile u32 = @ptrFromInt(base + off);
    return ptr.*;
}

/// The ID of this unit. Null when the board has no ID block or the block has
/// no valid ID.
pub fn read() ?u64 {
    const base = soc.unit_id_base orelse return null;
    if (reg(base, info) & info_valid == 0) return null;
    return @as(u64, reg(base, id_hi)) << 32 | reg(base, id_lo);
}
