//! Inter-hart IPI mailbox.
//!
//! A CLINT software interrupt is a single bit, but it can mean several things:
//! relay a supervisor IPI (SSIP), run a remote FENCE.I, or a remote SFENCE.VMA.
//! Each hart has a pending-operation bitmask. A sender ORs in the ops it wants,
//! signals the target's MSIP, and, for fences, waits for the target to clear the
//! bits. This gives synchronous RFENCE semantics.

const clint = @import("../arch/riscv/clint.zig");

pub const MAX_HARTS = 8;

// Pending operation bits.
pub const SOFT: u32 = 1 << 0; // relay to S-mode as SSIP
pub const FENCE_I: u32 = 1 << 1; // execute FENCE.I locally
pub const SFENCE_VMA: u32 = 1 << 2; // execute SFENCE.VMA locally (full flush)

var pending: [MAX_HARTS]u32 = [_]u32{0} ** MAX_HARTS;

/// Queue `ops` on `target` and signal it. Fire-and-forget (used for SOFT relays).
pub fn send(target: usize, ops: u32) void {
    if (target >= MAX_HARTS) return;
    // Only the OR side effect matters here. The previous mask is not needed.
    _ = @atomicRmw(u32, &pending[target], .Or, ops, .release); // zippy:ignore discarded_error
    clint.sendIpi(target);
}

/// Queue `ops` on `target`, signal it, and wait until the target runs and clears
/// them. Synchronous, used for remote fences.
pub fn sendSync(target: usize, ops: u32) void {
    send(target, ops);
    while (@atomicLoad(u32, &pending[target], .acquire) & ops != 0) {}
}

/// Service this hart's mailbox: acknowledge the CLINT, run any requested fences,
/// then clear the processed bits. Returns true when an S-mode relay (SSIP) is
/// pending.
pub fn service(hartid: usize) bool {
    const ops = @atomicLoad(u32, &pending[hartid], .acquire);
    clint.clearIpi(hartid);

    if (ops & FENCE_I != 0) asm volatile ("fence.i" ::: .{ .memory = true });
    if (ops & SFENCE_VMA != 0) asm volatile ("sfence.vma" ::: .{ .memory = true });

    // Clear only the processed bits. A concurrent sender may have ORed in more.
    // The release order lets a waiting sender see completion after the fence.
    _ = @atomicRmw(u32, &pending[hartid], .And, ~ops, .release); // zippy:ignore discarded_error
    return (ops & SOFT) != 0;
}
