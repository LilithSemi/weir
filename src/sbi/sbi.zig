//! Minimal RISC-V SBI (Supervisor Binary Interface) provider.
//!
//! Weir runs in M-mode and answers `ecall`s. Only the handful of functions
//! needed for early bring-up are wired today; the trap handler routes ecalls
//! here. This grows toward a full OpenSBI-equivalent as S-mode payloads land.

const console = @import("../console/console.zig");
const csr = @import("../arch/riscv/csr.zig");
const cpu = @import("../arch/riscv/cpu.zig");
const clint = @import("../arch/riscv/clint.zig");
const hsm = @import("hsm.zig");
const ipi_mailbox = @import("ipi.zig");
const platform = @import("../platform.zig");

/// SiFive-style test finisher: writing magic values powers the machine off or
/// resets it. Its address is discovered from the device tree, not assumed.
const FINISHER_PASS: u32 = 0x5555;
const FINISHER_RESET: u32 = 0x7777;

fn finisher() *volatile u32 {
    return @ptrFromInt(platform.resetBase());
}

// Extension IDs.
const EID_LEGACY_PUTCHAR = 0x01;
const EID_LEGACY_SHUTDOWN = 0x08;
const EID_BASE = 0x10;
const EID_TIME = 0x54494D45; // "TIME" timer
const EID_IPI = 0x735049; // "sPI" inter-processor interrupt
const EID_RFENCE = 0x52464E43; // "RFNC" remote fence
const EID_HSM = 0x48534D; // "HSM" hart state management
const EID_DBCN = 0x4442434E; // "DBCN" debug console
const EID_SRST = 0x53525354; // "SRST" system reset

// mie / mip bits used to relay machine interrupts down to supervisor level.
const MIE_MTIE: usize = 1 << 7; // machine timer
const MIP_STIP: usize = 1 << 5; // supervisor timer pending

// SBI return codes (sbiret.error).
const SBI_SUCCESS: usize = 0;
const SBI_ERR_NOT_SUPPORTED: usize = errCode(-2);
const SBI_ERR_INVALID_PARAM: usize = errCode(-3);

fn errCode(comptime v: isize) usize {
    return @bitCast(@as(isize, v));
}

pub const Ret = struct {
    err: usize = SBI_SUCCESS,
    val: usize = 0,
};

/// Dispatch a single SBI call. `args` holds a0..a5; eid is a7, fid is a6.
pub fn dispatch(eid: usize, fid: usize, args: [6]usize) Ret {
    return switch (eid) {
        EID_LEGACY_PUTCHAR => {
            console.putc(@truncate(args[0]));
            return .{};
        },
        EID_LEGACY_SHUTDOWN => shutdown(),
        EID_BASE => base(fid, args),
        EID_TIME => time(fid, args),
        EID_IPI => ipi(fid, args),
        EID_RFENCE => rfence(fid, args),
        EID_HSM => hartStateMgmt(fid, args),
        EID_DBCN => dbcn(fid, args),
        EID_SRST => shutdown(),
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// TIME extension. set_timer(stime_value) programs the next supervisor timer
/// event. Weir enables Sstc (menvcfg.STCE), so writing stimecmp directly arms
/// STIP (a future value also clears a pending STIP); no machine timer relay.
fn time(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        0 => {
            csr.write("stimecmp", args[0]);
            return .{};
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// HSM extension: hart_start (0), hart_stop (1), hart_get_status (2).
fn hartStateMgmt(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        0 => .{ .err = hsm.hartStart(args[0], args[1], args[2]) },
        1 => hsm.hartStop(), // never returns
        2 => blk: {
            const state = hsm.hartStatus(args[0]) orelse break :blk .{ .err = SBI_ERR_INVALID_PARAM };
            break :blk .{ .val = state };
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// IPI extension. send_ipi(hart_mask, hart_mask_base) queues a supervisor IPI
/// on each targeted hart; the receiver relays it to S-mode as SSIP.
fn ipi(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        0 => {
            forEachHart(args[0], args[1], struct {
                fn run(target: usize) void {
                    ipi_mailbox.send(target, ipi_mailbox.SOFT);
                }
            }.run);
            return .{};
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// RFENCE extension. Each function fans out to the targeted harts, which run
/// the fence in their machine software handler; the call returns once every
/// remote hart has completed (synchronous). SFENCE.VMA range/ASID arguments are
/// honoured conservatively by flushing the whole TLB.
fn rfence(fid: usize, args: [6]usize) Ret {
    const ops: u32 = switch (fid) {
        0 => ipi_mailbox.FENCE_I, // remote_fence_i
        1 => ipi_mailbox.SFENCE_VMA, // remote_sfence_vma
        2 => ipi_mailbox.SFENCE_VMA, // remote_sfence_vma_asid
        else => return .{ .err = SBI_ERR_NOT_SUPPORTED },
    };

    const self = csr.read("mhartid");
    var mask = args[0];
    const base_hart = args[1];
    var i: usize = 0;
    while (mask != 0) : (i += 1) {
        if (mask & 1 != 0) {
            const target = base_hart + i;
            if (target == self) {
                // Fence ourselves directly; never IPI self (it would deadlock).
                if (ops & ipi_mailbox.FENCE_I != 0) asm volatile ("fence.i" ::: .{ .memory = true });
                if (ops & ipi_mailbox.SFENCE_VMA != 0) asm volatile ("sfence.vma" ::: .{ .memory = true });
            } else {
                ipi_mailbox.sendSync(target, ops);
            }
        }
        mask >>= 1;
    }
    return .{};
}

fn forEachHart(mask_in: usize, base_hart: usize, comptime run: fn (usize) void) void {
    var mask = mask_in;
    var i: usize = 0;
    while (mask != 0) : (i += 1) {
        if (mask & 1 != 0) run(base_hart + i);
        mask >>= 1;
    }
}

fn base(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        0 => .{ .val = 0x02000000 }, // spec version 2.0
        1 => .{ .val = 0x4D575249 }, // impl id ("MWRI" - Midstall Weir)
        2 => .{ .val = 1 }, // impl version
        3 => .{ .val = probe(args[0]) }, // probe_extension
        4 => .{ .val = 0 }, // mvendorid
        5 => .{ .val = 0 }, // marchid
        6 => .{ .val = 0 }, // mimpid
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

fn probe(eid: usize) usize {
    return switch (eid) {
        EID_LEGACY_PUTCHAR, EID_LEGACY_SHUTDOWN, EID_BASE, EID_TIME, EID_IPI, EID_RFENCE, EID_HSM, EID_DBCN, EID_SRST => 1,
        else => 0,
    };
}

fn dbcn(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        // console_write(num_bytes, base_addr_lo, base_addr_hi): the modern
        // earlycon=sbi path. The buffer is identity-mapped, so read it directly.
        0 => {
            const n = args[0];
            const buf: [*]const u8 = @ptrFromInt(args[1]);
            var i: usize = 0;
            while (i < n) : (i += 1) console.putc(buf[i]);
            return .{ .val = n };
        },
        // console_read: nothing to deliver yet.
        1 => .{ .val = 0 },
        // console_write_byte
        2 => {
            console.putc(@truncate(args[0]));
            return .{};
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

pub fn shutdown() noreturn {
    finisher().* = FINISHER_PASS;
    cpu.halt();
}
