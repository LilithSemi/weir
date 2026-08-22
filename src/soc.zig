//! SoC parameters. conduit's Builder discovers them from the embedded device
//! tree at comptime. Everything here bakes into the binary. Weir and the FSBL do
//! no runtime device lookup. The addresses are known at compile time, so boot
//! pays zero discovery cost. The same tree drives the linker base in build.zig,
//! so the layout and the link address stay in sync. With no -Ddtb, these fall
//! back to the common addresses.

const std = @import("std");
const conduit = @import("conduit");
const has_dt = @import("build_options").has_dtb;

// One matcher per SoC device class that Weir bakes in. conduit walks the
// embedded DTB once at comptime. It lowers each matched node's reg into an MMIO
// resource, and its clock frequency into a Clock resource.
const matchers = [_]conduit.Matcher{
    .{ .class = .uart, .dt_compatible = &.{ "ns16550a", "ns16550", "snps,dw-apb-uart" } },
    .{ .class = .timer, .dt_compatible = &.{ "riscv,clint0", "sifive,clint0" } },
    // The /memory node has no compatible property. conduit exposes its device_type.
    .{ .class = .memory, .dt_compatible = &.{"memory"} },
    .{ .class = .flash, .dt_compatible = &.{"jedec,spi-nor"} },
    .{ .class = .sdram, .dt_compatible = &.{ "harbor,ddr3-sdram", "harbor,sdram-controller" } },
    .{ .class = .tpm, .dt_compatible = &.{ "tcg,tpm-tis-mmio", "tcg,tpm-tis" } },
    // A goldfish RTC (QEMU virt). Only this RTC IP is matched today, so time.zig
    // binds it directly. A new RTC needs its compatible here and a bind arm there.
    .{ .class = .rtc, .dt_compatible = &.{"google,goldfish-rtc"} },
    // A native SD/MMC host, or a virtio-mmio transport (QEMU). Both are the
    // `.block` class; storage.zig picks the driver by the matched compatible.
    .{ .class = .block, .dt_compatible = &.{ "harbor,sdhci", "harbor,sdio", "virtio,mmio" } },
    // The external interrupt controller (PLIC), for the ACPI MADT.
    .{ .class = .intc, .dt_compatible = &.{ "riscv,plic0", "sifive,plic-1.0.0" } },
    // A Harbor SPI master. On creek it carries an SD card in SPI mode (PmodSD).
    // storage.zig probes it for a card when there is no native SD host.
    .{ .class = .spi, .dt_compatible = &.{ "harbor,spi", "midstall,harbor-spi" } },
};

// The baked device table. Comptime only, and empty if no -Ddtb was embedded.
/// Every device conduit matched in the tree, with resolved resources (MMIO,
/// IRQ, clock) and the node's compatible ids. acpi.zig translates these into the
/// DSDT; the accessors below pull single values out.
pub const devices: []const conduit.Match = if (has_dt) blk: {
    @setEvalBranchQuota(4_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch
        @compileError("soc_dtb: invalid device tree");
    var be = conduit.backend.dtree.DtBackend.init(&rd);
    break :blk conduit.Builder.scan(&be, &matchers);
} else &.{};

fn firstMmio(class: conduit.Class) ?conduit.Resource.MmioRegion {
    @setEvalBranchQuota(4_000_000);
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (m.mmio()) |r| return r;
    return null;
}
fn firstClockHz(class: conduit.Class) ?u64 {
    @setEvalBranchQuota(4_000_000);
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (m.clock()) |c| return c.freq_hz;
    return null;
}

// Two devices can share a class (a native SD host and virtio are both `.block`),
// so these filter by the matched compatible as well.
fn hasId(m: *const conduit.Match, ids: []const []const u8) bool {
    for (m.ids.slice()) |x|
        for (ids) |want|
            if (std.mem.eql(u8, x, want)) return true;
    return false;
}
fn firstMmioId(class: conduit.Class, ids: []const []const u8) ?conduit.Resource.MmioRegion {
    @setEvalBranchQuota(4_000_000);
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (hasId(m, ids)) if (m.mmio()) |r| return r;
    return null;
}
fn firstClockHzId(class: conduit.Class, ids: []const []const u8) ?u64 {
    @setEvalBranchQuota(4_000_000);
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (hasId(m, ids)) if (m.clock()) |c| return c.freq_hz;
    return null;
}
fn countMmioId(class: conduit.Class, ids: []const []const u8) usize {
    @setEvalBranchQuota(4_000_000);
    var n: usize = 0;
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (hasId(m, ids)) {
        if (m.mmio()) |_| n += 1;
    };
    return n;
}

const sdhci_ids = [_][]const u8{ "harbor,sdhci", "harbor,sdio" };
const virtio_ids = [_][]const u8{"virtio,mmio"};

pub const uart_base: usize = if (firstMmio(.uart)) |r| @intCast(r.base) else 0x10000000;
pub const uart_clock: usize = if (firstClockHz(.uart)) |hz| @intCast(hz) else 24000000;
pub const clint_base: usize = if (firstMmio(.timer)) |r| @intCast(r.base) else 0x2000000;
// CLINT mtime tick rate (the RISC-V timebase-frequency). Used to turn elapsed
// timer ticks into seconds for the software wall clock. QEMU virt runs at 10 MHz.
pub const timebase_hz: u64 = if (firstClockHz(.timer)) |hz| hz else 10_000_000;

// A real-time clock, if the platform has one. 0 base means none, and time.zig
// falls back to a software clock from the UNIX epoch.
const rtc_mmio = firstMmio(.rtc);
pub const rtc_present: bool = rtc_mmio != null;
pub const rtc_base: usize = if (rtc_mmio) |r| @intCast(r.base) else 0;
pub const ram_base: usize = if (firstMmio(.memory)) |r| @intCast(r.base) else 0x80000000;
pub const ram_size: usize = if (firstMmio(.memory)) |r| @intCast(r.size) else 0x10000000;
pub const flash_base: usize = if (firstMmio(.flash)) |r| @intCast(r.base) else 0x20000000;

const tpm_mmio = firstMmio(.tpm);
pub const tpm_present: bool = tpm_mmio != null;
pub const tpm_base: usize = if (tpm_mmio) |r| @intCast(r.base) else 0x04000000;

// The PLIC (external interrupt controller), used to build the ACPI MADT.
const plic_mmio = firstMmio(.intc);
pub const plic_base: usize = if (plic_mmio) |r| @intCast(r.base) else 0x0c000000;
pub const plic_size: usize = if (plic_mmio) |r| @intCast(r.size) else 0x0400_0000;

// The boot hart's ISA string, read from the device tree (/cpus/cpu@N's
// `riscv,isa`) for the ACPI RHCT. An OS validates it against the hardware, so it
// must be the real string (e.g. QEMU's long rv64imafdc_zicsr_... form), never an
// assumption. Falls back to the mandatory base when no tree is embedded.
pub const cpu_isa: []const u8 = if (has_dt) readCpuIsa() else "rv64imac_zicsr_zifencei";

fn readCpuIsa() []const u8 {
    @setEvalBranchQuota(8_000_000);
    const fallback = "rv64imac_zicsr_zifencei";
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return fallback;
    var it = rd.nodeIterator();
    var in_cpu = false;
    while (it.next() catch return fallback) |node| switch (node) {
        .begin => |bg| in_cpu = std.mem.startsWith(u8, bg.name, "cpu@"),
        .prop => |p| if (in_cpu and std.mem.eql(u8, p.name, "riscv,isa")) {
            // The property is a null-terminated string; drop the terminator.
            const v = p.value;
            return if (v.len > 0 and v[v.len - 1] == 0) v[0 .. v.len - 1] else v;
        },
        .end => {},
    };
    return fallback;
}

// The hart's virtual-memory scheme, read from the device tree (cpu node's
// `mmu-type`), for the ACPI RHCT MMU node. An OS needs it to set up paging.
// 0 = Sv39, 1 = Sv48, 2 = Sv57.
pub const mmu_type: u8 = if (has_dt) readMmuType() else 0;

fn readMmuType() u8 {
    @setEvalBranchQuota(8_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return 0;
    var it = rd.nodeIterator();
    var in_cpu = false;
    while (it.next() catch return 0) |node| switch (node) {
        .begin => |bg| in_cpu = std.mem.startsWith(u8, bg.name, "cpu@"),
        .prop => |p| if (in_cpu and std.mem.eql(u8, p.name, "mmu-type")) {
            const v = p.value;
            if (std.mem.indexOf(u8, v, "sv57") != null) return 2;
            if (std.mem.indexOf(u8, v, "sv48") != null) return 1;
            return 0; // sv39
        },
        .end => {},
    };
    return 0;
}

// The QEMU fw-cfg MMIO base, read from the device tree (`qemu,fw-cfg-mmio`).
// Weir pulls the machine's own ACPI tables through it (see acpi/qemu.zig). It is
// not a conduit device class, so read it straight from the tree. Zero when no
// fw-cfg node is present (a real River SoC has none). The base is the node's
// reg address; QEMU's virt tree uses two address cells, so it is reg[0..8].
pub const fwcfg_base: usize = if (has_dt) readFwcfgBase() else 0;

fn readFwcfgBase() usize {
    @setEvalBranchQuota(8_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return 0;
    var it = rd.nodeIterator();
    var in_fwcfg = false;
    while (it.next() catch return 0) |node| switch (node) {
        .begin => |bg| in_fwcfg = std.mem.startsWith(u8, bg.name, "fw-cfg@"),
        .prop => |p| if (in_fwcfg and std.mem.eql(u8, p.name, "reg") and p.value.len >= 8) {
            return @intCast(std.mem.readInt(u64, p.value[0..8], .big));
        },
        .end => {},
    };
    return 0;
}

// DDR read-training control window. Harbor decodes it in the top trainCtrlSize
// (0x1000) bytes of the sdram controller's region. So the window base is the
// controller base plus the controller size minus trainCtrlSize. Zero means no
// CPU training window is present. The FSBL then takes the static no-training
// path.
const ddr_train_ctrl_size: usize = 0x1000; // == HarborDdrController.trainCtrlSize
const sdram_mmio = firstMmio(.sdram);
pub const ddr_train_base: usize =
    if (sdram_mmio) |r| @intCast(r.base + r.size - ddr_train_ctrl_size) else 0;

// SD/MMC host, River's block device. Absent on creek. 0 means none.
pub const sdhci_base: usize = if (firstMmioId(.block, &sdhci_ids)) |r| @intCast(r.base) else 0;
pub const sdhci_freq: u32 =
    if (firstClockHzId(.block, &sdhci_ids)) |hz| @intCast(hz) else 50_000_000;

// virtio-mmio transports from the device tree. A transport carries a block or
// other device; the class is read from its registers at boot, so storage.zig
// probes each for a block device. QEMU virt lays out 8; a real board may have 0.
// base+size+irq feed both the runtime probe and the generated DSDT (aml.zig).
pub const VirtioDev = struct { base: usize, size: usize, irq: u32 };
pub const virtio_count: usize = countMmioId(.block, &virtio_ids);
const virtio_devices_arr: [virtio_count]VirtioDev = blk: {
    @setEvalBranchQuota(4_000_000);
    var arr: [virtio_count]VirtioDev = undefined;
    var i: usize = 0;
    var it = conduit.discover.ofClass(devices, .block);
    while (it.next()) |m| if (hasId(m, &virtio_ids)) {
        if (m.mmio()) |r| {
            arr[i] = .{
                .base = @intCast(r.base),
                .size = @intCast(r.size),
                .irq = if (m.irq(0)) |q| q.number else 0,
            };
            i += 1;
        }
    };
    break :blk arr;
};
pub const virtio_devices: []const VirtioDev = &virtio_devices_arr;

// SPI masters that can carry an SD card in SPI mode. The device tree can
// declare more than one, so Weir bakes the full list and probes each at boot.
// One SPI IP exists today (Harbor). A new IP needs a new SoC matcher and a new
// SpiIp tag, and storage.zig gains an arm to bind it.
pub const SpiIp = enum { harbor };
// `dma` is set when the controller declares the `harbor,dma` capability in the
// device tree (or its ACPI _DSD). storage.zig passes it to the SD driver, which
// then uses the block DMA engine instead of the polled byte loop.
pub const SpiController = struct { base: usize, ip: SpiIp, dma: bool = false };

fn countMmio(class: conduit.Class) usize {
    @setEvalBranchQuota(4_000_000);
    var n: usize = 0;
    var it = conduit.discover.ofClass(devices, class);
    while (it.next()) |m| if (m.mmio()) |_| {
        n += 1;
    };
    return n;
}

/// Number of SPI masters in the device tree. Zero under QEMU (no SPI node).
pub const spi_count: usize = countMmio(.spi);

// The SPI masters, in device-tree order. Sized exactly to the tree, so an empty
// tree costs no storage. All Weir SoC `.spi` matches are Harbor today.
const spi_controllers_arr: [spi_count]SpiController = blk: {
    @setEvalBranchQuota(4_000_000);
    var arr: [spi_count]SpiController = undefined;
    var i: usize = 0;
    var it = conduit.discover.ofClass(devices, .spi);
    while (it.next()) |m| if (m.mmio()) |r| {
        arr[i] = .{ .base = @intCast(r.base), .ip = .harbor, .dma = m.hasFlag("harbor,dma") };
        i += 1;
    };
    break :blk arr;
};

/// Every SPI master, in device-tree order. A slice so callers index it with a
/// runtime value even when the tree declares none.
pub const spi_controllers: []const SpiController = &spi_controllers_arr;

// Native SD/MMC hosts (HarborSdioController). Like the SPI masters, the device
// tree can declare more than one, so Weir bakes the full list and probes each at
// boot. `freq` is the controller input clock, from the node's clock-frequency
// (the SD clock divider derives from it); it falls back to 50 MHz when the node
// omits it. Absent on creek. `sdhci_base`/`sdhci_freq` above stay as the first
// host, for callers that only want one.
pub const SdhciController = struct { base: usize, freq: u32 };

/// Number of native SD/MMC hosts in the device tree.
pub const sdhci_count: usize = countMmioId(.block, &sdhci_ids);

const sdhci_controllers_arr: [sdhci_count]SdhciController = blk: {
    @setEvalBranchQuota(4_000_000);
    var arr: [sdhci_count]SdhciController = undefined;
    var i: usize = 0;
    var it = conduit.discover.ofClass(devices, .block);
    while (it.next()) |m| if (hasId(m, &sdhci_ids)) {
        if (m.mmio()) |r| {
            arr[i] = .{
                .base = @intCast(r.base),
                .freq = if (m.clock()) |c|
                    (if (c.freq_hz) |hz| @as(u32, @intCast(hz)) else 50_000_000)
                else
                    50_000_000,
            };
            i += 1;
        }
    };
    break :blk arr;
};

/// Every native SD/MMC host, in device-tree order.
pub const sdhci_controllers: []const SdhciController = &sdhci_controllers_arr;
