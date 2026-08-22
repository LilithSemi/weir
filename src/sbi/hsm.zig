//! SBI Hart State Management (HSM): start, stop, and query secondary harts.
//!
//! Secondary harts park in `wait` (M-mode, STOPPED). `hartStart` records an
//! entry point, sets the target to START_PENDING, and sends it a CLINT IPI.
//! The woken hart drops into S-mode at that entry.

const csr = @import("../arch/riscv/csr.zig");
const clint = @import("../arch/riscv/clint.zig");
const mode = @import("../arch/riscv/mode.zig");
const ipi = @import("ipi.zig");

pub const MAX_HARTS = 8;

// SBI HSM hart states (also the values returned by hart_get_status).
const STARTED: u32 = 0;
const STOPPED: u32 = 1;
const START_PENDING: u32 = 2;

// SBI error codes.
const ERR_FAILED: usize = errCode(-1);
const ERR_INVALID_PARAM: usize = errCode(-3);
const ERR_ALREADY_AVAILABLE: usize = errCode(-6);

fn errCode(comptime v: isize) usize {
    return @bitCast(@as(isize, v));
}

const MIE_MSIE: usize = 1 << 3;

const Hart = struct {
    state: u32,
    start_addr: usize,
    opaque_arg: usize,
};

var harts: [MAX_HARTS]Hart = undefined;

/// Boot-hart only: initialise the hart table (boot hart STARTED, rest STOPPED).
pub fn init(boot_hart: usize) void {
    for (&harts, 0..) |*h, i| {
        h.* = .{
            .state = if (i == boot_hart) STARTED else STOPPED,
            .start_addr = 0,
            .opaque_arg = 0,
        };
    }
}

/// SBI hart_start. Returns an SBI error code (0 on success).
pub fn hartStart(target: usize, start_addr: usize, opaque_arg: usize) usize {
    if (target >= MAX_HARTS) return ERR_INVALID_PARAM;

    harts[target].start_addr = start_addr;
    harts[target].opaque_arg = opaque_arg;

    // Claim the hart: only a STOPPED hart can be started. The seq_cst exchange
    // publishes start_addr/opaque_arg to the target's acquire load.
    const prev = @cmpxchgStrong(
        u32,
        &harts[target].state,
        STOPPED,
        START_PENDING,
        .seq_cst,
        .seq_cst,
    );
    if (prev) |s| {
        return if (s == STARTED) ERR_ALREADY_AVAILABLE else ERR_FAILED;
    }

    clint.sendIpi(target);
    return 0;
}

/// SBI hart_stop. Marks the calling hart STOPPED and parks it. Never returns.
pub fn hartStop() noreturn {
    const hartid = csr.read("mhartid");
    @atomicStore(u32, &harts[hartid].state, STOPPED, .release);
    wait(hartid);
}

/// SBI hart_get_status. Returns the state, or null for an invalid hart id.
pub fn hartStatus(target: usize) ?usize {
    if (target >= MAX_HARTS) return null;
    return @atomicLoad(u32, &harts[target].state, .acquire);
}

/// M-mode parking loop for a stopped hart. It wakes on a CLINT IPI. Once
/// started, it drops into S-mode at the requested entry. Never returns.
pub fn wait(hartid: usize) noreturn {
    csr.set("mie", MIE_MSIE); // let wfi wake on a software interrupt
    while (true) {
        asm volatile ("wfi");
        // Drain the mailbox: a remote fence aimed at this stopped hart runs as
        // a no-op here but must clear so the sender's sync wait completes.
        _ = ipi.service(hartid); // zippy:ignore discarded_error -- stopped hart has no S-mode relay
        if (@atomicLoad(u32, &harts[hartid].state, .acquire) == START_PENDING) {
            const addr = harts[hartid].start_addr;
            const arg = harts[hartid].opaque_arg;
            @atomicStore(u32, &harts[hartid].state, STARTED, .release);
            mode.enterSupervisor(addr, hartid, arg);
        }
    }
}
