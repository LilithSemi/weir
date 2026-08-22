//! FSBL flow: console up, DDR up, copy main Weir into DRAM, jump to it.

const std = @import("std");
const conduit = @import("conduit");
const ddr = @import("ddr.zig");
const flash = @import("flash.zig");
const measure = @import("measure.zig");
const cfg = @import("config.zig");

pub const panic = std.debug.FullPanic(panicHandler);

// The FSBL console: conduit's ns16550a with a std.Io.Writer over it. River gates
// TX on a nonzero divisor and stalls on FCR/MCR writes, so use minimal_init.
// run() calls uart_dev.init() to program the baud before real output.
var uart_dev = conduit.driver.ns16550a.Ns16550a{
    .mmio = conduit.Mmio.direct(cfg.uart_base),
    .divisor = cfg.uart_divisor,
    .minimal_init = true,
};
var con_buf: [0]u8 = .{};
var ws = uart_dev.serial().writer(&con_buf);
const con: *std.Io.Writer = &ws.interface;

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    con.writeAll("\n[fsbl] PANIC: ") catch {};
    con.writeAll(msg) catch {};
    con.writeAll("\n") catch {};
    _ = ret_addr;
    while (true) asm volatile ("wfi");
}

pub fn run(hartid: usize, dtb: usize) noreturn {
    uart_dev.init();
    con.writeAll("\n[fsbl] Weir FSBL: DDR bring-up + main load\n") catch {};

    if (!ddr.init(con)) {
        con.writeAll("[fsbl] FATAL: DDR read training failed. Halting\n") catch {};
        while (true) asm volatile ("wfi");
    }

    const len = flash.loadMain(con) orelse {
        con.writeAll("[fsbl] FATAL: could not load main firmware\n") catch {};
        while (true) asm volatile ("wfi");
    };

    // Root of trust: measure the loaded firmware before running it.
    measure.measureMain(con, len);

    con.writeAll("[fsbl] jumping to main firmware in DRAM\n") catch {};
    jumpToMain(hartid, dtb);
}

/// Enter the main firmware at dram_base with a0=hartid, a1=dtb, exactly as the
/// platform would have entered Weir directly.
fn jumpToMain(hartid: usize, dtb: usize) noreturn {
    const entry: *const fn (usize, usize) callconv(.c) noreturn = @ptrFromInt(cfg.dram_base);
    entry(hartid, dtb);
}
