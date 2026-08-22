//! Privilege transitions. Today this is the M-mode to S-mode handoff.

const csr = @import("csr.zig");
const cpu = @import("cpu.zig");
const clint = @import("clint.zig");
const console = @import("../../console/console.zig");

// Per-hart S-mode stacks for the payload. The firmware boot stack is small and
// shared with the M-mode trap path. So the handoff switches to a clean 1 MiB
// region. There is one per hart, so secondaries never share the boot hart's
// stack.
const MAX_HARTS = 8;
// In .noinit. The stacks hold no initial data, so the M-mode bss clear must not
// zero them. On the slow microcoded creek core, zeroing this 8 MiB cost about
// 55 s of boot.
var payload_stacks: [MAX_HARTS][1 << 20]u8 align(16) linksection(".noinit") = undefined;

const MSTATUS_MPP_MASK: usize = 3 << 11;
const MSTATUS_MPP_S: usize = 1 << 11; // MPP = 0b01 (Supervisor)
const MSTATUS_MPIE: usize = 1 << 7;

const MIE_MSIE: usize = 1 << 3; // machine software (CLINT IPI relay)

// Exceptions delegated to S-mode: instruction-misaligned/access/page faults,
// breakpoints, illegal instruction, and ecall-from-U. ecall-from-S (9) and
// ecall-from-M (11) are deliberately left in M-mode so they reach the SBI
// handler. Load-misaligned (4) and store-misaligned (6) are also left in M-mode:
// the core has no hardware misaligned access, so trap.zig emulates them, the
// same way OpenSBI does. Delegating them would drop the fault on a supervisor
// that expects hardware misalignment support.
const MEDELEG: usize = 0xb1af;

// Interrupts delegated to S-mode: SSIP (1), STIP (5), SEIP (9).
const MIDELEG: usize = 0x222;

/// Diagnostic S-mode trap sink. Weir installs it before handoff. An early fault
/// in the supervisor payload, before the payload sets its own stvec, gets
/// reported instead of vanishing into a silent loop. A real payload overwrites
/// stvec on entry.
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
    console.out.print(
        "\n[weir] unhandled S-mode trap: scause={x} sepc={x} stval={x}\n",
        .{ scause, sepc, stval },
    ) catch {};
    console.out.print("[weir]   ra={x} sp={x}\n", .{ ra, sp }) catch {};
    cpu.halt();
}

export fn weirStrapVector() align(4) callconv(.naked) noreturn {
    asm volatile ("tail weirStrapReport");
}

/// Runtime-probe whether CSR `name` is implemented on this hart.
///
/// A minimal M-mode core, like the creek River core, implements only the
/// baseline CSRs. Access to an absent one raises an illegal-instruction trap
/// (RISC-V priv spec). This reads the CSR under a temporary M-mode trap handler.
/// On such a trap, the handler steps mepc past the faulting `csrr` and reports
/// the CSR absent. It then restores the prior mtvec. CSR instructions have no
/// compressed form, so a trapped `csrr` is always 4 bytes wide. The read has no
/// side effects, so this is safe to call for any CSR.
///
/// The scratch registers are operand-allocated, not a clobber list. So the
/// inline trap handler and the surrounding code use the same physical registers.
inline fn csrImplemented(comptime name: []const u8) bool {
    var ok: usize = 1;
    // s0/s1/s2 are asm scratch outputs. Init to 0 keeps them defined for the
    // linter. The asm overwrites them before any Zig read.
    var s0: usize = 0;
    var s1: usize = 0;
    var s2: usize = 0;
    asm volatile (
        \\ la    %[s1], 1f
        \\ csrrw %[s0], mtvec, %[s1]   // install probe handler, save old mtvec
        \\ csrr  %[s2],
    ++ name ++
        \\
        \\ j     2f
        \\ .balign 4
        \\1:                            // trap sink: CSR absent
        \\ csrr  %[s1], mepc
        \\ addi  %[s1], %[s1], 4        // skip the 4-byte csrr
        \\ csrw  mepc, %[s1]
        \\ li    %[ok], 0
        \\ mret
        \\2:
        \\ csrw  mtvec, %[s0]           // restore prior handler
        : [ok] "+r" (ok),
          [s0] "=&r" (s0),
          [s1] "=&r" (s1),
          [s2] "=&r" (s2),
        :
        : .{ .memory = true });
    return ok != 0;
}

/// Drop to S-mode at `entry`, passing `hartid`/`dtb` in a0/a1 per the SBI
/// boot convention. Does not return.
pub fn enterSupervisor(entry: usize, hartid: usize, dtb: usize) noreturn {
    // Grant S/U-mode access to all physical memory via PMP entry 0 (TOR, RWX).
    // Without this, S-mode would fault on every access. A PMP-less core grants
    // full access by default and traps the csrw as illegal, so probe first.
    if (csrImplemented("pmpaddr0")) {
        csr.write("pmpaddr0", 0x3fffffffffffffff);
        csr.write("pmpcfg0", 0x0f);
    }

    // Delegate illegal-instruction (bit 2) to S-mode only when the core has the
    // `time` counter CSR. Without it, an S-mode rdtime traps as illegal and must
    // reach M-mode. trapHandler then emulates it from the CLINT. A delegated
    // trap would go to the supervisor, which cannot service it.
    var medeleg = MEDELEG;
    if (!csrImplemented("time")) medeleg &= ~@as(usize, 1 << 2);
    csr.write("medeleg", medeleg);
    csr.write("mideleg", MIDELEG);

    // Let S-mode read the time/cycle/instret counters (rdtime). Absent on a core
    // without the counter facility. There the csrw would trap.
    if (csrImplemented("mcounteren")) csr.write("mcounteren", 0x7);

    // Enable the S-mode env features that QEMU's virt CPU advertises. Without
    // these in menvcfg, S-mode use of the matching instructions traps as
    // illegal, even though the ISA string claims them. Linux probes the ISA and
    // uses them without a guard, so it would Oops.
    //   STCE  (63): Sstc, program the timer through stimecmp directly.
    //   PBMTE (62): Svpbmt, page-based memory type bits in the PTE.
    //   CBZE  (7):  Zicboz, cbo.zero, which clear_page() uses.
    //   CBCFE (6):  Zicbom, cbo.clean and cbo.flush.
    //   CBIE  (5:4): Zicbom, cbo.inval (0b11 runs as flush).
    // menvcfg is a Priv-1.12 CSR that a minimal core need not implement. A write
    // there traps. The gated features (Sstc, Svpbmt, Zicbo*) are absent from
    // such a core's ISA anyway, so a payload must not rely on them.
    if (csrImplemented("menvcfg")) {
        const MENVCFG_STCE: usize = 1 << 63;
        const MENVCFG_PBMTE: usize = 1 << 62;
        const MENVCFG_CBZE: usize = 1 << 7;
        const MENVCFG_CBCFE: usize = 1 << 6;
        const MENVCFG_CBIE: usize = 0b11 << 4;
        const menvcfg = MENVCFG_STCE | MENVCFG_PBMTE | MENVCFG_CBZE | MENVCFG_CBCFE | MENVCFG_CBIE;
        csr.write("menvcfg", menvcfg);
        // STCE is WARL. It only sticks on a hart that implements Sstc. Read it
        // back so set_timer knows whether it may write stimecmp directly, or
        // must fall back to the CLINT machine timer and the STIP relay. A minimal
        // core like creek reads STCE back as 0, or never implements menvcfg.
        clint.sstc = (csr.read("menvcfg") & MENVCFG_STCE) != 0;
    }

    // Enable machine software interrupts so CLINT IPIs trap to M-mode while the
    // hart runs in S-mode. M-mode then relays them to S-mode as SSIP.
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

    // The payload stack is .noinit, so on real DRAM it starts as garbage. A
    // payload (or a Weir boot-service callback that runs on this stack) that reads
    // an uninitialised slot then gets a wild value: harmless as 0, but on hardware
    // it occasionally wrote onto a systemd-boot stack canary and tripped a rare
    // "Stack check failed". QEMU zero-fills RAM, which is exactly why it never
    // reproduced there. Zero the stack here so hardware matches that known-good
    // behaviour and the boot is deterministic. Costs one memset per boot hart.
    @memset(stack[0..], 0);
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
