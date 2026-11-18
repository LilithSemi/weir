//! System reset and power off. A syscon node of the device tree does the work
//! when the tree has one. Without one, a reboot starts each hart again at the
//! boot ROM, and a power off stops the harts.

const console = @import("../console/console.zig");
const csr = @import("../arch/riscv/csr.zig");
const cpu = @import("../arch/riscv/cpu.zig");
const ipi = @import("ipi.zig");
const soc = @import("soc");

const mstatus_mie: usize = 1 << 3;
const mstatus_mprv: usize = 1 << 17;

pub fn shutdown() noreturn {
    if (soc.poweroff) |device| write(device);
    console.out.writeAll("[weir] power off: the board has no power device, the harts stop\n") catch {};
    others(ipi.STOP);
    stopHart();
}

pub fn reboot() noreturn {
    if (soc.reboot) |device| write(device);
    if (soc.restart_vector == null) {
        console.out.writeAll("[weir] reboot: the board has no reset device, the harts stop\n") catch {};
        others(ipi.STOP);
        stopHart();
    }
    console.out.writeAll("[weir] reboot: start again at the boot ROM\n") catch {};
    while (!console.txEmpty()) {}
    others(ipi.RESTART);
    restartHart();
}

/// Stops this hart. No interrupt wakes it.
pub fn stopHart() noreturn {
    csr.write("mie", 0);
    cpu.halt();
}

/// Starts this hart again at the boot ROM, as a reset does. The devices keep
/// their state, so the boot code must not rely on the reset state of a device.
pub fn restartHart() noreturn {
    const vector = soc.restart_vector orelse stopHart();
    csr.write("mie", 0);
    csr.clear("mstatus", mstatus_mie | mstatus_mprv);
    csr.write("satp", 0);
    asm volatile ("jr %[vector]"
        :
        : [vector] "r" (vector),
          [hart] "{a0}" (csr.read("mhartid")),
          [dtb] "{a1}" (@as(usize, 0)),
    );
    unreachable;
}

fn write(device: soc.Syscon) void {
    // A reset drops the bytes that the UART did not send yet.
    while (!console.txEmpty()) {}
    const register: *volatile u32 = @ptrFromInt(device.address);
    register.* = device.value;
}

fn others(op: u32) void {
    const self = csr.read("mhartid");
    for (soc.harts) |hart| {
        if (hart != self) ipi.send(@intCast(hart), op);
    }
}
