//! M-mode reset entry. Every hart jumps here at the start of RAM. The boot hart
//! does the global init. Secondaries wait, then park in the HSM stopped state
//! until a start call wakes them.

const main = @import("main.zig");
const csr = @import("arch/riscv/csr.zig");
const trap = @import("arch/riscv/trap.zig");
const mode = @import("arch/riscv/mode.zig");
const hsm = @import("sbi/hsm.zig");

const BOOT_HART = 0;
const MAX_HARTS = 8;

extern var __bss_start: u8;
extern var __bss_end: u8;

// Dedicated per-hart M-mode trap stacks. After a hart drops to S-mode, the
// supervisor runs on its own virtual stack. An M-mode trap must not save onto
// that stack. M-mode addresses are physical, so a virtual sp would scribble
// arbitrary RAM. trapVector swaps to one of these stacks through mscratch.
var mtrap_stacks: [MAX_HARTS][16 * 1024]u8 align(16) = undefined;

// The boot hart publishes this after it clears .bss and the hart table is ready.
var global_ready: u32 = 0;

// _start is the ELF entry symbol the linker script and the CPU reset vector
// need by that exact name.
// zippy:ignore naming_convention
export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
    // Mask interrupts until Weir is ready for them.
        \\ csrw mie, zero
        \\ csrw mip, zero
        // Set up gp for small-data relaxation.
        \\ .option push
        \\ .option norelax
        \\ la gp, __global_pointer$
        \\ .option pop
        // Per-hart stack: sp = _stacks_bottom + (hartid + 1) * 64 KiB.
        \\ la sp, _stacks_bottom
        \\ addi t0, a0, 1
        \\ slli t0, t0, 16
        \\ add sp, sp, t0
        // a0=hartid and a1=dtb pass through to weirBoot.
        \\ tail weirBoot
    );
}

export fn weirBoot(hartid: usize, dtb: usize) callconv(.c) noreturn {
    if (hartid == BOOT_HART) {
        const start = @intFromPtr(&__bss_start);
        const end = @intFromPtr(&__bss_end);
        @memset(@as([*]u8, @ptrFromInt(start))[0 .. end - start], 0);
        hsm.init(BOOT_HART);
        @atomicStore(u32, &global_ready, 1, .release);
    } else {
        // Wait for the boot hart to finish global init.
        while (@atomicLoad(u32, &global_ready, .acquire) == 0) {}
    }

    // Every hart installs the trap vector in direct mode, 4-byte aligned. Each
    // also points mscratch at the top of its private M-mode trap stack.
    csr.write("mtvec", @intFromPtr(&trap.trapVector));
    const stk = &mtrap_stacks[hartid & (MAX_HARTS - 1)];
    csr.write("mscratch", @intFromPtr(stk) + stk.len);

    if (hartid == BOOT_HART) {
        // Run M-mode bring-up and diagnostics, then hand off to S-mode. The
        // target is a UEFI app or a loaded ELF payload. handoff halts if
        // nothing boots.
        main.boot(hartid, dtb);
        const h = main.handoff(hartid, dtb);
        mode.enterSupervisor(h.entry, h.a0, h.a1);
    } else {
        // Secondary harts park as STOPPED until an HSM hart_start wakes them.
        hsm.wait(hartid);
    }
}
