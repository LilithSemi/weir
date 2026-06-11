//! Weir firmware bring-up orchestration.

const std = @import("std");
const console = @import("console/console.zig");
const config = @import("config.zig");
const fdt = @import("fdt/fdt.zig");
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
    fdt.inspect(dtb_addr);

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

    // Prove the trap -> SBI path end to end with an M-mode ecall.
    console.writeStr("[sbi] self-test: console_putchar('Y') via ecall -> ");
    asm volatile ("ecall"
        :
        : [eid] "{a7}" (@as(usize, 0x01)),
          [ch] "{a0}" (@as(usize, 'Y')),
        : .{ .memory = true });
    console.writeStr("\n[weir] M-mode bring-up complete, dropping to S-mode\n");
}

/// What to enter in S-mode and the two arguments to hand it (a0, a1).
pub const Handoff = struct {
    entry: usize,
    a0: usize,
    a1: usize,
};

// Scratch buffer for an image read off storage (low firmware RAM, clear of the
// PE load base at 0x8200_0000).
var disk_image: [8 << 20]u8 align(16) = undefined;

// Firmware-resident DTB copy. The platform DTB sits high in RAM inside the
// region we advertise as free, so an EFI app could overwrite it; hand the app
// this copy in low, reserved firmware memory instead.
var dtb_copy: [256 << 10]u8 align(8) = undefined;

fn stableDtb(dtb: usize) usize {
    const total = fdt.totalSize(dtb) orelse return dtb;
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
            console.printf("[loader] payload entry @ {x}\n", .{entry});
            return .{ .entry = entry, .a0 = hartid, .a1 = dtb };
        } else |err| {
            console.printf("[loader] ELF load failed: {s}\n", .{@errorName(err)});
        }
    }

    noBoot();
}
