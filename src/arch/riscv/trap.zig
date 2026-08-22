//! M-mode trap entry and handler.
//!
//! `trapVector` saves the integer register file, calls `trapHandler`, then
//! restores and `mret`s. Today it services ecalls, routed to SBI, and reports
//! anything unexpected.

const csr = @import("csr.zig");
const cpu = @import("cpu.zig");
const clint = @import("clint.zig");
const sbi = @import("../../sbi/sbi.zig");
const ipi = @import("../../sbi/ipi.zig");
const console = @import("../../console/console.zig");

/// Saved integer registers, indexed by register number (x0 slot unused).
pub const TrapFrame = extern struct {
    x: [32]usize,
};

// mcause exception codes.
const CAUSE_ILLEGAL_INSTRUCTION = 2;
const CAUSE_MISALIGNED_LOAD = 4;
const CAUSE_MISALIGNED_STORE = 6;
const CAUSE_ECALL_U = 8;
const CAUSE_ECALL_S = 9;
const CAUSE_ECALL_M = 11;

// The `time` counter CSR (0xC01). On a core that omits it, an S-mode `rdtime`
// traps here as illegal, and Weir serves it from the CLINT machine timer.
const CSR_TIME = 0xc01;

// mcause interrupt codes (top bit set).
const IRQ_M_SOFT = 3;
const IRQ_M_TIMER = 7;

// mie / mip bits.
const MIE_MTIE: usize = 1 << 7;
const MIP_SSIP: usize = 1 << 1;
const MIP_STIP: usize = 1 << 5;

pub export fn trapVector() align(4) linksection(".text") callconv(.naked) void {
    asm volatile (
    // Switch to the private M-mode trap stack. sp takes mscratch (the stack
    // top), and mscratch takes the interrupted sp. The interrupted context may
    // be a paging-enabled supervisor whose sp is a virtual address, unusable in
    // M-mode.
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
            // Machine timer. A timer device interrupt is M-mode only. So relay
            // it to S-mode as STIP and stop the machine timer. set_timer re-arms
            // it later. mepc stays untouched, so the interrupted code resumes.
            IRQ_M_TIMER => {
                csr.clear("mie", MIE_MTIE);
                csr.set("mip", MIP_STIP);
            },
            // Machine software IPI. Service the mailbox, where remote fences
            // run. Relay to S-mode as SSIP only when a supervisor IPI was asked
            // for.
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

    // Illegal instruction from a lower privilege. mode.zig delegates this to
    // S-mode on a core that has the counter CSRs. So Weir only reaches here when
    // the core omits them. Emulate a `time` read (rdtime) from the CLINT. Hand
    // anything else back to the supervisor, as if it had been delegated.
    if (code == CAUSE_ILLEGAL_INSTRUCTION) {
        if (emulateTimeRead(frame)) return;
        redirectToSupervisor();
        return;
    }

    // Misaligned load or store from a lower privilege. The core does not do
    // misaligned access in hardware, so mode.zig keeps these in M-mode
    // (medeleg clears bits 4 and 6) and Weir emulates them, like OpenSBI. Hand
    // an instruction it does not decode (for example a float access) back to
    // the supervisor.
    if (code == CAUSE_MISALIGNED_LOAD or code == CAUSE_MISALIGNED_STORE) {
        if (emulateMisaligned(frame, code == CAUSE_MISALIGNED_STORE)) return;
        redirectToSupervisor();
        return;
    }

    reportFatal(mcause);
}

/// Serve an S/U-mode read of the `time` counter that trapped because the core
/// omits the CSR. Returns false for any instruction that is not a `time` CSR
/// read, so the caller redirects it to the supervisor unchanged.
fn emulateTimeRead(frame: *TrapFrame) bool {
    // The payload runs with paging off (Bare), so mepc is a physical address
    // that the M-mode handler reads directly. mepc is only 2-byte aligned,
    // because the trapped csrr can follow a compressed op. This core faults on a
    // misaligned 4-byte load, so read the 4-byte instruction as two aligned
    // halfwords.
    const mepc = csr.read("mepc");
    // mepc is the trapped context's PC, a supervisor virtual address once Linux
    // enables paging, so translate it before the read (see emulateMisaligned).
    const lo = @as(*const u16, @ptrFromInt(translateVaddr(mepc))).*;
    const hi = @as(*const u16, @ptrFromInt(translateVaddr(mepc + 2))).*;
    const instr = @as(u32, lo) | (@as(u32, hi) << 16);
    if (instr & 0x7f != 0x73) return false; // not the SYSTEM opcode
    const funct3 = (instr >> 12) & 0x7;
    if (funct3 == 0 or funct3 == 4) return false; // ecall/ebreak, not a CSR op
    if ((instr >> 20) & 0xfff != CSR_TIME) return false;
    const rd = (instr >> 7) & 0x1f;
    if (rd != 0) frame.x[rd] = clint.time();
    csr.write("mepc", mepc + 4);
    return true;
}

/// Translate a supervisor virtual address to a physical address through the
/// active satp. The misaligned emulator runs in M-mode with paging off, so the
/// faulting address (a supervisor virtual address in mtval) must be walked to
/// find the memory the trapped access meant. Returns the input unchanged when
/// paging is off (Bare) or the walk finds no valid leaf, which keeps the old
/// direct-physical behaviour for an identity-mapped range. Sv39 only; delta
/// uses no wider mode.
fn translateVaddr(vaddr: usize) usize {
    const satp = csr.read("satp");
    const mode = satp >> 60; // RV64 satp MODE, bits [63:60]. 0 = Bare, 8 = Sv39.
    if (mode != 8) return vaddr;

    var table = (satp & ((1 << 44) - 1)) << 12; // root table physical base
    const vpn = [3]usize{
        (vaddr >> 12) & 0x1ff,
        (vaddr >> 21) & 0x1ff,
        (vaddr >> 30) & 0x1ff,
    };

    var level: usize = 3;
    while (level > 0) {
        level -= 1;
        // Page-table entries are eight bytes and eight-byte aligned, so this
        // read is aligned and does not itself trap.
        const pte = @as(*const u64, @ptrFromInt(table + vpn[level] * 8)).*;
        if ((pte & 1) == 0) return vaddr; // V clear: not mapped, fall back
        const ppn = (pte >> 10) & ((1 << 44) - 1);
        if ((pte & 0b1010) != 0) {
            // R or X set: a leaf. A megapage takes its low bits from the input.
            const off_bits: u6 = @intCast(12 + 9 * level);
            const low_mask = (@as(usize, 1) << off_bits) - 1;
            return ((ppn << 12) & ~low_mask) | (vaddr & low_mask);
        }
        table = ppn << 12; // pointer to the next level
    }
    return vaddr; // no leaf reached: fall back
}

/// Read `width` bytes at a (possibly misaligned) supervisor virtual address, one
/// aligned byte at a time, and return them zero-extended in a u64. A byte access
/// is always aligned, and per-byte translation also covers an access that
/// crosses a page.
fn readMisalignedBytes(addr: usize, width: usize) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < width) : (i += 1) {
        const b = @as(*const u8, @ptrFromInt(translateVaddr(addr + i))).*;
        value |= @as(u64, b) << @intCast(i * 8);
    }
    return value;
}

/// Write the low `width` bytes of `value` to a (possibly misaligned) supervisor
/// virtual address, one aligned byte at a time.
fn writeMisalignedBytes(addr: usize, width: usize, value: u64) void {
    var i: usize = 0;
    while (i < width) : (i += 1) {
        @as(*u8, @ptrFromInt(translateVaddr(addr + i))).* = @truncate(value >> @intCast(i * 8));
    }
}

/// Sign-extend the low `width * 8` bits of `value` to 64 bits. Width 8 is a
/// no-op.
fn signExtendWidth(value: u64, width: usize) u64 {
    if (width >= 8) return value;
    const shift: u6 = @intCast((8 - width) * 8);
    return @bitCast(@as(i64, @bitCast(value << shift)) >> shift);
}

/// Compute the AMO result from the old memory value and the source operand for
/// the RISC-V AMO funct5 codes. It operates on the low `width * 8` bits. min/max
/// use the signed forms and minu/maxu the unsigned forms. An unknown code leaves
/// memory unchanged.
fn amoApply(funct5: u32, old: u64, src: u64, width: usize) u64 {
    const mask: u64 = if (width >= 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width * 8)) - 1;
    const o = old & mask;
    const s = src & mask;
    const signed_less = @as(i64, @bitCast(signExtendWidth(o, width))) <
        @as(i64, @bitCast(signExtendWidth(s, width)));
    const result = switch (funct5) {
        0x00 => o +% s, // amoadd
        0x01 => s, // amoswap
        0x04 => o ^ s, // amoxor
        0x08 => o | s, // amoor
        0x0c => o & s, // amoand
        0x10 => if (signed_less) o else s, // amomin
        0x14 => if (signed_less) s else o, // amomax
        0x18 => if (o < s) o else s, // amominu
        0x1c => if (o < s) s else o, // amomaxu
        else => o,
    };
    return result & mask;
}

/// Emulate a misaligned load or store the core cannot do in hardware. The core
/// raises cause 4 (load) or 6 (store) with mtval set to the faulting address.
/// This handler reads or writes the data one byte at a time (a byte access is
/// always aligned), writes the result back into the trap frame for a load, and
/// steps mepc past the instruction. It matches how OpenSBI keeps misaligned
/// access in M-mode and fixes it up. It returns false for an instruction it
/// does not decode (a float access or an unknown encoding), so the caller
/// redirects the fault to S-mode.
fn emulateMisaligned(frame: *TrapFrame, is_store: bool) bool {
    const mepc = csr.read("mepc");
    // mepc is only 2-byte aligned, because a compressed op can precede the
    // faulting instruction. The core faults on a misaligned 4-byte load, so
    // read the instruction as two aligned halfwords. mepc is the trapped
    // context's PC: a supervisor virtual address once Linux enables paging, so
    // translate it like the data address (a raw M-mode pointer would read a
    // physical address that does not exist for a high kernel VA and hang).
    const lo = @as(*const u16, @ptrFromInt(translateVaddr(mepc))).*;
    const compressed = (lo & 0x3) != 0x3;
    const instr: u32 = if (compressed) blk: {
        break :blk lo;
    } else blk: {
        const hi = @as(*const u16, @ptrFromInt(translateVaddr(mepc + 2))).*;
        break :blk @as(u32, lo) | (@as(u32, hi) << 16);
    };

    // An AMO (opcode 0x2f) raises the same store-misaligned cause (6) as a plain
    // store when its address is not naturally aligned, but it is a
    // read-modify-write, not a store. Emulate the full RMW, like OpenSBI: read
    // the old value, apply the operation with rs2, write the new value back, and
    // put the pre-modification value in rd (sign-extended for the .w form). LR/SC
    // cannot be emulated here (the reservation lives in the core), so hand them
    // back to the supervisor. HW-localised 2026-08-21.
    if (!compressed and (instr & 0x7f) == 0x2f) {
        const funct3 = (instr >> 12) & 0x7;
        const amo_width: usize = switch (funct3) {
            2 => 4, // .w
            3 => 8, // .d
            else => return false,
        };
        const funct5 = (instr >> 27) & 0x1f;
        if (funct5 == 0x02 or funct5 == 0x03) return false; // lr / sc
        const rd = (instr >> 7) & 0x1f;
        const rs2 = (instr >> 20) & 0x1f;
        const addr = csr.read("mtval");
        const old = readMisalignedBytes(addr, amo_width);
        // rs2 == x0 supplies zero. x0 has no frame slot, so do not read it.
        const src: u64 = if (rs2 == 0) 0 else frame.x[rs2];
        writeMisalignedBytes(addr, amo_width, amoApply(funct5, old, src, amo_width));
        if (rd != 0) frame.x[rd] = signExtendWidth(old, amo_width);
        csr.write("mepc", mepc + 4);
        return true;
    }

    // Decode the access width in bytes, whether a load sign-extends, and the
    // data register (rd for a load, rs2 for a store). The faulting address
    // comes from mtval, so the immediate does not need decoding.
    var width: usize = 0;
    var signed = false;
    var reg: usize = 0;

    if (!compressed) {
        const funct3 = (instr >> 12) & 0x7;
        if (!is_store) {
            reg = (instr >> 7) & 0x1f; // rd
            switch (funct3) {
                0 => { // lb
                    width = 1;
                    signed = true;
                },
                1 => { // lh
                    width = 2;
                    signed = true;
                },
                2 => { // lw
                    width = 4;
                    signed = true;
                },
                3 => width = 8, // ld
                4 => width = 1, // lbu
                5 => width = 2, // lhu
                6 => width = 4, // lwu
                else => return false,
            }
        } else {
            reg = (instr >> 20) & 0x1f; // rs2
            switch (funct3) {
                0 => width = 1, // sb
                1 => width = 2, // sh
                2 => width = 4, // sw
                3 => width = 8, // sd
                else => return false,
            }
        }
    } else {
        // Compressed. Quadrant 0 uses a 3-bit register (x8 + field) for both the
        // load rd and the store rs2. Quadrant 2 is the stack-pointer form with a
        // full 5-bit register. funct3 2/6 are 4-byte, 3/7 are 8-byte. funct3 1/5
        // are the float forms this handler does not emulate.
        const quadrant = instr & 0x3;
        const funct3 = (instr >> 13) & 0x7;
        switch (funct3) {
            2, 6 => { // c.lw / c.sw / c.lwsp / c.swsp
                width = 4;
                signed = true; // a compressed word load sign-extends, like lw
            },
            3, 7 => width = 8, // c.ld / c.sd / c.ldsp / c.sdsp
            else => return false,
        }
        switch (quadrant) {
            0 => reg = 8 + ((instr >> 2) & 0x7), // rd' or rs2'
            2 => reg = if (is_store) (instr >> 2) & 0x1f else (instr >> 7) & 0x1f,
            else => return false,
        }
    }

    const addr = csr.read("mtval");

    if (!is_store) {
        var value: u64 = 0;
        var i: usize = 0;
        while (i < width) : (i += 1) {
            // The faulting address is a supervisor virtual address. Weir runs in
            // M-mode with paging off, so translate each byte through the active
            // satp; a plain pointer would read the wrong physical location (for
            // an ioremap/vmalloc range it targets memory that does not exist and
            // the bus never acknowledges). Byte access is always aligned, and
            // per-byte translation also covers an access that crosses a page.
            const b = @as(*const u8, @ptrFromInt(translateVaddr(addr + i))).*;
            value |= @as(u64, b) << @intCast(i * 8);
        }
        if (signed and width < 8) {
            const shift: u6 = @intCast((8 - width) * 8);
            value = @bitCast(@as(i64, @bitCast(value << shift)) >> shift);
        }
        // A load into x0 is discarded. x0 has no frame slot.
        if (reg != 0) frame.x[reg] = value;
    } else {
        // rs2 == x0 stores zero. x0 has no frame slot, so do not read it.
        const value: u64 = if (reg == 0) 0 else frame.x[reg];
        var i: usize = 0;
        while (i < width) : (i += 1) {
            @as(*u8, @ptrFromInt(translateVaddr(addr + i))).* = @truncate(value >> @intCast(i * 8));
        }
    }

    csr.write("mepc", mepc + if (compressed) @as(usize, 2) else 4);
    return true;
}

/// Redirect the current M-mode trap into S-mode, like hardware delegation. The
/// supervisor's own handler then services illegal instructions that Weir does
/// not emulate, exactly as it would with medeleg's illegal-instruction bit set.
fn redirectToSupervisor() void {
    const SR_SIE: usize = 1 << 1;
    const SR_SPIE: usize = 1 << 5;
    const SR_SPP: usize = 1 << 8;
    const MPP_MASK: usize = 0x3 << 11;
    const MPP_S: usize = 0x1 << 11;

    csr.write("scause", csr.read("mcause"));
    csr.write("sepc", csr.read("mepc"));
    csr.write("stval", csr.read("mtval"));

    var ms = csr.read("mstatus");
    const sie_set = (ms & SR_SIE) != 0;
    const from_supervisor = ((ms & MPP_MASK) >> 11) == 1;
    ms &= ~(SR_SPIE | SR_SIE | SR_SPP | MPP_MASK);
    if (sie_set) ms |= SR_SPIE; // SPIE <- SIE
    if (from_supervisor) ms |= SR_SPP; // SPP <- interrupted privilege (S vs U)
    ms |= MPP_S; // MPP <- S so the trailing mret drops into S-mode
    csr.write("mstatus", ms);

    // Enter the supervisor trap vector base. Exceptions ignore vectored mode.
    csr.write("mepc", csr.read("stvec") & ~@as(usize, 0x3));
}

fn reportFatal(mcause: usize) noreturn {
    console.out.print(
        "\n[weir] unhandled trap: mcause={x} mepc={x} mtval={x}\n",
        .{ mcause, csr.read("mepc"), csr.read("mtval") },
    ) catch {};
    cpu.halt();
}
