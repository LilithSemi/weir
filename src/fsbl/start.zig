//! First-stage boot loader (FSBL) reset entry (the SPL / bootblock stage).
//!
//! On an SoC where DRAM is dead at reset (e.g. River on the ECP5), the core
//! cannot run main firmware from DRAM. The FSBL runs from on-chip SRAM (or
//! flash), brings up the DDR controller, copies main Weir into DRAM, and jumps
//! to it.

const main = @import("main.zig");

pub const panic = main.panic;

extern var __bss_start: u8;
extern var __bss_end: u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ csrw mie, zero
        \\ csrw mip, zero
        \\ .option push
        \\ .option norelax
        \\ la gp, __global_pointer$
        \\ .option pop
        \\ la sp, _stack_top
        \\ tail fsblMain
    );
}

export fn fsblMain(hartid: usize, dtb: usize) callconv(.c) noreturn {
    // Only the boot hart runs the FSBL; others wait for the main firmware's HSM.
    // TODO: River's actual multi-hart reset model goes here.
    if (hartid != 0) while (true) asm volatile ("wfi");

    // Zero .bss before anything touches it.
    const s = @intFromPtr(&__bss_start);
    const e = @intFromPtr(&__bss_end);
    @memset(@as([*]u8, @ptrFromInt(s))[0 .. e - s], 0);

    main.run(hartid, dtb);
}
