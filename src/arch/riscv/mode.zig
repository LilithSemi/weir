//! Privilege transitions. Today: M-mode -> S-mode handoff.

const csr = @import("csr.zig");
const cpu = @import("cpu.zig");
const console = @import("../../console/console.zig");

// Per-hart S-mode stacks for the payload. The firmware boot stack is small and
// shared with the M-mode trap path, so the handoff switches to a clean 1 MiB
// region; one per hart so secondaries never share the boot hart's stack.
const MAX_HARTS = 8;
var payload_stacks: [MAX_HARTS][1 << 20]u8 align(16) = undefined;

const MSTATUS_MPP_MASK: usize = 3 << 11;
const MSTATUS_MPP_S: usize = 1 << 11; // MPP = 0b01 (Supervisor)
const MSTATUS_MPIE: usize = 1 << 7;

const MIE_MSIE: usize = 1 << 3; // machine software (CLINT IPI relay)

// Exceptions delegated to S-mode: misaligned/access/page faults, breakpoints,
// illegal instruction, and ecall-from-U. ecall-from-S (9) and ecall-from-M (11)
// are deliberately left in M-mode so they reach the SBI handler.
const MEDELEG: usize = 0xb1ff;

// Interrupts delegated to S-mode: SSIP (1), STIP (5), SEIP (9).
const MIDELEG: usize = 0x222;

/// Diagnostic S-mode trap sink. Installed before handoff so an early fault in
/// the supervisor payload (before it sets its own stvec) is reported instead of
/// vanishing into a silent loop. A real payload overwrites stvec on entry.
export fn weirStrapReport() callconv(.c) noreturn {
    const ra = asm volatile ("mv %[r], ra"
        : [r] "=r" (-> usize),
    );
    const sp = asm volatile ("mv %[r], sp"
        : [r] "=r" (-> usize),
    );
    const scause = csr.read("scause");
    const sepc = csr.read("sepc");
    const stval = csr.read("stval");
    console.printf("\n[weir] unhandled S-mode trap: scause={x} sepc={x} stval={x}\n", .{ scause, sepc, stval });
    console.printf("[weir]   ra={x} sp={x}\n", .{ ra, sp });
    cpu.halt();
}

export fn weirStrapVector() align(4) callconv(.naked) noreturn {
    asm volatile ("tail weirStrapReport");
}

/// Drop to S-mode at `entry`, passing `hartid`/`dtb` in a0/a1 per the SBI
/// boot convention. Does not return.
pub fn enterSupervisor(entry: usize, hartid: usize, dtb: usize) noreturn {
    // Grant S/U-mode access to all physical memory via PMP entry 0 (TOR, RWX).
    // Without this, S-mode would fault on every access.
    csr.write("pmpaddr0", 0x3fffffffffffffff);
    csr.write("pmpcfg0", 0x0f);

    csr.write("medeleg", MEDELEG);
    csr.write("mideleg", MIDELEG);

    // Let S-mode read the time/cycle/instret counters (rdtime).
    csr.write("mcounteren", 0x7);

    // Enable the S-mode env features QEMU's virt CPU advertises. Without these in
    // menvcfg, S-mode use of the matching instructions traps as illegal even
    // though the ISA string claims them, and Linux probes the ISA and uses them
    // unconditionally (so it would Oops):
    //   STCE  (63) - Sstc: program the timer via stimecmp directly.
    //   PBMTE (62) - Svpbmt: page-based memory type bits in the PTE.
    //   CBZE  (7)  - Zicboz: cbo.zero, which clear_page() uses.
    //   CBCFE (6)  - Zicbom: cbo.clean / cbo.flush.
    //   CBIE  (5:4)- Zicbom: cbo.inval (0b11 = execute as flush).
    const MENVCFG_STCE: usize = 1 << 63;
    const MENVCFG_PBMTE: usize = 1 << 62;
    const MENVCFG_CBZE: usize = 1 << 7;
    const MENVCFG_CBCFE: usize = 1 << 6;
    const MENVCFG_CBIE: usize = 0b11 << 4;
    csr.write("menvcfg", MENVCFG_STCE | MENVCFG_PBMTE | MENVCFG_CBZE | MENVCFG_CBCFE | MENVCFG_CBIE);

    // Enable machine software interrupts so CLINT IPIs trap to M-mode (where we
    // relay them to S-mode as SSIP) while the hart runs in S-mode.
    csr.set("mie", MIE_MSIE);

    var mstatus = csr.read("mstatus");
    mstatus &= ~MSTATUS_MPP_MASK;
    mstatus |= MSTATUS_MPP_S;
    mstatus |= MSTATUS_MPIE;
    csr.write("mstatus", mstatus);

    // Diagnostic S-mode trap sink until the payload installs its own handler.
    csr.write("stvec", @intFromPtr(&weirStrapVector));

    csr.write("mepc", entry);

    // Hand the payload a clean, generous, 16-byte-aligned per-hart stack.
    const stack = &payload_stacks[hartid & (MAX_HARTS - 1)];
    const stack_top = (@intFromPtr(stack) + stack.len) & ~@as(usize, 15);

    // mret returns to mepc at privilege MPP, with a0/a1 carried into S-mode and
    // sp pointing at the dedicated payload stack.
    asm volatile (
        \\ mv sp, %[sp]
        \\ mret
        :
        : [sp] "r" (stack_top),
          [a0] "{a0}" (hartid),
          [a1] "{a1}" (dtb),
        : .{ .memory = true });
    unreachable;
}
