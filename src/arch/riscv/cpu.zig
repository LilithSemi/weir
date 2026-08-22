//! Low-level RISC-V CPU primitives shared across the firmware.

/// Wait for an interrupt. Hint that the hart can idle until the next one fires.
pub inline fn wfi() void {
    asm volatile ("wfi");
}

/// Park the hart forever. This is the single stop-here sink. Panics, unhandled
/// traps, post-shutdown, and an exhausted boot all converge here.
pub fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
