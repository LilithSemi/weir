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
const storage = @import("block/storage.zig");
const conduit = @import("conduit");
const varstore = @import("uefi/varstore.zig");
const time = @import("time.zig");
const manager = @import("boot/manager.zig");
const uefi = @import("uefi/uefi.zig");
const initrd = @import("uefi/initrd.zig");
const cpu = @import("arch/riscv/cpu.zig");
const clint = @import("arch/riscv/clint.zig");
const soc = @import("soc");

/// Firmware panic handler. The UART is reachable from both M- and S-mode, so it
/// reports wherever a panic happens, then parks the hart.
pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    console.out.print("\n[weir] PANIC: {s} (ra={?x})\n", .{ msg, ret_addr }) catch {};
    cpu.halt();
}

// Force-link the reset entry, the trap vector, and the Harbor drivers. Weir
// never names their exports, so each import makes the linker keep them.
comptime {
    _ = @import("start.zig"); // zippy:ignore discarded_error -- links the _start reset entry
    _ = @import("arch/riscv/trap.zig"); // zippy:ignore discarded_error -- links the trap vector
    _ = @import("drivers.zig"); // zippy:ignore discarded_error -- links the Harbor drivers
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
    // Prefer a build-embedded DTB. Use the platform DTB when none is embedded.
    const dtb_addr = if (config.dtb) |d| @intFromPtr(d.ptr) else dtb;

    // Discover the peripherals before the console starts. This drives the UART
    // that the SoC reports, not a fixed address.
    platform.discover(dtb_addr);

    console.init();
    console.out.writeAll(banner) catch {};
    console.out.print("[weir] boot hart {d}, dtb @ {x}\n", .{ hartid, dtb_addr }) catch {};
    if (config.dtb != null) console.out.writeAll(
        "[fdt] using the build-embedded device tree\n",
    ) catch {};
    platform.report();

    // ACPI table source, in priority order:
    //  1. QEMU fw_cfg tables (a complete DSDT that matches the machine).
    //  2. A supplied AML blob (-Daml): a real, complete DSDT, used as-is.
    //  3. A DSDT translated from the embedded device tree: every node becomes a
    //     PRP0001 device (its reg/interrupts as _CRS, its compatible/properties
    //     as _DSD), so the OS binds the same drivers it would from the DT.
    // With no fw_cfg, no AML, and no device tree, there is nothing to build a
    // DSDT from, so Weir advertises no ACPI and the OS uses the device tree Weir
    // publishes to the config table.
    if (acpi_qemu.loadTables()) |rsdp| {
        console.out.print("[acpi] using QEMU fw_cfg tables, RSDP @ {x}\n", .{rsdp}) catch {};
    } else if (config.aml != null or config.dtb != null) {
        acpi.setup(config.aml);
    } else {
        console.out.writeAll("[acpi] no AML and no device tree. The OS uses the published device tree.\n") catch {};
    }

    // Non-volatile EFI variable store, backed by CFI NOR flash if present.
    varstore.init();

    // Wall-clock time for the UEFI runtime services. Binds an RTC if present,
    // else starts a software clock at the UNIX epoch.
    time.init();

    // Measured boot. The root of trust is PCR 0, the Weir image. If an earlier
    // immutable FSBL already measured Weir, log its digest. If not, self-measure.
    // The event log goes where the ACPI TPM2 table points, so the OS finds it.
    // QEMU's RISC-V ACPI omits the TPM2 table, so synthesize one when a TPM
    // is present.
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

    // Prove the trap to SBI path end to end with an M-mode ecall. The creek
    // microcode mret hang that blocked this test is fixed. The dynamic
    // interpreter now handles the Return micro-op, so the test runs again.
    const sbi_self_test = true;
    if (sbi_self_test) {
        console.out.writeAll("[sbi] self-test: console_putchar('Y') via ecall -> ") catch {};
        asm volatile ("ecall"
            :
            : [eid] "{a7}" (@as(usize, 0x01)),
              [ch] "{a0}" (@as(usize, 'Y')),
            : .{ .memory = true });
        console.out.writeAll(" (resumed after mret)\n") catch {};
    }

    // Bring up boot storage. The boot device is the SD card on the SPI bus. The
    // storage subsystem discovers it here. A later OS image on the card boots
    // through the disk or boot-manager path.
    bringUpStorage();

    console.out.writeAll("[weir] M-mode bring-up complete, dropping to S-mode\n") catch {};
}

/// Return a best-effort name for an SD manufacturer ID (CID byte 0). The list
/// holds the well-known assignments. An unknown ID reports "unknown".
/// Discover the boot block devices. First run a loopback self-test on each SPI
/// master to prove its datapath. Then hand off to the storage subsystem, report
/// every device it finds, and read LBA 0 of the first as a liveness check.
fn bringUpStorage() void {
    // Loopback self-test per SPI master. A byte written with loopback set must
    // come back intact. This proves the SPI datapath before Weir talks to a card.
    for (platform.spiControllers(), 0..) |ctrl, s| {
        switch (ctrl.ip) {
            .harbor => {
                const mmio = conduit.Mmio.direct(ctrl.base);
                mmio.write(u32, 0x18, 4); // DIVIDER
                mmio.write(u32, 0x00, 0b1001); // enable | loopback
                mmio.write(u32, 0x10, 0xA5); // DATA, start the transfer
                while (mmio.read(u32, 0x08) & 1 != 0) {} // wait for not-busy
                const lb: u8 = @truncate(mmio.read(u32, 0x10));
                mmio.write(u32, 0x00, 0); // disable
                const verdict = if (lb == 0xA5) "OK" else "FAIL";
                console.out.print(
                    "[weir] sd: spi{d} @ 0x{x} loopback 0xA5 -> 0x{x:0>2} ({s})\n",
                    .{ s, ctrl.base, lb, verdict },
                ) catch {};
            },
        }
    }

    // The storage subsystem finds every block device: virtio, an SD host, or an
    // SD card in SPI mode. Each is a generic block device.
    if (!storage.init()) {
        console.out.writeAll("[weir] sd: storage subsystem found no block device\n") catch {};
        return;
    }

    for (storage.devices(), 0..) |d, i| {
        const dev = d.dev;
        const mib = dev.num_blocks * @as(u64, 512) / (1024 * 1024);
        console.out.print(
            "[weir] sd: device {d} {s}: {d} blocks ({d} MiB), {d} B/blk\n",
            .{ i, @tagName(d.kind), dev.num_blocks, mib, dev.block_size },
        ) catch {};
        // Show the device identity when it carries one (an SD/MMC CID).
        if (d.info.known()) {
            const info = d.info;
            console.out.print(
                "[weir] sd:   MID=0x{x:0>2} ({s}) OEM=\"{s}\" product=\"{s}\" rev {d}.{d} serial 0x{x:0>8} made {d}-{d:0>2}\n",
                .{ info.manufacturer_id, info.manufacturer(), &info.oem, &info.product, info.revision.major, info.revision.minor, info.serial, info.date.year, info.date.month },
            ) catch {};
        }
    }

    // Liveness and data check on the first device.
    const dev0 = storage.devices()[0].dev;
    var sector: [512]u8 = undefined;
    if (dev0.readBlocks(0, 1, sector[0..])) {
        // One formatted call, not a per-byte loop. sig=55aa proves the read got
        // real MBR data. The first 4 bytes of a GPT protective MBR are zero.
        console.out.print(
            "[weir] sd: device 0 LBA0 ok: [0..4]={x:0>2}{x:0>2}{x:0>2}{x:0>2} sig={x:0>2}{x:0>2}\n",
            .{ sector[0], sector[1], sector[2], sector[3], sector[510], sector[511] },
        ) catch {};
    } else {
        console.err.writeAll("[weir] sd: device 0 LBA0 read failed\n") catch {};
    }

    // SDIO read-verify probe. DISABLED for a clean boot (the stale-flash false
    // alarm is resolved: with the card reflashed to the exact image, small and
    // large reads both match the golden checksum, so the SD read path is sound).
    if (false) {
        const nblk: u32 = 256; // SMALL non-zero control (kernel s0)
        const bytes: u32 = nblk * 512;
        const start_lba: u32 = 61461; // kernel EFI file start (non-zero code, clean localization)
        const bufA: [*]u8 = @ptrFromInt(0x88000000);
        const bufB: [*]u8 = @ptrFromInt(0x88200000);
        console.out.print("[weir] rv: read-verify {d} blocks @ LBA {d}\n", .{ nblk, start_lba }) catch {};
        // One BIG read, then FNV-1a checksum, compared on the host to the golden
        // image. With the per-chunk read-back barrier in the driver this large
        // read should now be byte-exact (golden for LBA 4096, 2 MiB =
        // 0xbbcbfb20f46ad9f0).
        _ = bufB;
        if (!dev0.readBlocks(start_lba, nblk, bufA[0..bytes])) {
            console.err.writeAll("[weir] rv: big read FAILED\n") catch {};
        } else {
            // Per-1024-block-quarter checksums, to localise which part of the big
            // read corrupts. Host goldens: Q0 0xfc31bff590c22325 Q1
            // 0xf932056dca302c21 Q2 0x70f45e126ac7122e Q3 0xa87ae0aff64244bb.
            var q: u32 = 0;
            while (q < 1) : (q += 1) {
                var h: u64 = 0xcbf29ce484222325;
                var ci: u32 = q * 256 * 512;
                const end: u32 = ci + 256 * 512;
                while (ci < end) : (ci += 1) h = (h ^ bufA[ci]) *% 0x100000001b3;
                console.out.print("[weir] rv: s{d} = 0x{x:0>16}\n", .{ q, h }) catch {};
            }
        }
    }

    // Throughput/SD-read diagnostic bench. DISABLED for the boot image: its
    // hundreds of back-to-back reads stress the marginal DDR path (now throttled
    // by the readBlocks drain, but that makes the bench crawl) and it is not
    // needed to boot. The real boot path (storage init + kernel load) uses the
    // same drained readBlocks. Re-enable by flipping the guard for diagnostics.
    if (false) {
        // Diagnostic bench. Print the transfer clock divider FIRST (SD clock is
        // fabric / (2*(CLK_DIV+1))), so we see it even if a read stalls. Then read
        // 8 blocks one at a time with a per-block time, to localise any hang and
        // measure the real per-block cost. SDIO base 0x10001000, CLK_DIV at +0x10.
        // DDR write-rate isolation. Time a tight CPU store loop to DRAM, no SD
        // and no ADMA. If this crawls too, the narrow-write cost is the DDR path,
        // not the SDIO DMA. The read-back loop times the read side as well.
        {
            const words: u32 = 8192;
            const p: [*]volatile u32 = @ptrFromInt(0x88000000);
            const w0 = clint.time();
            var i: u32 = 0;
            while (i < words) : (i += 1) p[i] = i ^ 0xa5a5a5a5;
            const w1 = clint.time();
            var acc: u32 = 0;
            i = 0;
            while (i < words) : (i += 1) acc +%= p[i];
            const w2 = clint.time();
            const wus = if (soc.timebase_hz != 0) (w1 -% w0) * 1000000 / soc.timebase_hz else 0;
            const rus = if (soc.timebase_hz != 0) (w2 -% w1) * 1000000 / soc.timebase_hz else 0;
            const wkbps = if (wus != 0) @as(u64, words) * 4 * 1000 / wus else 0;
            const rkbps = if (rus != 0) @as(u64, words) * 4 * 1000 / rus else 0;
            const wc = (w1 -% w0) / words;
            const rc = (w2 -% w1) / words;
            console.out.print("[weir] ddr: cpu {d} KiB: write {d} us ({d} KB/s, {d} cyc/word), read {d} us ({d} KB/s, {d} cyc/word) acc={x}\n", .{ words * 4 / 1024, wus, wkbps, wc, rus, rkbps, rc, acc }) catch {};
        }

        // Same store/load loop to on-chip SRAM (0x08000000, single-cycle) instead
        // of DRAM. SRAM time = the core plus fast-memory cost; DRAM-time minus
        // SRAM-time = the pure DDR access penalty. This splits the 704 cycles.
        {
            const words: u32 = 4096;
            const p: [*]volatile u32 = @ptrFromInt(0x08004000);
            const s0 = clint.time();
            var i: u32 = 0;
            while (i < words) : (i += 1) p[i] = i ^ 0xa5a5a5a5;
            const s1 = clint.time();
            var acc: u32 = 0;
            i = 0;
            while (i < words) : (i += 1) acc +%= p[i];
            const s2 = clint.time();
            const wc = (s1 -% s0) / words;
            const rc = (s2 -% s1) / words;
            console.out.print("[weir] sram: cpu {d} words: write {d} cyc/word, read {d} cyc/word acc={x}\n", .{ words, wc, rc, acc }) catch {};
        }

        const clk_div = @as(*volatile u32, @ptrFromInt(0x10001010)).*;
        console.out.print("[weir] sd: bench: CLK_DIV={d}, reading 8 blocks one at a time\n", .{clk_div}) catch {};

        // ADMA diagnostic counters. Clear (write 0x80), read ONE block, read the
        // four counters back. This splits the per-word cost: ackwait = cycles the
        // ADMA stalls on write acks, datstall = cycles the SD clock is parked on
        // the ADMA drain, active = total ADMA write-state cycles, beats = words.
        {
            const base: usize = 0x10001000;
            const p_ackwait: *volatile u32 = @ptrFromInt(base + 0x80);
            const p_beat: *volatile u32 = @ptrFromInt(base + 0x88);
            const p_datstall: *volatile u32 = @ptrFromInt(base + 0x90);
            const p_active: *volatile u32 = @ptrFromInt(base + 0x98);
            var one: [512]u8 = undefined;
            // DIAG: confirm an uncached SDIO STATUS read works HERE (post DRAM
            // loops, pre-ADMA). STATUS @ +0x08, bit8 = busy.
            {
                const p_status: *volatile u32 = @ptrFromInt(base + 0x08);
                var s: u32 = 0;
                var k: u32 = 0;
                while (k < 5) : (k += 1) s = p_status.*;
                console.out.print("[weir] diag: pre-adma STATUS read ok, last=0x{x}\n", .{s}) catch {};
            }
            p_ackwait.* = 0;
            // DIAG: repeated single-block reads. Print BEFORE each so we see
            // exactly which iteration wedges (1st real transfer vs Nth repeat).
            var rep: u32 = 0;
            var ok = true;
            while (rep < 6) : (rep += 1) {
                console.out.print("[weir] diag: read #{d} start\n", .{rep}) catch {};
                ok = dev0.readBlocks(rep, 1, one[0..]);
                const bt2 = p_beat.*;
                console.out.print("[weir] diag: read #{d} done ok={} beats={d} data0=0x{x}\n", .{ rep, ok, bt2, @as(*u32, @ptrCast(@alignCast(&one[0]))).* }) catch {};
                if (!ok) break;
            }
            const bt = p_beat.*;
            const aw = p_ackwait.*;
            const ds = p_datstall.*;
            const ac = p_active.*;
            console.out.print("[weir] diag: 1blk ok={} beats={d} ackwait={d} datstall={d} active={d} ackwait_per_beat={d}\n", .{ ok, bt, aw, ds, ac, if (bt != 0) aw / bt else 0 }) catch {};
        }

        // SD-clock sweep. Read the same 32 blocks at falling SD clocks. If the
        // time is FLAT across the sweep, the ADMA drain gates the transfer, not
        // SD delivery (the ADMA is the wall). If it scales with the clock, SD
        // delivery is the limit. SD clock = fabric(20MHz) / (2*(div+1)).
        {
            var one: [512]u8 = undefined;
            const clkdiv: *volatile u32 = @ptrFromInt(0x10001010);
            const divs = [_]u32{ 0, 1, 3, 7 };
            for (divs) |d| {
                clkdiv.* = d;
                var okall = true;
                const t0 = clint.time();
                var b: u32 = 0;
                while (b < 8) : (b += 1) {
                    // DIAG: a print here is a ~4ms gap between back-to-back reads.
                    // If this makes the tight loop stop hanging, the deadlock is
                    // "cyc must drop between transactions" (l1_cache.dart:586).
                    console.out.print("[weir] diag: clksweep div={d} blk {d} start\n", .{ d, b }) catch {};
                    if (!dev0.readBlocks(b, 1, one[0..])) okall = false;
                }
                const t1 = clint.time();
                const us = if (soc.timebase_hz != 0) (t1 -% t0) * 1000000 / soc.timebase_hz else 0;
                console.out.print("[weir] clksweep div={d} (~{d} MHz): {d} us/blk ok={}\n", .{ d, 20 / (2 * (d + 1)), us / 8, okall }) catch {};
            }
            clkdiv.* = 0;
        }
        var one: [512]u8 = undefined;
        var b: u32 = 0;
        while (b < 8) : (b += 1) {
            const t0 = clint.time();
            const ok1 = dev0.readBlocks(b, 1, one[0..]);
            const t1 = clint.time();
            const ms = if (soc.timebase_hz != 0) (t1 -% t0) * 1000 / soc.timebase_hz else 0;
            console.out.print("[weir] sd:   blk {d}: {d} ms ok={}\n", .{ b, ms, ok1 }) catch {};
            if (!ok1) break;
        }

        // Multi-block chunk sweep. Read n blocks in one readBlocks call (one CMD18
        // multi-block transfer for n <= CHUNK_BLOCKS) and time it, for growing n.
        // This finds where the controller stops handling a continuous multi-block
        // read and how the per-block cost falls as command overhead amortises.
        // Each line prints before the next size, so the last line before a reset
        // marks the largest working chunk. Reads into free high DRAM at 0x88000000.
        {
            const dst: [*]u8 = @ptrFromInt(0x88000000);
            const sizes = [_]u32{ 1, 2, 4, 8, 16, 32, 48, 63 };
            for (sizes) |nblk| {
                console.out.print("[weir] sd: mblk n={d}: start\n", .{nblk}) catch {};
                const t0 = clint.time();
                const okm = dev0.readBlocks(0, nblk, dst[0 .. nblk * 512]);
                const t1 = clint.time();
                const us = if (soc.timebase_hz != 0) (t1 -% t0) * 1000000 / soc.timebase_hz else 0;
                const us_per = us / nblk;
                console.out.print("[weir] sd: mblk n={d}: {d} us total, {d} us/blk ok={}\n", .{ nblk, us, us_per, okm }) catch {};
                if (!okm) break;
            }
        }

        // Read-integrity check: read the same range TWICE and compare. Any
        // mismatch means the DMA read path returns non-deterministic data, which
        // would corrupt the systemd-boot binary and explain the intermittent boot
        // failures (null GUID, bad fn pointer, smashed canary).
        {
            const N = 16;
            var a: [N * 512]u8 = undefined;
            var c: [N * 512]u8 = undefined;
            const ra = dev0.readBlocks(0, N, a[0..]);
            const rc = dev0.readBlocks(0, N, c[0..]);
            var mism: u32 = 0;
            var first: i64 = -1;
            for (a, c, 0..) |x, y, off| {
                if (x != y) {
                    mism += 1;
                    if (first < 0) first = @intCast(off);
                }
            }
            console.out.print(
                "[weir] sd: integrity: 2x read {d} blk ok={},{} mismatches={d} first@{d}\n",
                .{ N, ra, rc, mism, first },
            ) catch {};
        }
    }

    console.out.writeAll("[weir] sd: probe done\n") catch {};
}

/// The S-mode entry point and the two arguments to hand it (a0, a1).
pub const Handoff = struct {
    entry: usize,
    a0: usize,
    a1: usize,
};

// Firmware-resident DTB copy. Weir hands it to an EFI app in reserved low RAM.
// Only the UEFI/PE and boot-manager handoff paths use it, through stableDtb. A
// size of 0 when none are enabled keeps it out of the zeroed bss.
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
        console.err.print("[uefi] PE load failed: {s}\n", .{@errorName(err)}) catch {};
        return null;
    };
    const table = uefi.prepare(stableDtb(dtb), hartid, loaded.base, loaded.size);
    console.out.print(
        "[uefi] PE entry @ {x} (base {x}, {d} bytes), system table @ {x}\n",
        .{ loaded.entry, loaded.base, loaded.size, table },
    ) catch {};
    return .{ .entry = loaded.entry, .a0 = @intFromPtr(uefi.imageHandle()), .a1 = table };
}

// Cap on a raw disk image read into high RAM. A bare boot PE is small; this
// bounds the read off a slow card and reuses the boot manager's staging region.
const raw_image_max: usize = 16 << 20;

/// Load a PE that sits as a bare image at sector 0, with no ESP or filesystem.
/// It walks the same device-tree storage list the boot manager uses, so a virtio
/// disk, a native SD host, and an SD card in SPI mode all get the same try. It is
/// not tied to one transport. Returns null when no device holds a raw PE.
fn loadRawImage(hartid: usize, dtb: usize) ?Handoff {
    if (!storage.init()) return null;
    const buf = @as([*]u8, @ptrFromInt(mem.kernel_read_base))[0..raw_image_max];
    for (storage.devices(), 0..) |d, i| {
        // Read sector 0 and check the DOS/PE 'MZ' magic before Weir reads a whole
        // image off a slow card.
        var lba0: [512]u8 = undefined;
        if (!d.dev.readBlocks(0, 1, lba0[0..])) continue;
        if (lba0[0] != 'M' or lba0[1] != 'Z') continue;

        var sectors: u64 = raw_image_max / 512;
        if (sectors > d.dev.num_blocks) sectors = d.dev.num_blocks;
        if (!d.dev.readBlocks(0, @intCast(sectors), buf)) {
            console.err.print("[loader] device {d}: raw image read failed\n", .{i}) catch {};
            continue;
        }
        const n: usize = @intCast(sectors * 512);
        console.out.print("[loader] device {d}: raw PE image, {d} bytes\n", .{ i, n }) catch {};
        if (enterPe(buf[0..n], hartid, dtb)) |h| return h;
    }
    return null;
}

/// No bootable payload exists, or the one found failed to load. There is no
/// built-in fallback, so report it and park the hart.
fn noBoot() noreturn {
    console.err.writeAll("[weir] no bootable payload found, halting\n") catch {};
    cpu.halt();
}

/// Resolve the S-mode handoff, either a UEFI app under an EFI System Table or
/// an ELF payload. Weir tries the boot sources in priority order. A boot manager
/// that finds nothing falls back to an embedded payload. If every source fails,
/// halt. See noBoot.
pub fn handoff(hartid: usize, dtb: usize) Handoff {
    console.out.writeAll("[weir] handoff: entered\n") catch {};

    // The device tree Weir hands the OS: the embedded -Ddtb tree when present (it
    // carries Weir's own SoC view and any fix-ups), else the pointer the previous
    // stage passed in a1. Both the UEFI configuration table (DEVICE_TREE_GUID)
    // and the payload a1 use this, so the tree reaches the OS even when a1 was
    // null or a stale FSBL pointer. Linux on RISC-V prefers the DT and panics
    // (no CPU nodes) without it.
    const dtb_eff = if (config.dtb) |d| @intFromPtr(d.ptr) else dtb;

    // Publish an initramfs when embedded, so the Linux EFI stub can fetch it.
    if (config.initrd) |img| {
        console.out.print("[initrd] serving {d} bytes via LoadFile2\n", .{img.len}) catch {};
        initrd.install(img);
    }

    if (config.boot_manager) {
        console.out.writeAll(
            "[boot] boot manager: searching the ESP for a bootable EFI app\n",
        ) catch {};
        if (manager.loadBootImage()) |loaded| {
            const table = uefi.prepare(stableDtb(dtb_eff), hartid, loaded.base, loaded.size);
            console.out.print(
                "[uefi] PE entry @ {x} (base {x}, {d} bytes), system table @ {x}\n",
                .{ loaded.entry, loaded.base, loaded.size, table },
            ) catch {};
            return .{ .entry = loaded.entry, .a0 = @intFromPtr(uefi.imageHandle()), .a1 = table };
        }
        console.out.writeAll("[boot] nothing bootable here, trying the next source\n") catch {};
    }

    if (config.disk_boot) {
        console.out.writeAll("[loader] searching storage for a raw boot PE\n") catch {};
        if (loadRawImage(hartid, dtb_eff)) |h| return h;
        console.out.writeAll("[loader] no raw boot PE on any disk\n") catch {};
    }

    if (config.pe_app) |image| {
        console.out.print(
            "[uefi] loading PE/COFF EFI application, {d} bytes\n",
            .{image.len},
        ) catch {};
        if (enterPe(image, hartid, dtb_eff)) |h| return h;
    }

    if (config.payload) |image| {
        console.out.print(
            "[loader] loading embedded S-mode payload, {d} bytes\n",
            .{image.len},
        ) catch {};
        const entry = elf.load(image) catch |err| {
            console.err.print("[loader] ELF load failed: {s}\n", .{@errorName(err)}) catch {};
            noBoot();
        };
        // Hand the payload the same resolved tree (dtb_eff). The raw a1 dtb is a
        // null or stale FSBL pointer on this SoC, which sent the payload to a bad
        // address and hung it.
        console.out.print(
            "[loader] payload entry @ {x}, dtb @ {x}\n",
            .{ entry, dtb_eff },
        ) catch {};
        return .{ .entry = entry, .a0 = hartid, .a1 = dtb_eff };
    }

    noBoot();
}
