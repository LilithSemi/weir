//! Inter-hart IPI mailbox.
//!
//! A CLINT software interrupt is a single bit, but it can mean several things:
//! relay a supervisor IPI (SSIP), execute a remote FENCE.I, or a remote
//! SFENCE.VMA. Each hart has a pending-operation bitmask; a sender ORs in the
//! ops it wants, pokes the target's MSIP, and (for fences) waits for the target
//! to clear the bits, giving synchronous RFENCE semantics.

const csr = @import("../arch/riscv/csr.zig");
const clint = @import("../arch/riscv/clint.zig");

pub const MAX_HARTS = 8;

// Pending operation bits.
pub const SOFT: u32 = 1 << 0; // relay to S-mode as SSIP
pub const FENCE_I: u32 = 1 << 1; // execute FENCE.I locally
pub const SFENCE_VMA: u32 = 1 << 2; // execute SFENCE.VMA locally (full flush)

var pending: [MAX_HARTS]u32 = [_]u32{0} ** MAX_HARTS;

/// Queue `ops` on `target` and poke it. Fire-and-forget (used for SOFT relays).
pub fn send(target: usize, ops: u32) void {
    if (target >= MAX_HARTS) return;
    _ = @atomicRmw(u32, &pending[target], .Or, ops, .release);
    clint.sendIpi(target);
}

/// Queue `ops` on `target`, poke it, and wait until it has executed and cleared
/// them. Synchronous: used for remote fences.
pub fn sendSync(target: usize, ops: u32) void {
    send(target, ops);
    while (@atomicLoad(u32, &pending[target], .acquire) & ops != 0) {}
}

/// Service this hart's mailbox: ack the CLINT, run any requested fences, then
/// clear those bits. Returns true if an S-mode relay (SSIP) was requested.
pub fn service(hartid: usize) bool {
    const ops = @atomicLoad(u32, &pending[hartid], .acquire);
    clint.clearIpi(hartid);

    if (ops & FENCE_I != 0) asm volatile ("fence.i" ::: .{ .memory = true });
    if (ops & SFENCE_VMA != 0) asm volatile ("sfence.vma" ::: .{ .memory = true });

    // Clear exactly the bits we processed (a concurrent sender may have ORed in
    // more), releasing so a waiting sender observes completion after the fence.
    _ = @atomicRmw(u32, &pending[hartid], .And, ~ops, .release);
    return (ops & SOFT) != 0;
}
