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
// The UART's own baud clock, which console.zig divides to get the divisor. This
// one IS a device clock, so the node's `clock-frequency` is the right source.
// The default is a guess for a tree that omits it, and a guess here sets every
// baud rate wrong. A board declares the rate instead of relying on it.
pub const uart_clock: usize = if (firstClockHz(.uart)) |hz| @intCast(hz) else 24000000;
pub const clint_base: usize = if (firstMmio(.timer)) |r| @intCast(r.base) else 0x2000000;

/// The architectural timebase: the rate the RISC-V `time` counter (CLINT mtime)
/// increments at. conduit reads it from the platform description, never from a
/// timer device's own clock. The two are different things, and a CLINT normally
/// declares no clock of its own, so a device-class lookup finds nothing.
///
/// Null means the description does not say. Weir then has to pick a value, and
/// `timebase_known` reports that it did.
const timebase_from_platform: ?u64 = if (has_dt) readTimebaseHz() else null;

/// True when `timebase_hz` came from the platform description. False means
/// `timebase_hz` is the QEMU-virt default, which is wrong on every other board:
/// every delay Weir computes is then scaled by the ratio, and the timebase Weir
/// reports to the OS in the ACPI RHCT is wrong by the same ratio. platform.zig
/// says so on the console at boot.
pub const timebase_known: bool = timebase_from_platform != null;

// QEMU's virt machine runs mtime at 10 MHz. No other platform is promised that
// rate, so this default is correct for QEMU virt and for nothing else. A board
// declares `timebase-frequency` on its cpu node instead of relying on it.
const qemu_virt_timebase_hz: u64 = 10_000_000;

/// Ticks per second of the CLINT mtime counter. Every computed delay and every
/// reported time scales with it, so a wrong value is a proportional error in
/// all of them.
pub const timebase_hz: u64 = timebase_from_platform orelse qemu_virt_timebase_hz;

fn readTimebaseHz() ?u64 {
    @setEvalBranchQuota(4_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return null;
    var be = conduit.backend.dtree.DtBackend.init(&rd);
    return conduit.Builder.timebaseHz(&be);
}

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

// The PLIC's source count and its contexts, both read from the PLIC node of the
// device tree. The ACPI MADT reports them, and on the ACPI path they are the
// only place an OS can get them from: the DSDT carries the register window and
// the GSI base, never the source count or the context map.

/// Number of external interrupt sources the PLIC implements (`riscv,ndev`). An
/// OS sizes its interrupt domain from it. Falls back to the architectural
/// maximum when the tree does not say, which is safe but wasteful.
pub const plic_ndev: u32 = if (has_dt) readPlicNdev() else 1023;

/// One PLIC context. The PLIC node's `interrupts-extended` lists the contexts
/// in context order, so the index into `plic_contexts` is the context number
/// the PLIC decodes. Each entry names the hart it interrupts and the local
/// interrupt cause it drives (11 = machine external, 9 = supervisor external).
pub const PlicContext = struct { hart_id: u64, cause: u32 };

const plic_context_count: usize = if (has_dt) countPlicContexts() else 0;
const plic_contexts_arr: [plic_context_count]PlicContext =
    if (has_dt) readPlicContexts(plic_context_count) else .{};

/// Every PLIC context, in context order. Empty when no tree is embedded.
pub const plic_contexts: []const PlicContext = &plic_contexts_arr;

/// Number of harts in the tree. At least one: a tree with no cpu node is
/// broken, and Weir is running, so a hart exists.
pub const hart_count: usize = if (has_dt) countHarts() else 1;

const harts_arr: [hart_count]u64 = if (has_dt) readHarts(hart_count) else .{0};

/// Every hart id, in device-tree order. The first is the boot hart.
pub const harts: []const u64 = &harts_arr;

/// A device-tree address cell pair, either one or two cells wide.
fn readCells(v: []const u8) u64 {
    if (v.len >= 8) return std.mem.readInt(u64, v[0..8], .big);
    if (v.len >= 4) return std.mem.readInt(u32, v[0..4], .big);
    return 0;
}

/// The raw value of `want` on the PLIC node, or null.
///
/// The PLIC is found by its `compatible`, not by its node name, because the
/// name differs between generators (`plic@`, `plic-1-0-0@`). Properties can
/// come in any order, so the value is only accepted once the node ends and the
/// compatible is known.
fn plicProp(want: []const u8) ?[]const u8 {
    @setEvalBranchQuota(8_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return null;
    var it = rd.nodeIterator();
    var depth: usize = 0;
    var is_plic = false;
    var value: ?[]const u8 = null;
    while (it.next() catch return null) |node| switch (node) {
        // Do not reset while inside the PLIC's own subtree, so a child node
        // cannot drop the properties collected from the PLIC itself.
        .begin => |bg| if (!is_plic or bg.depth <= depth) {
            depth = bg.depth;
            is_plic = false;
            value = null;
        },
        // A property reports the depth of its node plus one.
        .prop => |p| if (p.depth == depth + 1) {
            if (std.mem.eql(u8, p.name, "compatible") and
                std.mem.indexOf(u8, p.value, "plic") != null) is_plic = true;
            if (std.mem.eql(u8, p.name, want)) value = p.value;
        },
        .end => |e| if (e.depth == depth and is_plic) return value,
    };
    return null;
}

// A PLIC decodes sources 1 to 1023, so 1023 is both the architectural maximum
// and the safe fallback when the tree does not say.
const plic_max_sources: u32 = 1023;

fn readPlicNdev() u32 {
    const v = plicProp("riscv,ndev") orelse return plic_max_sources;
    if (v.len < 4) return plic_max_sources;
    return @min(std.mem.readInt(u32, v[0..4], .big), plic_max_sources);
}

// `interrupts-extended` holds one phandle plus one interrupt cell per context.
// The hart local interrupt controller declares `#interrupt-cells = <1>`, so an
// entry is 8 bytes.
const plic_context_entry_len = 8;

fn countPlicContexts() usize {
    @setEvalBranchQuota(8_000_000);
    const v = plicProp("interrupts-extended") orelse return 0;
    return v.len / plic_context_entry_len;
}

fn readPlicContexts(comptime n: usize) [n]PlicContext {
    @setEvalBranchQuota(8_000_000);
    var arr: [n]PlicContext = undefined;
    const v = plicProp("interrupts-extended") orelse return arr;
    for (0..n) |i| {
        const e = v[i * plic_context_entry_len ..][0..plic_context_entry_len];
        arr[i] = .{
            .hart_id = phandleToHart(std.mem.readInt(u32, e[0..4], .big)) orelse 0,
            .cause = std.mem.readInt(u32, e[4..8], .big),
        };
    }
    return arr;
}

/// The hart that owns the local interrupt controller with this phandle. The
/// controller is a child of the cpu node, and the cpu node's `reg` is the hart
/// id, so the walk carries the last cpu node seen.
fn phandleToHart(phandle: u32) ?u64 {
    @setEvalBranchQuota(8_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return null;
    var it = rd.nodeIterator();
    var cpu_depth: ?usize = null;
    var hart: u64 = 0;
    while (it.next() catch return null) |node| switch (node) {
        .begin => |bg| {
            if (std.mem.startsWith(u8, bg.name, "cpu@")) {
                cpu_depth = bg.depth;
                hart = 0;
            } else if (cpu_depth) |d| {
                if (bg.depth <= d) cpu_depth = null;
            }
        },
        .prop => |p| if (cpu_depth) |d| {
            if (p.depth == d + 1 and std.mem.eql(u8, p.name, "reg")) hart = readCells(p.value);
            if (p.depth == d + 2 and std.mem.eql(u8, p.name, "phandle") and p.value.len >= 4 and
                std.mem.readInt(u32, p.value[0..4], .big) == phandle) return hart;
        },
        .end => {},
    };
    return null;
}

fn countHarts() usize {
    @setEvalBranchQuota(8_000_000);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return 1;
    var it = rd.nodeIterator();
    var n: usize = 0;
    while (it.next() catch return 1) |node| switch (node) {
        .begin => |bg| if (std.mem.startsWith(u8, bg.name, "cpu@")) {
            n += 1;
        },
        .prop, .end => {},
    };
    return if (n == 0) 1 else n;
}

fn readHarts(comptime n: usize) [n]u64 {
    @setEvalBranchQuota(8_000_000);
    var arr: [n]u64 = @splat(0);
    var rd = conduit.dtree.Reader.initBuffer(@embedFile("soc_dtb")) catch return arr;
    var it = rd.nodeIterator();
    var i: usize = 0;
    var cpu_depth: ?usize = null;
    while (it.next() catch return arr) |node| switch (node) {
        .begin => |bg| {
            if (std.mem.startsWith(u8, bg.name, "cpu@") and i < n) {
                cpu_depth = bg.depth;
            } else if (cpu_depth) |d| {
                if (bg.depth <= d) cpu_depth = null;
            }
        },
        .prop => |p| if (cpu_depth) |d| {
            if (p.depth == d + 1 and std.mem.eql(u8, p.name, "reg")) {
                arr[i] = readCells(p.value);
                i += 1;
                cpu_depth = null;
            }
        },
        .end => {},
    };
    return arr;
}

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
// The host controller's input clock. The SD clock divider derives from it, so a
// wrong value clocks the card by the same ratio. 50 MHz is a guess for a tree
// that omits `clock-frequency`, not a property of any board here.
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

// These run on the host through `zig build test`, over the same embedded tree
// and the same comptime path the firmware uses.

test "the embedded device tree supplies the architectural timebase" {
    // Regression: the CLINT node carries no `clock-frequency`, so the timebase
    // used to be looked up on the timer device class, find nothing, and fall
    // silently to the QEMU-virt default. Every UEFI Stall then ran short and the
    // ACPI RHCT reported the wrong rate. A tree Weir is built against must
    // declare the timebase, and Weir must read it.
    if (!has_dt) return error.SkipZigTest;
    try std.testing.expect(timebase_known);
    try std.testing.expect(timebase_hz > 0);
}

test "with no platform description the timebase is the QEMU virt rate, and says so" {
    if (has_dt) return error.SkipZigTest;
    try std.testing.expect(!timebase_known);
    try std.testing.expectEqual(@as(u64, 10_000_000), timebase_hz);
}

test "a native SD host declares its own input clock" {
    // Same shape as the timebase defect: a missing `clock-frequency` silently
    // becomes 50 MHz, and the SD clock divider is then wrong by that ratio.
    if (sdhci_count == 0) return error.SkipZigTest;
    const declared = firstClockHzId(.block, &sdhci_ids) orelse return error.SdHostHasNoClock;
    try std.testing.expectEqual(declared, @as(u64, sdhci_freq));
}

test "the uart clock comes from the uart node, not from a default" {
    // `uart_clock` uses the device-class clock lookup that the timebase must
    // not use. That is correct here: the rate belongs to the UART, and the
    // ns16550a node declares it.
    if (!has_dt) return error.SkipZigTest;
    try std.testing.expect(firstClockHz(.uart) != null);
    try std.testing.expectEqual(firstClockHz(.uart).?, @as(u64, uart_clock));
}
