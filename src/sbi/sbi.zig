//! Minimal RISC-V SBI (Supervisor Binary Interface) provider.
//!
//! Weir runs in M-mode and answers `ecall`s. Today it wires only the few
//! functions needed for early bring-up. The trap handler routes ecalls here.
//! Weir grows toward a full OpenSBI equivalent as S-mode payloads land.

const console = @import("../console/console.zig");
const csr = @import("../arch/riscv/csr.zig");
const cpu = @import("../arch/riscv/cpu.zig");
const clint = @import("../arch/riscv/clint.zig");
const hsm = @import("hsm.zig");
const ipi_mailbox = @import("ipi.zig");
const platform = @import("../platform.zig");

/// SiFive-style test finisher. A write of this magic value powers the machine
/// off. The device tree gives the finisher address. Weir does not assume it.
const FINISHER_PASS: u32 = 0x5555;

fn finisher() *volatile u32 {
    return @ptrFromInt(platform.resetBase());
}

// Extension IDs.
const EID_LEGACY_PUTCHAR = 0x01;
const EID_LEGACY_GETCHAR = 0x02;
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

/// Dispatch a single SBI call. `args` holds a0..a5. eid is a7 and fid is a6.
pub fn dispatch(eid: usize, fid: usize, args: [6]usize) Ret {
    return switch (eid) {
        EID_LEGACY_PUTCHAR => {
            console.out.writeByte(@truncate(args[0])) catch {};
            return .{};
        },
        EID_LEGACY_GETCHAR => legacyGetchar(),
        EID_LEGACY_SHUTDOWN, EID_SRST => shutdown(),
        EID_BASE => base(fid, args),
        EID_TIME => time(fid, args),
        EID_IPI => ipi(fid, args),
        EID_RFENCE => rfence(fid, args),
        EID_HSM => hartStateMgmt(fid, args),
        EID_DBCN => dbcn(fid, args),
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// TIME extension. set_timer(stime_value) programs the next supervisor timer
/// event. Weir enables Sstc (menvcfg.STCE), so a write to stimecmp arms STIP
/// directly. A future value also clears a pending STIP. No machine timer relay.
fn time(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        0 => {
            if (clint.sstc) {
                // Sstc: arm the S-mode timer directly. A future stimecmp also
                // clears a pending STIP.
                csr.write("stimecmp", args[0]);
            } else {
                // No Sstc (minimal core, e.g. creek): program the machine timer
                // through the CLINT and re-arm MTIE. The M-mode timer IRQ handler
                // (trap.zig) relays the machine timer to S-mode as STIP. Clear a
                // stale STIP first because this is a fresh event.
                clint.setTimecmp(csr.read("mhartid"), args[0]);
                csr.clear("mip", MIP_STIP);
                csr.set("mie", MIE_MTIE);
            }
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
            const state = hsm.hartStatus(args[0]) orelse
                break :blk .{ .err = SBI_ERR_INVALID_PARAM };
            break :blk .{ .val = state };
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

/// IPI extension. send_ipi(hart_mask, hart_mask_base) queues a supervisor IPI
/// on each targeted hart. The receiver relays it to S-mode as SSIP.
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

/// RFENCE extension. Each function fans out to the targeted harts. Every hart
/// runs the fence in its machine software handler. The call returns after every
/// remote hart completes (synchronous). Weir handles the SFENCE.VMA range and
/// ASID arguments conservatively and flushes the whole TLB.
fn rfence(fid: usize, args: [6]usize) Ret {
    const ops: u32 = switch (fid) {
        0 => ipi_mailbox.FENCE_I, // remote_fence_i
        1, 2 => ipi_mailbox.SFENCE_VMA, // remote_sfence_vma / remote_sfence_vma_asid
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
                // Fence this hart directly. Never IPI self. That would deadlock.
                if (ops & ipi_mailbox.FENCE_I != 0)
                    asm volatile ("fence.i" ::: .{ .memory = true });
                if (ops & ipi_mailbox.SFENCE_VMA != 0)
                    asm volatile ("sfence.vma" ::: .{ .memory = true });
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
        1 => .{ .val = 0x4D575249 }, // impl id ("MWRI", Lilith Semiconductor Weir)
        2 => .{ .val = 1 }, // impl version
        3 => .{ .val = probe(args[0]) }, // probe_extension
        4 => .{ .val = csr.read("mvendorid") }, // JEDEC vendor ID
        5 => .{ .val = csr.read("marchid") }, // architecture ID
        6 => .{ .val = csr.read("mimpid") }, // implementation ID
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

fn probe(eid: usize) usize {
    return switch (eid) {
        EID_LEGACY_PUTCHAR,
        EID_LEGACY_GETCHAR,
        EID_LEGACY_SHUTDOWN,
        EID_BASE,
        EID_TIME,
        EID_IPI,
        EID_RFENCE,
        EID_HSM,
        EID_DBCN,
        EID_SRST,
        => 1,
        else => 0,
    };
}

/// Legacy console_getchar. The legacy ABI returns the byte in a0, which is
/// `Ret.err` here, or -1 when the UART has no waiting input.
fn legacyGetchar() Ret {
    var b: [1]u8 = undefined;
    var d = [_][]u8{&b};
    if ((console.input.readVec(&d) catch 0) == 1) return .{ .err = b[0] };
    return .{ .err = errCode(-1) };
}

fn dbcn(fid: usize, args: [6]usize) Ret {
    return switch (fid) {
        // console_write(num_bytes, base_addr_lo, base_addr_hi): the modern
        // earlycon=sbi path. The buffer is identity-mapped, so read it directly.
        0 => {
            const n = args[0];
            const buf: [*]const u8 = @ptrFromInt(args[1]);
            var i: usize = 0;
            while (i < n) : (i += 1) console.out.writeByte(buf[i]) catch {};
            return .{ .val = n };
        },
        // console_read(num_bytes, base_addr_lo, base_addr_hi): read waiting UART
        // input into the identity-mapped buffer. Returns the byte count, which is
        // 0 when nothing waits (a non-blocking poll, per the DBCN contract).
        1 => {
            const buf: [*]u8 = @ptrFromInt(args[1]);
            var d = [_][]u8{buf[0..args[0]]};
            return .{ .val = console.input.readVec(&d) catch 0 };
        },
        // console_write_byte
        2 => {
            console.out.writeByte(@truncate(args[0])) catch {};
            return .{};
        },
        else => .{ .err = SBI_ERR_NOT_SUPPORTED },
    };
}

pub fn shutdown() noreturn {
    finisher().* = FINISHER_PASS;
    cpu.halt();
}
