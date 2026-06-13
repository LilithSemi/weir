//! FSBL flow: console up, DDR up, copy main Weir into DRAM, jump to it.

const std = @import("std");
const uart = @import("uart");
const ddr = @import("ddr.zig");
const flash = @import("flash.zig");
const measure = @import("measure.zig");
const cfg = @import("config.zig");

pub const panic = std.debug.FullPanic(panicHandler);

var con = uart.Ns16550a{ .base = cfg.uart_base, .divisor = cfg.uart_divisor };

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    con.writeStr("\n[fsbl] PANIC: ");
    con.writeStr(msg);
    con.writeStr("\n");
    _ = ret_addr;
    while (true) asm volatile ("wfi");
}

pub fn run(hartid: usize, dtb: usize) noreturn {
    con.base = cfg.uart_base;
    con.divisor = cfg.uart_divisor;
    con.init();
    con.writeStr("\n[fsbl] Weir FSBL: DDR bring-up + main load\n");

    if (!ddr.init(&con)) {
        con.writeStr("[fsbl] FATAL: DDR read training failed; halting\n");
        while (true) asm volatile ("wfi");
    }

    const len = flash.loadMain(&con) orelse {
        con.writeStr("[fsbl] FATAL: could not load main firmware\n");
        while (true) asm volatile ("wfi");
    };

    // Root of trust: measure the loaded firmware before running it.
    measure.measureMain(&con, len);

    con.writeStr("[fsbl] jumping to main firmware in DRAM\n");
    jumpToMain(hartid, dtb);
}

/// Enter the main firmware at dram_base with a0=hartid, a1=dtb, exactly as the
/// platform would have entered Weir directly.
fn jumpToMain(hartid: usize, dtb: usize) noreturn {
    const entry: *const fn (usize, usize) callconv(.c) noreturn = @ptrFromInt(cfg.dram_base);
    entry(hartid, dtb);
}
