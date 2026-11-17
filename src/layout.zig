//! Firmware memory layout as offsets from the RAM base. The RAM size selects a
//! large or a small layout. mem.zig and the linker script generator both use
//! this file, so the firmware and its link checks agree.

const std = @import("std");

const kib = 1 << 10;
const mib = 1 << 20;

/// RAM of this size or more gets the large layout.
pub const small_below = 128 * mib;
/// Weir does not support less RAM than this.
pub const min_ram = 16 * mib;

pub const Layout = struct {
    /// End of the reserved firmware window.
    fw_window: u64,
    /// Where the first EFI image loads.
    load_base: u64,
    acpi_pool: u64,
    acpi_pool_size: u64,
    /// Null when the page pool starts after the loaded first image.
    page_pool: ?u64,
    /// Staging buffer for the files the boot manager reads.
    staging: u64,
    staging_size: u64,
    /// Staging buffer for `\EFI\BOOT\initrd`. A size of 0 disables it.
    initrd: u64,
    initrd_size: u64,
    /// Number of 1 MiB S-mode payload stacks.
    payload_stacks: usize,
    /// The page that holds the record the FSBL leaves for the main firmware.
    handoff: u64,

    /// The firmware image, with its stacks, must end at or below this offset.
    pub fn imageLimit(l: Layout) u64 {
        return @min(l.fw_window, l.acpi_pool, l.handoff);
    }

    /// The first image must end at or below this offset.
    pub fn loadLimit(l: Layout) u64 {
        return if (l.page_pool == null) l.staging else l.acpi_pool;
    }
};

/// The largest number of harts that Weir supports.
pub const max_harts = 8;

/// The layout for `ram_size` bytes of RAM. `hart_count` sizes the payload
/// stacks and the firmware window of the small layout. The caller makes sure
/// that `ram_size` is at least `min_ram`.
pub fn compute(ram_size: u64, hart_count: usize) Layout {
    if (ram_size >= small_below) return .{
        .fw_window = 32 * mib,
        .load_base = 32 * mib,
        .acpi_pool = 63 * mib,
        .acpi_pool_size = 1 * mib,
        .page_pool = 64 * mib,
        .staging = 96 * mib,
        .staging_size = 64 * mib,
        .initrd = 512 * mib,
        .initrd_size = 512 * mib,
        .payload_stacks = 8,
        .handoff = 32 * mib - 4 * kib,
    };
    // With one hart the image has one payload stack and fits in 2 MiB.
    const fw_window: u64 = if (hart_count == 1) 2 * mib else 4 * mib;
    const staging = std.mem.alignBackward(u64, ram_size / 2, 2 * mib);
    return .{
        .fw_window = fw_window,
        .load_base = fw_window,
        .acpi_pool = fw_window - 64 * kib,
        .acpi_pool_size = 64 * kib,
        .page_pool = null,
        .staging = staging,
        .staging_size = @min(ram_size - staging, 64 * mib),
        .initrd = 0,
        .initrd_size = 0,
        .payload_stacks = hart_count,
        .handoff = fw_window - 64 * kib - 4 * kib,
    };
}

/// The number of 64 KiB M-mode boot stacks in the image. The reset code
/// selects a stack by hart ID, so the small layout needs one for each ID up to
/// the largest. `hart_id_limit` is the largest hart ID plus 1.
pub fn bootStacks(ram_size: u64, hart_id_limit: usize) usize {
    if (ram_size >= small_below) return max_harts;
    return @min(@max(hart_id_limit, 1), max_harts);
}

const testing = std.testing;

test "the large layout keeps the fixed offsets" {
    for ([_]u64{ 128 * mib, 256 * mib, 2048 * mib }) |ram| {
        const l = compute(ram, 1);
        try testing.expectEqual(@as(u64, 0x0200_0000), l.fw_window);
        try testing.expectEqual(@as(u64, 0x0200_0000), l.load_base);
        try testing.expectEqual(@as(u64, 0x03f0_0000), l.acpi_pool);
        try testing.expectEqual(@as(u64, 0x10_0000), l.acpi_pool_size);
        try testing.expectEqual(@as(?u64, 0x0400_0000), l.page_pool);
        try testing.expectEqual(@as(u64, 0x0600_0000), l.staging);
        try testing.expectEqual(@as(u64, 64 << 20), l.staging_size);
        try testing.expectEqual(@as(u64, 0x2000_0000), l.initrd);
        try testing.expectEqual(@as(u64, 512 << 20), l.initrd_size);
        try testing.expectEqual(@as(usize, 8), l.payload_stacks);
        try testing.expectEqual(@as(u64, 0x01ff_f000), l.handoff);
        try testing.expectEqual(@as(u64, 0x01ff_f000), l.imageLimit());
        try testing.expectEqual(l.acpi_pool, l.loadLimit());
    }
}

test "the small layout starts just below 128 MiB" {
    try testing.expect(compute(128 * mib, 1).page_pool != null);
    try testing.expect(compute(128 * mib - 4 * kib, 1).page_pool == null);
}

test "the small layout fits in RAM without overlap" {
    for ([_]u64{ min_ram, 32 * mib, 64 * mib, 100 * mib, small_below - 4 * kib }) |ram| {
        const l = compute(ram, 2);
        try testing.expectEqual(@as(u64, 4 * mib), l.fw_window);
        try testing.expectEqual(l.fw_window, l.acpi_pool + l.acpi_pool_size);
        try testing.expectEqual(l.fw_window, l.load_base);
        try testing.expect(l.load_base < l.staging);
        try testing.expect(l.staging + l.staging_size <= ram);
        try testing.expect(l.staging_size > 0);
        try testing.expect(l.staging_size <= 64 * mib);
        try testing.expectEqual(@as(u64, 0), l.load_base % (2 * mib));
        try testing.expectEqual(@as(u64, 0), l.staging % (2 * mib));
        try testing.expectEqual(@as(u64, 0), l.initrd_size);
        try testing.expectEqual(@as(usize, 2), l.payload_stacks);
        try testing.expectEqual(l.acpi_pool - 4 * kib, l.handoff);
        try testing.expectEqual(l.handoff, l.imageLimit());
        try testing.expectEqual(l.staging, l.loadLimit());
    }
}

test "the small layout puts the staging buffer in the top half" {
    const l32 = compute(32 * mib, 1);
    try testing.expectEqual(@as(u64, 16 * mib), l32.staging);
    try testing.expectEqual(@as(u64, 16 * mib), l32.staging_size);
    const l64 = compute(64 * mib, 1);
    try testing.expectEqual(@as(u64, 32 * mib), l64.staging);
    try testing.expectEqual(@as(u64, 32 * mib), l64.staging_size);
}

test "the small layout with one hart has a 2 MiB firmware window" {
    const l = compute(32 * mib, 1);
    try testing.expectEqual(@as(u64, 2 * mib), l.fw_window);
    try testing.expectEqual(@as(u64, 2 * mib), l.load_base);
    try testing.expectEqual(l.fw_window, l.acpi_pool + l.acpi_pool_size);
    try testing.expectEqual(l.acpi_pool - 4 * kib, l.handoff);
    try testing.expectEqual(l.handoff, l.imageLimit());
}

test "the boot stacks follow the largest hart ID in the small layout only" {
    try testing.expectEqual(@as(usize, 8), bootStacks(256 * mib, 1));
    try testing.expectEqual(@as(usize, 1), bootStacks(32 * mib, 1));
    try testing.expectEqual(@as(usize, 1), bootStacks(32 * mib, 0));
    try testing.expectEqual(@as(usize, 4), bootStacks(32 * mib, 4));
    try testing.expectEqual(@as(usize, 8), bootStacks(32 * mib, 100));
}
