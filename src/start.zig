//! M-mode reset entry. Every hart on the platform jumps here at the start of
//! RAM. The boot hart performs global init; secondaries wait, then park in the
//! HSM stopped state until started.

const main = @import("main.zig");
const csr = @import("arch/riscv/csr.zig");
const trap = @import("arch/riscv/trap.zig");
const mode = @import("arch/riscv/mode.zig");
const hsm = @import("sbi/hsm.zig");

const BOOT_HART = 0;
const MAX_HARTS = 8;

extern var __bss_start: u8;
extern var __bss_end: u8;

// Dedicated per-hart M-mode trap stacks. Once a hart drops to S-mode the
// supervisor runs on its own virtual stack, and M-mode traps must NOT save onto
// it (M-mode addresses are physical, so a virtual sp would scribble arbitrary
// RAM). `trapVector` swaps to one of these via mscratch.
var mtrap_stacks: [MAX_HARTS][16 * 1024]u8 align(16) = undefined;

// Published by the boot hart once .bss is cleared and the hart table is ready.
var global_ready: u32 = 0;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
    // Mask interrupts until we are ready for them.
        \\ csrw mie, zero
        \\ csrw mip, zero
        // Set up gp for any small-data relaxation.
        \\ .option push
        \\ .option norelax
        \\ la gp, __global_pointer$
        \\ .option pop
        // Per-hart stack: sp = _stacks_bottom + (hartid + 1) * 64 KiB.
        \\ la sp, _stacks_bottom
        \\ addi t0, a0, 1
        \\ slli t0, t0, 16
        \\ add sp, sp, t0
        // a0=hartid, a1=dtb are preserved into weirBoot.
        \\ tail weirBoot
    );
}

export fn weirBoot(hartid: usize, dtb: usize) callconv(.c) noreturn {
    if (hartid == BOOT_HART) {
        // Zero .bss before anyone reads it, then publish the hart table.
        const start = @intFromPtr(&__bss_start);
        const end = @intFromPtr(&__bss_end);
        @memset(@as([*]u8, @ptrFromInt(start))[0 .. end - start], 0);
        hsm.init(BOOT_HART);
        @atomicStore(u32, &global_ready, 1, .release);
    } else {
        // Wait for the boot hart to finish global init.
        while (@atomicLoad(u32, &global_ready, .acquire) == 0) {}
    }

    // Every hart installs the trap vector (direct mode; 4-byte aligned) and
    // points mscratch at its private M-mode trap stack top.
    csr.write("mtvec", @intFromPtr(&trap.trapVector));
    const stk = &mtrap_stacks[hartid & (MAX_HARTS - 1)];
    csr.write("mscratch", @intFromPtr(stk) + stk.len);

    if (hartid == BOOT_HART) {
        // M-mode bring-up and diagnostics, then hand off to S-mode: a UEFI app
        // or a loaded ELF payload (handoff halts if nothing boots).
        main.boot(hartid, dtb);
        const h = main.handoff(hartid, dtb);
        mode.enterSupervisor(h.entry, h.a0, h.a1);
    } else {
        // Secondary harts park as STOPPED until an HSM hart_start wakes them.
        hsm.wait(hartid);
    }
}
