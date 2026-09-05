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
const conduit = @import("conduit");

/// Build the table set referencing `dsdt` (raw AML) and report a summary. No
/// paging here, so virtual == physical and the pool base is a plain address.
pub fn setup(dsdt: ?[]const u8) void {
    build(dsdt) catch {
        console.err.writeAll("[acpi] table construction failed (buffer too small)\n") catch {};
    };
}

/// SPCR body (after the 36-byte SDT header): a full-16550 console at `uart_base`,
/// byte-wide registers, 115200 8N1, polled.
fn spcrBody(uart_base: u64) [44]u8 {
    var b = [_]u8{0} ** 44;
    b[0] = 0x00; // interface type: full 16550
    b[4] = 0x00; // base address GAS: system memory
    b[5] = 8; // register bit width
    b[7] = 1; // access size: byte
    std.mem.writeInt(u64, b[8..16], uart_base, .little);
    b[22] = 7; // baud rate: 115200
    b[24] = 1; // stop bits: 1
    std.mem.writeInt(u16, b[28..30], 0xFFFF, .little); // not a PCI device
    std.mem.writeInt(u16, b[30..32], 0xFFFF, .little); // not a PCI vendor
    return b;
}

/// MADT body: local interrupt controller address and flags, then one RINTC per
/// hart and the PLIC. Single hart for now (creek/virt -smp 1).
fn madtBody(hart_id: u64, plic_base: u64, plic_size: u32) [80]u8 {
    var b = [_]u8{0} ** 80;
    // b[0..4] local interrupt controller address, b[4..8] flags: both 0.
    // RINTC (type 0x18) at b[8..44].
    b[8] = 0x18; // type: RISC-V INTC
    b[9] = 36; // length
    b[10] = 1; // version
    std.mem.writeInt(u32, b[12..16], 1, .little); // flags: enabled
    std.mem.writeInt(u64, b[16..24], hart_id, .little);
    // b[24..28] ACPI processor UID, b[28..32] external interrupt controller id,
    // b[32..40] IMSIC base, b[40..44] IMSIC size: all 0 (a PLIC system).
    // PLIC (type 0x1B) at b[44..80].
    b[44] = 0x1b; // type: PLIC
    b[45] = 36; // length
    b[46] = 1; // version
    b[47] = 0; // PLIC ID
    // b[48..56] hardware id: 0.
    std.mem.writeInt(u16, b[56..58], 1023, .little); // total external sources
    std.mem.writeInt(u16, b[58..60], 7, .little); // max priority
    std.mem.writeInt(u32, b[64..68], plic_size, .little); // register space size
    std.mem.writeInt(u64, b[68..76], plic_base, .little); // PLIC address
    // b[76..80] global system interrupt vector base: 0.
    return b;
}

/// Build the RHCT body into `buf`: the hart timebase, then an ISA-string node,
/// an MMU node (the paging scheme the OS needs before it can enable paging), and
/// a hart-info node referencing both. Node offsets are relative to the table
/// start (header + 20 = 56). Returns the used bytes (variable ISA length).
fn buildRhct(buf: []u8, timebase: u64, isa: []const u8, mmu_type: u8) []const u8 {
    @memset(buf, 0);
    // buf[0..4] flags: 0.
    std.mem.writeInt(u64, buf[4..12], timebase, .little); // time base frequency
    std.mem.writeInt(u32, buf[12..16], 3, .little); // node count: ISA, MMU, hart info
    std.mem.writeInt(u32, buf[16..20], 56, .little); // offset of the first node
    // ISA string node (type 0) at body offset 20 (table offset 56).
    const isa_len = isa.len + 1; // include the null terminator
    const isa_node = (8 + isa_len + 1) & ~@as(usize, 1); // pad to 2 bytes
    std.mem.writeInt(u16, buf[20..22], 0, .little); // node type: ISA string
    std.mem.writeInt(u16, buf[22..24], @intCast(isa_node), .little);
    std.mem.writeInt(u16, buf[24..26], 1, .little); // revision
    std.mem.writeInt(u16, buf[26..28], @intCast(isa_len), .little); // ISA length
    @memcpy(buf[28..][0..isa.len], isa);
    // MMU node (type 2) after the ISA node.
    const m = 20 + isa_node; // body offset
    std.mem.writeInt(u16, buf[m..][0..2], 2, .little); // node type: MMU
    std.mem.writeInt(u16, buf[m + 2 ..][0..2], 8, .little); // node length
    std.mem.writeInt(u16, buf[m + 4 ..][0..2], 1, .little); // revision
    buf[m + 6] = 0; // reserved
    buf[m + 7] = mmu_type; // 0 = Sv39, 1 = Sv48, 2 = Sv57
    // Hart info node (type 0xFFFF) after the MMU node, referencing ISA and MMU.
    const h = m + 8;
    std.mem.writeInt(u16, buf[h..][0..2], 0xFFFF, .little); // node type: hart info
    std.mem.writeInt(u16, buf[h + 2 ..][0..2], 20, .little); // node length (12 + 2*4)
    std.mem.writeInt(u16, buf[h + 4 ..][0..2], 1, .little); // revision
    std.mem.writeInt(u16, buf[h + 6 ..][0..2], 2, .little); // number of offsets
    std.mem.writeInt(u32, buf[h + 8 ..][0..4], 0, .little); // ACPI processor UID
    std.mem.writeInt(u32, buf[h + 12 ..][0..4], 56, .little); // table offset of ISA node
    std.mem.writeInt(u32, buf[h + 16 ..][0..4], @intCast(36 + m), .little); // MMU node
    return buf[0 .. h + 20];
}

// Backing storage for the translated device list, filled from soc.devices and
// consumed by buildScope within the same call. Module-level to keep it off the
// stack. The DSDT AML body lands in dsdt_body.
const max_dsdt_devs = 24;
var dsdt_devs: [max_dsdt_devs]aml.Device = undefined;
var dsdt_mem: [max_dsdt_devs][4]aml.MemRegion = undefined;
var dsdt_irqs: [max_dsdt_devs][8]u32 = undefined;
var dsdt_props: [max_dsdt_devs][2]aml.Prop = undefined;
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
fn addClock(m: *const conduit.Match, props: *[2]aml.Prop, pi: *usize) void {
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
                    gsb = 0;
                },
                // The 16550 UART: the kernel's RISC-V 8250 ACPI driver binds
                // RSCV0003 and reads the baud clock from _DSD. (PRP0001/of_serial
                // does not bind it.)
                .uart => {
                    hid = "RSCV0003";
                    qi = addIrqs(m, &dsdt_irqs[n]);
                    addClock(m, &dsdt_props[n], &pi);
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

    const fadt_phys = try b.fadt(.{ .dsdt_phys = dsdt_phys, .hw_reduced = true });
    // The provided AML is only the DSDT, so build the tables an OS needs to run
    // in ACPI mode: MADT (harts + PLIC), RHCT (hart ISA/timebase), and SPCR (the
    // console). Without these an OS that sees the RSDP finds no CPUs and hangs.
    const madt = madtBody(0, soc.plic_base, @intCast(soc.plic_size));
    const madt_phys = try b.addTable("APIC", &madt, 6);
    var rhct_buf: [512]u8 = undefined;
    const rhct = buildRhct(&rhct_buf, soc.timebase_hz, soc.cpu_isa, soc.mmu_type);
    const rhct_phys = try b.addTable("RHCT", rhct, 1);
    const spcr = spcrBody(soc.uart_base);
    const spcr_phys = try b.addTable("SPCR", &spcr, 2);
    const xsdt_phys = try b.xsdt(&.{ fadt_phys, madt_phys, rhct_phys, spcr_phys });
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
