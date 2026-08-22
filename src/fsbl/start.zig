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
extern var _data_lma: u8;
extern var _data_vma: u8;
extern var _data_end: u8;

// _start is the ELF entry symbol the linker script and the CPU reset vector
// need by that exact name.
// zippy:ignore naming_convention
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
    // Only the boot hart runs the FSBL. The other harts wait for the main
    // firmware HSM.
    if (hartid != 0) while (true) asm volatile ("wfi");

    // XIP: copy initialized .data from its flash load image (_data_lma) into the
    // DRAM window (_data_vma.._data_end) before any global is read. The FSBL
    // executes in place from read-only flash, so its writable state (e.g. the
    // UART `con` struct) only exists once copied. The dcache backs the DRAM
    // window as scratch until the FSBL brings DDR up.
    const dl = @intFromPtr(&_data_lma);
    const dv = @intFromPtr(&_data_vma);
    const de = @intFromPtr(&_data_end);
    if (de > dv) {
        const dst = @as([*]u8, @ptrFromInt(dv))[0 .. de - dv];
        const src = @as([*]const u8, @ptrFromInt(dl))[0 .. de - dv];
        @memcpy(dst, src);
    }

    // Zero .bss before anything touches it.
    const s = @intFromPtr(&__bss_start);
    const e = @intFromPtr(&__bss_end);
    @memset(@as([*]u8, @ptrFromInt(s))[0 .. e - s], 0);

    main.run(hartid, dtb);
}
