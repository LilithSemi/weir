//! FSBL trap handler. It prints the trap CSRs on the UART and halts.
//!
//! The handler uses only registers and the UART registers. It uses no stack
//! and no RAM, so it also works when sp is bad or when the RAM is the fault.

const std = @import("std");
const cfg = @import("config.zig");

// The bound on each wait for an empty transmit register, so a dead UART
// cannot stop the halt line.
const tx_wait_loops = 0x10000;

const lsr_thre = 0x20;

/// The trap vector. start.zig writes its address to mtvec at reset.
export fn fsblTrapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (entryCode());
}

/// The vector while the handler runs. A trap in the handler stops here.
export fn fsblTrapHalt() align(4) callconv(.naked) noreturn {
    asm volatile (
        \\ csrw mie, zero
        \\ 1: wfi
        \\ j 1b
    );
}

fn entryCode() []const u8 {
    return std.fmt.comptimePrint(
        \\ .option push
        \\ .option norelax
        \\ la t0, fsblTrapHalt
        \\ .option pop
        \\ csrw mtvec, t0
        \\ csrci mstatus, 8
        \\ csrw mie, zero
        \\ csrr s2, mcause
        \\ csrr s3, mepc
        \\ csrr s4, mtval
        \\ li t0, 0x{x}
        \\{s}
        \\{s}
        \\ mv a0, s2
        \\ jal ra, .Lfsbl_trap_puthex
        \\{s}
        \\ mv a0, s3
        \\ jal ra, .Lfsbl_trap_puthex
        \\{s}
        \\ mv a0, s4
        \\ jal ra, .Lfsbl_trap_puthex
        \\{s}
        \\ 1: wfi
        \\ j 1b
        \\
        \\ .Lfsbl_trap_putc:
        \\ li t1, {d}
        \\ 1: lbu t2, 5(t0)
        \\ andi t2, t2, {d}
        \\ bnez t2, 2f
        \\ addi t1, t1, -1
        \\ bnez t1, 1b
        \\ 2: sb a0, 0(t0)
        \\ ret
        \\
        \\ .Lfsbl_trap_puthex:
        \\ mv s1, ra
        \\ mv a1, a0
        \\ li t3, 60
        \\ li t4, 0
        \\ 1: srl a0, a1, t3
        \\ andi a0, a0, 15
        \\ or t4, t4, a0
        \\ bnez t4, 2f
        \\ bnez t3, 4f
        \\ 2: addi a0, a0, '0'
        \\ li t5, '9' + 1
        \\ blt a0, t5, 3f
        \\ addi a0, a0, 'a' - '9' - 1
        \\ 3: jal ra, .Lfsbl_trap_putc
        \\ 4: addi t3, t3, -4
        \\ bgez t3, 1b
        \\ mv ra, s1
        \\ ret
    , .{
        cfg.uart_base,
        divisorCode(cfg.uart_divisor),
        printCode("\n[fsbl] trap: mcause="),
        printCode(" mepc="),
        printCode(" mtval="),
        printCode("\n[fsbl] halted\n"),
        tx_wait_loops,
        lsr_thre,
    });
}

// Program the divisor again, the same as the ns16550a minimal_init. River
// sends nothing while the divisor is zero, and the trap can come before
// main.zig sets it.
fn divisorCode(comptime divisor: u16) []const u8 {
    if (divisor == 0) return "";
    return std.fmt.comptimePrint(
        \\ li t1, 0x83
        \\ sb t1, 3(t0)
        \\ li t1, 0x{x}
        \\ sb t1, 0(t0)
        \\ li t1, 0x{x}
        \\ sb t1, 1(t0)
        \\ li t1, 0x03
        \\ sb t1, 3(t0)
    , .{ divisor & 0xff, divisor >> 8 });
}

// Each byte is an immediate, so the text needs no data load. A line feed
// gets a carriage return first, the same as the ns16550a driver.
fn printCode(comptime text: []const u8) []const u8 {
    comptime var code: []const u8 = "";
    inline for (text) |c| {
        if (c == '\n') code = code ++ " li a0, 13\n jal ra, .Lfsbl_trap_putc\n";
        code = code ++ std.fmt.comptimePrint(" li a0, {d}\n jal ra, .Lfsbl_trap_putc\n", .{c});
    }
    return code;
}
