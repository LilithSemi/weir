//! ACPI table construction. The platform supplies the DSDT (raw AML) through
//! `-Daml`. Weir wraps it in the minimum HW-reduced RISC-V table set
//! (RSDP -> XSDT -> FADT, with FADT.X_DSDT pointing at the AML in place).
//! almanac's Builder lays the tables into the ACPI-reclaim pool and stamps every
//! checksum. The tables MUST sit in that pool (see mem.zig / qemu.zig): the EFI
//! memory map marks it EfiACPIReclaimMemory, so the OS maps and reads the tables.
//! Tables left in reserved firmware memory fault the OS's ACPI table setup
//! (Linux acpi_tb_init_table_descriptor) while it reads each table header.

const std = @import("std");
const almanac = @import("conduit").almanac;
const console = @import("../console/console.zig");
const soc = @import("soc");
const qemu = @import("qemu.zig");
const aml = @import("aml.zig");
const madt = @import("madt.zig");
const tables = @import("tables.zig");
const conduit = @import("conduit");
const early_display = @import("../display/early.zig");

/// Build the table set referencing `dsdt` (raw AML) and report a summary. No
/// paging here, so virtual == physical and the pool base is a plain address.
pub fn setup(dsdt: ?[]const u8) void {
    build(dsdt) catch {
        console.err.writeAll("[acpi] table construction failed (buffer too small)\n") catch {};
    };
}

// The PLIC's ACPI identity. One PLIC exists on every River SoC today, so it is
// PLIC 0 and it owns the global system interrupts from 0 up. `plic_gsi_base`
// must equal the `_GSB` the DSDT gives the same PLIC (see buildDsdt below): an
// OS matches the two to attach the MADT record to the DSDT device, and without
// a match it never probes the PLIC at all.
const plic_id: u8 = 0;
const plic_gsi_base: u32 = 0;

// Highest priority the Harbor PLIC accepts. It has 3 priority bits, and the
// device tree has no property for it, so it is stated here.
const plic_max_priority: u16 = 7;

// The PLIC's hardware ID, the same string as the DSDT device's _HID. The field
// is informational and no OS driver reads it, but a value is more use than zero
// to anyone dumping the table.
const plic_hw_id = "RSCV0001".*;

// The contexts the PLIC declares, in the layout the MADT builder wants.
const plic_contexts_arr: [soc.plic_contexts.len]madt.Context = blk: {
    var arr: [soc.plic_contexts.len]madt.Context = undefined;
    for (soc.plic_contexts, 0..) |c, i| arr[i] = .{ .hart_id = c.hart_id, .cause = c.cause };
    break :blk arr;
};

// One RINTC per hart, each naming the PLIC context that drives that hart's
// supervisor external interrupt. Weir owns the machine context, so it is never
// named here. Both the hart list and the context list come from the device
// tree, so they describe the interrupt wiring the SoC really has.
const madt_harts: [soc.hart_count]madt.Hart = blk: {
    var arr: [soc.hart_count]madt.Hart = undefined;
    for (soc.harts, 0..) |hart, i| arr[i] = .{
        .hart_id = hart,
        .uid = @intCast(i),
        .context = madt.supervisorContext(&plic_contexts_arr, hart),
    };
    break :blk arr;
};

var madt_buf: [madt.bodyLen(soc.hart_count)]u8 = undefined;

fn madtBody() []const u8 {
    return madt.build(&madt_buf, &madt_harts, .{
        .id = plic_id,
        .hw_id = plic_hw_id,
        .num_irqs = @intCast(soc.plic_ndev),
        .max_priority = plic_max_priority,
        .size = @intCast(soc.plic_size),
        .base = soc.plic_base,
        .gsi_base = plic_gsi_base,
    });
}

// Backing storage for the translated device list, filled from soc.devices and
// consumed by buildScope within the same call. Module-level to keep it off the
// stack. The DSDT AML body lands in dsdt_body.
const max_dsdt_devs = 24;
var dsdt_devs: [max_dsdt_devs]aml.Device = undefined;
var dsdt_mem: [max_dsdt_devs][4]aml.MemRegion = undefined;
var dsdt_irqs: [max_dsdt_devs][8]u32 = undefined;
// The most _DSD properties of one device: a UART has a clock, a register
// shift and a register width.
const max_props = 3;
var dsdt_props: [max_dsdt_devs][max_props]aml.Prop = undefined;
var dsdt_body: [8192]u8 = undefined;

fn digit(v: usize) u8 {
    return '0' + @as(u8, @intCast(v % 10));
}

/// The native RISC-V ACPI HID for an interrupt controller, from its compatible.
/// The kernel binds these directly and registers an irqchip, so device GSIs map.
fn intcHid(m: *const conduit.Match) []const u8 {
    for (m.ids.slice()) |id| {
        if (std.mem.indexOf(u8, id, "aplic") != null) return "RSCV0002"; // APLIC
    }
    return "RSCV0001"; // PLIC
}

/// Add a clock-frequency property from the node's clock, if it has one.
fn addClock(m: *const conduit.Match, props: *[max_props]aml.Prop, pi: *usize) void {
    if (m.clock()) |c| if (c.freq_hz) |hz| {
        props[pi.*] = .{ .key = "clock-frequency", .value = .{ .int = hz } };
        pi.* += 1;
    };
}

/// Add every interrupt (GSI) the node declares to its _CRS.
fn addIrqs(m: *const conduit.Match, irqs: *[8]u32) usize {
    var qi: usize = 0;
    while (qi < irqs.len) : (qi += 1) {
        const q = m.irq(qi) orelse break;
        irqs[qi] = q.number;
    }
    return qi;
}

/// Translate the device tree into the DSDT AML body when the platform supplies
/// none. Well-known RISC-V devices use their native ACPI HID so the kernel binds
/// them directly: the interrupt controller (RSCV0001 PLIC / RSCV0002 APLIC, with
/// a _GSB, which registers the irqchip) and the 16550 UART (RSCV0003). Every
/// other node becomes a PRP0001 device whose driver matches the _DSD "compatible"
/// property, the device-tree bridge. conduit already resolved each node's
/// resources and compatible ids (soc.devices).
fn buildDsdt() []u8 {
    var n: usize = 0;
    for ([_]conduit.Class{ .intc, .uart, .block }) |class| {
        var it = conduit.discover.ofClass(soc.devices, class);
        while (it.next()) |m| {
            if (n >= max_dsdt_devs) break;

            var mi: usize = 0;
            while (mi < dsdt_mem[n].len) : (mi += 1) {
                const r = m.mmioAt(mi) orelse break;
                dsdt_mem[n][mi] = .{ .base = @intCast(r.base), .size = @intCast(r.size) };
            }

            var qi: usize = 0;
            var pi: usize = 0;
            var hid: []const u8 = "PRP0001";
            var gsb: ?u32 = null;
            switch (class) {
                // The interrupt controller: source of interrupts, no _DSD. Its
                // native HID + _GSB is what registers the irqchip.
                .intc => {
                    hid = intcHid(m);
                    gsb = plic_gsi_base;
                },
                // The 16550 UART: the kernel's RISC-V 8250 ACPI driver binds
                // RSCV0003 and reads the baud clock from _DSD. (PRP0001/of_serial
                // does not bind it.)
                .uart => {
                    hid = "RSCV0003";
                    qi = addIrqs(m, &dsdt_irqs[n]);
                    addClock(m, &dsdt_props[n], &pi);
                    if (m.mmio()) |r| if (r.base == soc.uart_base and soc.uart_io_width != 1) {
                        dsdt_props[n][pi] = .{ .key = "reg-shift", .value = .{ .int = soc.uart_reg_shift } };
                        dsdt_props[n][pi + 1] = .{ .key = "reg-io-width", .value = .{ .int = soc.uart_io_width } };
                        pi += 2;
                    };
                },
                // Everything else: the PRP0001 device-tree bridge.
                else => {
                    qi = addIrqs(m, &dsdt_irqs[n]);
                    dsdt_props[n][pi] = .{ .key = "compatible", .value = .{ .strs = m.ids.slice() } };
                    pi += 1;
                    addClock(m, &dsdt_props[n], &pi);
                },
            }

            dsdt_devs[n] = .{
                .name = .{ 'D', digit(n / 100), digit(n / 10), digit(n) },
                .uid = @intCast(n),
                .hid = hid,
                .gsb = gsb,
                .mem = dsdt_mem[n][0..mi],
                .irqs = dsdt_irqs[n][0..qi],
                .props = dsdt_props[n][0..pi],
            };
            n += 1;
        }
    }
    return aml.buildScope(&dsdt_body, dsdt_devs[0..n]);
}

fn build(dsdt: ?[]const u8) !void {
    // Lay the tables into the ACPI-reclaim pool, not a static buffer, so the OS
    // maps and reads them. See the file header.
    const pool: [*]u8 = @ptrFromInt(qemu.POOL_BASE);
    const buf = pool[0..qemu.POOL_SIZE];
    const base = qemu.POOL_BASE;
    var b = almanac.Builder.init(buf, base);
    b.oem_id = "LILSMI".*;
    b.oem_table_id = "WEIR    ".*;
    b.creator_id = "WEIR".*;

    // Copy the provided AML (DSDT) into the pool and point X_DSDT at the copy.
    // The embedded blob lives in reserved firmware rodata, which the OS cannot
    // map for ACPI; the pool is EfiACPIReclaimMemory.
    //
    // ACPICA (acpi_tb_parse_fadt) always installs the DSDT the FADT names and
    // reads its header, so the FADT must point at a real, backed table. With no
    // AML, translate the device tree into the DSDT: without device objects the OS
    // enumerates nothing (pnp: found 0 devices), so console=ttyS0 points at a tty
    // that never registers and the disks never appear.
    const dsdt_phys: u64 = if (dsdt) |d| try b.addRaw(d) else try b.addTable("DSDT", buildDsdt(), 2);

    // ACPI 6.6 (revision 6, minor version 6). It is the first revision that
    // defines the RISC-V RINTC and PLIC structures the MADT below carries, so
    // an older claimed revision would not describe the table Weir writes.
    const fadt_phys = try b.fadt(.{
        .dsdt_phys = dsdt_phys,
        .hw_reduced = true,
        .minor_version = 6,
    });
    // The provided AML is only the DSDT, so build the tables an OS needs to run
    // in ACPI mode: MADT (harts + PLIC), RHCT (hart ISA/timebase), and SPCR (the
    // console). Without these an OS that sees the RSDP finds no CPUs and hangs.
    const madt_phys = try b.addTable("APIC", madtBody(), madt.revision);
    var rhct_buf: [512]u8 = undefined;
    const rhct = tables.rhct(&rhct_buf, soc.timebase_hz, soc.cpu_isa, soc.mmu_type);
    const rhct_phys = try b.addTable("RHCT", rhct, 1);
    const spcr = tables.spcr(soc.uart_base, soc.uart_io_width);
    const spcr_phys = try b.addTable("SPCR", std.mem.asBytes(&spcr), 2);
    var entries = [_]u64{ fadt_phys, madt_phys, rhct_phys, spcr_phys, 0 };
    var count: usize = 4;
    if (bootGraphics(&b)) |bgrt_phys| {
        entries[count] = bgrt_phys;
        count += 1;
    }
    const xsdt_phys = try b.xsdt(entries[0..count]);
    const rsdp_phys = try b.rsdp(xsdt_phys);
    // Publish through the shared RSDP accessor, the same one the UEFI config
    // table reads, so the OS finds these tables.
    qemu.setRsdp(@intCast(rsdp_phys));

    console.out.print("[acpi] RSDP @ {x}\n", .{rsdp_phys}) catch {};
    console.out.print("[acpi] XSDT @ {x}, FADT @ {x}\n", .{ xsdt_phys, fadt_phys }) catch {};
    console.out.print(
        "[acpi] MADT @ {x}, RHCT @ {x}, SPCR @ {x} (16550 @ {x}, PLIC @ {x})\n",
        .{ madt_phys, rhct_phys, spcr_phys, soc.uart_base, soc.plic_base },
    ) catch {};
    console.out.print(
        "[acpi] MADT: {d} hart(s), PLIC {d} sources, GSI base {d}, S-context {?d}\n",
        .{ madt_harts.len, soc.plic_ndev, plic_gsi_base, madt_harts[0].context },
    ) catch {};

    if (dsdt) |d| {
        // The AML blob is itself an SDT: signature[4], length at offset 4.
        const sig = d[0..4];
        const len = std.mem.readInt(u32, d[4..8], .little);
        console.out.print(
            "[acpi] DSDT @ {x}: '{s}', {d} bytes (provided AML)\n",
            .{ dsdt_phys, sig, len },
        ) catch {};
    } else {
        console.out.print(
            "[acpi] no AML provided. DSDT @ {x} translated from the device tree\n",
            .{dsdt_phys},
        ) catch {};
    }

    reportChecksums(rsdp_phys, xsdt_phys, fadt_phys);
}

// The BGRT names the splash, so the OS can keep it on the screen while it
// starts. The BMP goes to the ACPI pool, which the OS maps and keeps until it
// has read the tables.
fn bootGraphics(b: *almanac.Builder) ?u64 {
    const offset = early_display.shownSplash() orelse return null;
    const image_phys = b.addRaw(early_display.splashFile()) catch {
        console.out.writeAll("[acpi] no BGRT, the splash does not fit in the ACPI pool\n") catch {};
        return null;
    };
    const body = tables.bgrt(image_phys, offset.x, offset.y);
    const table_phys = b.addTable("BGRT", std.mem.asBytes(&body), 1) catch return null;
    console.out.print("[acpi] BGRT @ {x}, image @ {x}\n", .{ table_phys, image_phys }) catch {};
    return table_phys;
}

fn reportChecksums(rsdp_phys: u64, xsdt_phys: u64, fadt_phys: u64) void {
    const rsdp_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(rsdp_phys)));
    const xsdt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(xsdt_phys)));
    const fadt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(fadt_phys)));
    const ok_rsdp = almanac.checksum.valid(rsdp_b[0..36]);
    const xsdt_len = std.mem.readInt(u32, xsdt_b[4..8], .little);
    const ok_xsdt = almanac.checksum.valid(xsdt_b[0..xsdt_len]);
    const ok_fadt = almanac.checksum.valid(fadt_b[0..276]); // ACPI 6.x FADT
    console.out.print(
        "[acpi] checksums: RSDP={s} XSDT={s} FADT={s}\n",
        .{ okStr(ok_rsdp), okStr(ok_xsdt), okStr(ok_fadt) },
    ) catch {};
}

fn okStr(ok: bool) []const u8 {
    return if (ok) "ok" else "FAIL";
}
