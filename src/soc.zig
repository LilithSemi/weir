//! SoC parameters, discovered from the embedded device tree at COMPTIME via
//! conduit's Builder. Everything here is baked into the binary - Weir and the
//! FSBL do NO runtime device lookup, which is the point: the addresses are known
//! at compile time, so there is zero discovery cost at boot. The same tree drives
//! the linker base (build.zig), so layout and link address stay in sync. With no
//! -Ddtb these fall back to the common addresses.

const conduit = @import("conduit");
const has_dt = @import("build_options").has_dtb;

// One matcher per SoC device class we bake. conduit walks the embedded DTB once
// at comptime and lowers each matched node's reg into an MMIO resource (and its
// clock-frequency into a Clock resource).
const matchers = [_]conduit.Matcher{
    .{ .class = .uart, .dt_compatible = &.{ "ns16550a", "ns16550", "snps,dw-apb-uart" } },
    .{ .class = .timer, .dt_compatible = &.{ "riscv,clint0", "sifive,clint0" } },
    // The /memory node has no `compatible`; conduit exposes its device_type.
    .{ .class = .memory, .dt_compatible = &.{"memory"} },
    .{ .class = .flash, .dt_compatible = &.{"jedec,spi-nor"} },
    .{ .class = .sdram, .dt_compatible = &.{ "harbor,ddr3-sdram", "harbor,sdram-controller" } },
    .{ .class = .tpm, .dt_compatible = &.{ "tcg,tpm-tis-mmio", "tcg,tpm-tis" } },
    .{ .class = .block, .dt_compatible = &.{ "harbor,sdhci", "harbor,sdio" } },
};

// The baked device table (comptime-only; empty if no -Ddtb was embedded).
const devices: []const conduit.Match = if (has_dt) blk: {
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

pub const uart_base: usize = if (firstMmio(.uart)) |r| @intCast(r.base) else 0x10000000;
pub const uart_clock: usize = if (firstClockHz(.uart)) |hz| @intCast(hz) else 24000000;
pub const clint_base: usize = if (firstMmio(.timer)) |r| @intCast(r.base) else 0x2000000;
pub const ram_base: usize = if (firstMmio(.memory)) |r| @intCast(r.base) else 0x80000000;
pub const ram_size: usize = if (firstMmio(.memory)) |r| @intCast(r.size) else 0x10000000;
pub const flash_base: usize = if (firstMmio(.flash)) |r| @intCast(r.base) else 0x20000000;

const tpm_mmio = firstMmio(.tpm);
pub const tpm_present: bool = tpm_mmio != null;
pub const tpm_base: usize = if (tpm_mmio) |r| @intCast(r.base) else 0x04000000;

// DDR read-training control window: Harbor decodes it in the TOP trainCtrlSize
// (0x1000) bytes of the sdram controller's region, so the window base is
// (controller base + controller size - trainCtrlSize). Zero = no CPU training
// window present (the FSBL then takes the static "no training" path).
const ddr_train_ctrl_size: usize = 0x1000; // == HarborDdrController.trainCtrlSize
const sdram_mmio = firstMmio(.sdram);
pub const ddr_train_base: usize =
    if (sdram_mmio) |r| @intCast(r.base + r.size - ddr_train_ctrl_size) else 0;

// SD/MMC host (River's block device; absent on creek). 0 = none.
pub const sdhci_base: usize = if (firstMmio(.block)) |r| @intCast(r.base) else 0;
pub const sdhci_freq: u32 = if (firstClockHz(.block)) |hz| @intCast(hz) else 50_000_000;
