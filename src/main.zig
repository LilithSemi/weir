//! Weir firmware bring-up orchestration.

const std = @import("std");
const console = @import("console/console.zig");
const config = @import("config.zig");
const acpi = @import("acpi/acpi.zig");
const acpi_qemu = @import("acpi/qemu.zig");
const platform = @import("platform.zig");
const mem = @import("mem.zig");
const tpm = @import("tpm/tpm.zig");
const boot_handoff = @import("boot_handoff.zig");
const elf = @import("loader/elf.zig");
const pe = @import("loader/pe.zig");
const blk = @import("virtio/blk.zig");
const varstore = @import("uefi/varstore.zig");
const manager = @import("boot/manager.zig");
const uefi = @import("uefi/uefi.zig");
const initrd = @import("uefi/initrd.zig");
const cpu = @import("arch/riscv/cpu.zig");

/// Firmware panic handler. The UART is reachable from both M- and S-mode, so it
/// reports wherever a panic happens, then parks the hart.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    console.printf("\n[weir] PANIC: {s} (ra={?x})\n", .{ msg, ret_addr });
    cpu.halt();
}

// Pull in the reset entry and trap vector (their exports must be linked).
comptime {
    _ = @import("start.zig");
    _ = @import("arch/riscv/trap.zig");
    _ = @import("drivers.zig"); // Harbor peripheral drivers for River
}

const banner =
    \\
    \\  __      __  ___   ___   ___
    \\  \ \    / / | __| |_ _| | _ \   Weir
    \\   \ \/\/ /  | _|   | |  |   /   RISC-V firmware
    \\    \_/\_/   |___| |___| |_|_\   SBI . UEFI . ACPI
    \\
    \\
;

inline fn bmark(comptime c: u8) void {
    asm volatile (
        \\ lui t0, 0x10000
        \\1:
        \\ lbu t1, 5(t0)
        \\ andi t1, t1, 0x20
        \\ beqz t1, 1b
        \\ sb %[ch], 0(t0)
        :
        : [ch] "r" (@as(usize, c)),
        : .{ .t0 = true, .t1 = true });
}

// TEMP diagnostic: raw-UART putc (runtime), rides the FSBL divisor.
fn putc(c: u8) void {
    asm volatile (
        \\ lui t0, 0x10000
        \\1:
        \\ lbu t1, 5(t0)
        \\ andi t1, t1, 0x20
        \\ beqz t1, 1b
        \\ sb %[ch], 0(t0)
        :
        : [ch] "r" (@as(usize, c)),
        : .{ .t0 = true, .t1 = true });
}

// TEMP diagnostic: raw-UART hex, rides the FSBL divisor (pre-console).
fn dbgHex(v: u32) void {
    var i: i32 = 28;
    putc('0');
    putc('x');
    while (i >= 0) : (i -= 4) {
        const nib: u8 = @intCast((v >> @intCast(i)) & 0xF);
        putc(if (nib < 10) '0' + nib else 'a' + (nib - 10));
    }
}

// TEMP diagnostic: discriminate DRAM read-margin from write-margin. Write each
// word ONCE with an address-derived unique value, then read it back THREE times.
//   clean  = all three reads == expected
//   cwrong = all three reads equal but != expected (write margin / addressing)
//   rflaky = the three reads disagree (read-capture margin)
// Failure counts + the first failing address discriminate the fault class with
// no assumption about which side is marginal.
fn dramSelfTest() void {
    const base: usize = 0x84000000;
    const words: usize = 0x4000; // 64 KiB
    var clean: u32 = 0;
    var cwrong: u32 = 0;
    var rflaky: u32 = 0;
    var firstFail: u32 = 0xFFFFFFFF;
    var p: usize = 0;
    while (p < words) : (p += 1) {
        const a = base + p * 4;
        const want: u32 = @truncate((a ^ 0xDEADBEEF) *% 2654435761);
        @as(*volatile u32, @ptrFromInt(a)).* = want;
        const r1 = @as(*volatile u32, @ptrFromInt(a)).*;
        const r2 = @as(*volatile u32, @ptrFromInt(a)).*;
        const r3 = @as(*volatile u32, @ptrFromInt(a)).*;
        if (r1 == want and r2 == want and r3 == want) {
            clean += 1;
        } else {
            if (firstFail == 0xFFFFFFFF) firstFail = @truncate(a);
            if (r1 == r2 and r2 == r3) cwrong += 1 else rflaky += 1;
        }
    }
    bmark('[');
    bmark('S');
    bmark('T');
    bmark(' ');
    bmark('c');
    dbgHex(clean);
    bmark(' ');
    bmark('w');
    dbgHex(cwrong);
    bmark(' ');
    bmark('f');
    dbgHex(rflaky);
    bmark(' ');
    bmark('@');
    dbgHex(firstFail);
    bmark(']');
    bmark('\n');
}

pub fn boot(hartid: usize, dtb: usize) void {
    // Prefer a build-embedded DTB, else what the platform gave us.
    const dtb_addr = if (config.dtb) |d| @intFromPtr(d.ptr) else dtb;

    // Discover peripherals before bringing up the console, so we drive whatever
    // UART this SoC reports rather than a hardcoded one.
    platform.discover(dtb_addr);

    console.init();
    console.writeStr(banner);
    console.printf("[weir] boot hart {d}, dtb @ {x}\n", .{ hartid, dtb_addr });
    if (config.dtb != null) console.writeStr("[fdt] using build-embedded device tree (-Ddtb)\n");
    platform.report();

    // On QEMU, consume the machine's own fw_cfg tables (DSDT/MADT/RHCT matching
    // the hardware). Else wrap a provided AML blob (the real-River path).
    if (acpi_qemu.loadTables()) |rsdp| {
        console.printf("[acpi] using QEMU fw_cfg tables, RSDP @ {x}\n", .{rsdp});
    } else {
        acpi.setup(config.aml);
    }

    // Non-volatile EFI variable store, backed by CFI NOR flash if present.
    varstore.init();

    // Measured boot. Root of trust is PCR 0 = the Weir image: if an earlier,
    // immutable FSBL already measured us, log its digest, else self-measure.
    // The event log goes where the ACPI TPM2 table points so the OS finds it;
    // synthesize a TPM2 table (QEMU's RISC-V ACPI omits it) when a TPM exists.
    if (acpi_qemu.tpm2LogArea()) |area| {
        tpm.setLogArea(area.addr, area.len);
    } else if (platform.tpmPresent()) {
        if (acpi_qemu.injectTpm2(platform.tpmBase())) |area| tpm.setLogArea(area.addr, area.len);
    }
    tpm.init();
    if (boot_handoff.fsblPcr0(mem.ram_base)) |digest| {
        tpm.recordPrior(tpm.PCR_FIRMWARE, tpm.EV_POST_CODE, &digest, "weir firmware (FSBL)");
    } else {
        tpm.measureSelf(mem.ram_base);
    }
    tpm.selfTest();

    // Prove the trap -> SBI path end to end with an M-mode ecall. The creek
    // microcode trap-return (mret) hang that gated this off is fixed (the dynamic
    // interpreter now handles the Return micro-op), so it is back on.
    const sbi_self_test = true;
    if (sbi_self_test) {
        console.writeStr("[sbi] self-test: console_putchar('Y') via ecall -> ");
        asm volatile ("ecall"
            :
            : [eid] "{a7}" (@as(usize, 0x01)),
              [ch] "{a0}" (@as(usize, 'Y')),
            : .{ .memory = true });
        console.writeStr(" (resumed after mret)\n");
    }

    // Prove wfi retires on real silicon. creek implements wfi as a NOP-hint that
    // advances pc+4 (it does not actually stall), so this must fall straight
    // through and print "resumed". If it hangs here, the dynamic-interpreter wfi
    // handler regressed.
    console.writeStr("[wfi] executing wfi -> ");
    asm volatile ("wfi" ::: .{ .memory = true });
    console.writeStr("resumed\n");

    console.writeStr("\n[weir] M-mode bring-up complete, dropping to S-mode\n");
}

/// What to enter in S-mode and the two arguments to hand it (a0, a1).
pub const Handoff = struct {
    entry: usize,
    a0: usize,
    a1: usize,
};

// Scratch buffer for an image read off storage. Only the disk-boot path uses it;
// sizing it to 0 when disk boot is off keeps 8 MiB out of .bss, which the M-mode
// bss clear would otherwise zero at ~26us/word on the slow microcoded core (an
// 8 MiB zero was ~55s of the boot).
const disk_image_len: usize = if (config.disk_boot) 8 << 20 else 0;
var disk_image: [disk_image_len]u8 align(16) = undefined;

// Firmware-resident DTB copy, handed to an EFI app in reserved low RAM. Only the
// UEFI/PE and boot-manager handoff paths use it (via stableDtb); size 0 when none
// are enabled so it does not bloat the zeroed bss.
const dtb_copy_len: usize =
    if (config.disk_boot or config.boot_manager or config.pe_app != null)
        256 << 10
    else
        0;
var dtb_copy: [dtb_copy_len]u8 align(8) = undefined;

fn stableDtb(dtb: usize) usize {
    if (dtb == 0) return dtb;
    const hp: [*]const u8 = @ptrFromInt(dtb);
    // FDT header: big-endian magic (0xd00dfeed) at +0, totalsize at +4.
    if (std.mem.readInt(u32, hp[0..4], .big) != 0xd00dfeed) return dtb;
    const total = std.mem.readInt(u32, hp[4..8], .big);
    if (total == 0 or total > dtb_copy.len) return dtb;
    @memcpy(dtb_copy[0..total], @as([*]const u8, @ptrFromInt(dtb))[0..total]);
    return @intFromPtr(&dtb_copy);
}

/// Load a PE EFI application and enter it under an EFI System Table. The kernel
/// stub reads the DTB and boot hartid through the table, so they are published
/// there.
fn enterPe(image: []const u8, hartid: usize, dtb: usize) ?Handoff {
    tpm.measure(tpm.PCR_BOOT_LOADER, image, "boot loader");
    const loaded = pe.load(image) catch |err| {
        console.printf("[uefi] PE load failed: {s}\n", .{@errorName(err)});
        return null;
    };
    const table = uefi.prepare(stableDtb(dtb), hartid, loaded.base, loaded.size);
    console.printf("[uefi] PE entry @ {x} (base {x}, {d} bytes), system table @ {x}\n", .{ loaded.entry, loaded.base, loaded.size, table });
    return .{ .entry = loaded.entry, .a0 = @intFromPtr(uefi.imageHandle()), .a1 = table };
}

/// No bootable payload was found, or the one we had failed to load. There is no
/// built-in fallback, so report it and park the hart.
fn noBoot() noreturn {
    console.writeStr("[weir] no bootable payload found; halting\n");
    cpu.halt();
}

/// Resolve the S-mode handoff: a UEFI app under an EFI System Table, or an ELF
/// payload. Boot sources are tried in priority order (e.g. a boot manager that
/// finds nothing falls back to an embedded payload). If all are exhausted, halt
/// (see noBoot).
pub fn handoff(hartid: usize, dtb: usize) Handoff {
    // Publish an initramfs (if embedded) so the Linux EFI stub can fetch it.
    if (config.initrd) |img| {
        console.printf("[initrd] serving {d} bytes via LoadFile2\n", .{img.len});
        initrd.install(img);
    }

    if (config.boot_manager) {
        console.writeStr("[boot] boot manager: searching the ESP for a bootable EFI app\n");
        if (manager.loadBootImage()) |loaded| {
            const table = uefi.prepare(stableDtb(dtb), hartid, loaded.base, loaded.size);
            console.printf("[uefi] PE entry @ {x} (base {x}, {d} bytes), system table @ {x}\n", .{ loaded.entry, loaded.base, loaded.size, table });
            return .{ .entry = loaded.entry, .a0 = @intFromPtr(uefi.imageHandle()), .a1 = table };
        }
        console.writeStr("[boot] nothing bootable here; trying the next source\n");
    }

    if (config.disk_boot) {
        console.writeStr("[loader] booting PE off virtio-blk storage\n");
        if (blk.init()) {
            if (blk.readImage(&disk_image, disk_image.len)) |n| {
                console.printf("[loader] read {d} bytes from disk\n", .{n});
                if (enterPe(disk_image[0..n], hartid, dtb)) |h| return h;
            } else console.writeStr("[loader] disk read failed\n");
        } else console.writeStr("[loader] no virtio-blk disk found\n");
    }

    if (config.pe_app) |image| {
        console.printf("[uefi] loading PE/COFF EFI application, {d} bytes\n", .{image.len});
        if (enterPe(image, hartid, dtb)) |h| return h;
    }

    if (config.payload) |image| {
        console.printf("[loader] loading embedded S-mode payload, {d} bytes\n", .{image.len});
        if (elf.load(image)) |entry| {
            // Hand the payload the DTB Weir actually discovered on: the embedded
            // -Ddtb tree when present, else the platform/FSBL pointer. Passing the
            // raw `dtb` (a null/stale FSBL pointer on this SoC) sent the payload
            // reading a bad address and hanging.
            const payload_dtb = if (config.dtb) |d| @intFromPtr(d.ptr) else dtb;
            console.printf("[loader] payload entry @ {x}, dtb @ {x}\n", .{ entry, payload_dtb });
            return .{ .entry = entry, .a0 = hartid, .a1 = payload_dtb };
        } else |err| {
            console.printf("[loader] ELF load failed: {s}\n", .{@errorName(err)});
        }
    }

    noBoot();
}
