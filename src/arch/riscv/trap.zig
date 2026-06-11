//! M-mode trap entry and handler.
//!
//! `trapVector` saves the integer register file, calls `trapHandler`, then
//! restores and `mret`s. Today it services ecalls (routed to SBI) and reports
//! anything unexpected.

const csr = @import("csr.zig");
const cpu = @import("cpu.zig");
const sbi = @import("../../sbi/sbi.zig");
const ipi = @import("../../sbi/ipi.zig");
const console = @import("../../console/console.zig");

/// Saved integer registers, indexed by register number (x0 slot unused).
pub const TrapFrame = extern struct {
    x: [32]usize,
};

// mcause exception codes.
const CAUSE_ECALL_U = 8;
const CAUSE_ECALL_S = 9;
const CAUSE_ECALL_M = 11;

// mcause interrupt codes (top bit set).
const IRQ_M_SOFT = 3;
const IRQ_M_TIMER = 7;

// mie / mip bits.
const MIE_MTIE: usize = 1 << 7;
const MIP_SSIP: usize = 1 << 1;
const MIP_STIP: usize = 1 << 5;

pub export fn trapVector() align(4) linksection(".text") callconv(.naked) void {
    asm volatile (
    // Switch to the private M-mode trap stack: sp <- mscratch (stack top),
    // mscratch <- the interrupted sp. The interrupted context may be a paging-
    // enabled supervisor whose sp is a virtual address unusable in M-mode.
        \\ csrrw sp, mscratch, sp
        \\ addi sp, sp, -256
        \\ sd x1,  8(sp)
        \\ sd x3,  24(sp)
        \\ sd x4,  32(sp)
        \\ sd x5,  40(sp)
        \\ sd x6,  48(sp)
        \\ sd x7,  56(sp)
        \\ sd x8,  64(sp)
        \\ sd x9,  72(sp)
        \\ sd x10, 80(sp)
        \\ sd x11, 88(sp)
        \\ sd x12, 96(sp)
        \\ sd x13, 104(sp)
        \\ sd x14, 112(sp)
        \\ sd x15, 120(sp)
        \\ sd x16, 128(sp)
        \\ sd x17, 136(sp)
        \\ sd x18, 144(sp)
        \\ sd x19, 152(sp)
        \\ sd x20, 160(sp)
        \\ sd x21, 168(sp)
        \\ sd x22, 176(sp)
        \\ sd x23, 184(sp)
        \\ sd x24, 192(sp)
        \\ sd x25, 200(sp)
        \\ sd x26, 208(sp)
        \\ sd x27, 216(sp)
        \\ sd x28, 224(sp)
        \\ sd x29, 232(sp)
        \\ sd x30, 240(sp)
        \\ sd x31, 248(sp)
        \\ csrr t0, mscratch
        \\ sd t0, 16(sp)
        \\ addi t0, sp, 256
        \\ csrw mscratch, t0
        \\ mv a0, sp
        \\ call trapHandler
        \\ ld x1,  8(sp)
        \\ ld x3,  24(sp)
        \\ ld x4,  32(sp)
        \\ ld x5,  40(sp)
        \\ ld x6,  48(sp)
        \\ ld x7,  56(sp)
        \\ ld x8,  64(sp)
        \\ ld x9,  72(sp)
        \\ ld x10, 80(sp)
        \\ ld x11, 88(sp)
        \\ ld x12, 96(sp)
        \\ ld x13, 104(sp)
        \\ ld x14, 112(sp)
        \\ ld x15, 120(sp)
        \\ ld x16, 128(sp)
        \\ ld x17, 136(sp)
        \\ ld x18, 144(sp)
        \\ ld x19, 152(sp)
        \\ ld x20, 160(sp)
        \\ ld x21, 168(sp)
        \\ ld x22, 176(sp)
        \\ ld x23, 184(sp)
        \\ ld x24, 192(sp)
        \\ ld x25, 200(sp)
        \\ ld x26, 208(sp)
        \\ ld x27, 216(sp)
        \\ ld x28, 224(sp)
        \\ ld x29, 232(sp)
        \\ ld x30, 240(sp)
        \\ ld x31, 248(sp)
        \\ ld sp, 16(sp)
        \\ mret
    );
}

export fn trapHandler(frame: *TrapFrame) callconv(.c) void {
    const mcause = csr.read("mcause");
    const is_interrupt = (mcause >> (@bitSizeOf(usize) - 1)) != 0;
    const code = mcause & 0xfff;

    if (is_interrupt) {
        switch (code) {
            // Machine timer: a timer device interrupt is M-mode only, so relay
            // it to S-mode as STIP and stop the machine timer (set_timer will
            // re-arm it). mepc is untouched: we resume the interrupted code.
            IRQ_M_TIMER => {
                csr.clear("mie", MIE_MTIE);
                csr.set("mip", MIP_STIP);
            },
            // Machine software (IPI): service the mailbox (remote fences run
            // here); relay to S-mode as SSIP only if a supervisor IPI was asked.
            IRQ_M_SOFT => {
                if (ipi.service(csr.read("mhartid"))) csr.set("mip", MIP_SSIP);
            },
            else => reportFatal(mcause),
        }
        return;
    }

    if (code == CAUSE_ECALL_M or code == CAUSE_ECALL_S or code == CAUSE_ECALL_U) {
        const eid = frame.x[17]; // a7
        const fid = frame.x[16]; // a6
        const args = frame.x[10..16].*; // a0..a5
        const ret = sbi.dispatch(eid, fid, args);
        frame.x[10] = ret.err; // a0
        frame.x[11] = ret.val; // a1
        csr.write("mepc", csr.read("mepc") + 4);
        return;
    }

    reportFatal(mcause);
}

fn reportFatal(mcause: usize) noreturn {
    console.printf(
        "\n[weir] unhandled trap: mcause={x} mepc={x} mtval={x}\n",
        .{ mcause, csr.read("mepc"), csr.read("mtval") },
    );
    cpu.halt();
}
