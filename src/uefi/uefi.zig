//! UEFI boot-services environment built on the real UEFI ABI.
//!
//! Fills the genuine EFI System/Boot/Runtime Services layouts (std.os.uefi,
//! which matches the spec) so an external EFI binary like Limine's
//! BOOTRISCV64.EFI calls our services at the offsets it expects. Unneeded
//! services stub to unsupported/not-found. Routines run in S-mode alongside the
//! app (the PMP grant lets them reach MMIO directly), as real boot services do.

const std = @import("std");
const uefi = std.os.uefi;
const console = @import("../console/console.zig");
const clint = @import("../arch/riscv/clint.zig");
const cpu = @import("../arch/riscv/cpu.zig");
const varstore = @import("varstore.zig");
const handledb = @import("handledb.zig");
const blockio = @import("blockio.zig");
const initrd = @import("initrd.zig");
const pe = @import("../loader/pe.zig");
const fat = @import("../fs/fat.zig");
const soc = @import("soc");
const smbios = @import("smbios.zig");
const acpi_qemu = @import("../acpi/qemu.zig");
const platform = @import("../platform.zig");
const mem = @import("../mem.zig");
const tpm = @import("../tpm/tpm.zig");
const tcg2 = @import("../tpm/tcg2.zig");
const time = @import("../time.zig");

const Status = uefi.Status;
const tables = uefi.tables;

// SiFive-style test finisher, address from device-tree discovery.
fn finisher() *volatile u32 {
    return @ptrFromInt(platform.resetBase());
}

// Memory layout advertised to the app, derived from build-time ram_base (see
// mem.zig). Firmware and loaded image sit low. Pages come from the high half.
const RAM_BASE = mem.ram_base;
// Usable RAM ceiling. The 256 MiB default is too small for a large netboot
// initrd, so prepare() replaces it with real top-of-RAM from the DTB /memory.
var RAM_END: usize = mem.ram_end_default;
const PAGE_POOL_BASE = mem.page_pool_base;

// prepare() builds these EFI tables and protocol structs before the app can
// read them, so an undefined start is safe. Zero-init would only add cost.
var system_table: tables.SystemTable = undefined; // zippy:ignore unsafe_undefined
var boot_services: tables.BootServices = undefined; // zippy:ignore unsafe_undefined
var runtime_services: tables.RuntimeServices = undefined; // zippy:ignore unsafe_undefined
var con_out: uefi.protocol.SimpleTextOutput = undefined; // zippy:ignore unsafe_undefined
var con_out_mode: uefi.protocol.SimpleTextOutput.Mode = undefined; // zippy:ignore unsafe_undefined
var con_in: uefi.protocol.SimpleTextInput = undefined; // zippy:ignore unsafe_undefined
var config_table: [16]tables.ConfigurationTable = undefined;
var config_count: usize = 0;
var image_marker: u8 = 0;
var vendor = std.unicode.utf8ToUtf16LeStringLiteral("Midstall Weir").*;

// State an EFI app (the Linux kernel stub) needs: its loaded image, the boot
// hartid, the device tree, and a kernel command line. prepare() fills the
// structs below before the app can read them.
var loaded_image: uefi.protocol.LoadedImage = undefined; // zippy:ignore unsafe_undefined
var end_path: uefi.protocol.DevicePath = undefined; // zippy:ignore unsafe_undefined
var riscv_boot: RiscvBootProtocol = undefined; // zippy:ignore unsafe_undefined
var boot_hartid: usize = 0;
var dtb_addr: usize = 0;
var cmdline = std.unicode.utf8ToUtf16LeStringLiteral("earlycon=sbi console=ttyS0 keep_bootcon").*;

// Device tree handed to the OS via the EFI configuration table.
const DEVICE_TREE_GUID = uefi.Guid{
    .time_low = 0xb1b621d5,
    .time_mid = 0xf19c,
    .time_high_and_version = 0x41a5,
    .clock_seq_high_and_reserved = 0x83,
    .clock_seq_low = 0x0b,
    .node = .{ 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 },
};

// RISCV_EFI_BOOT_PROTOCOL: how the Linux EFI stub learns the boot hartid.
const RISCV_BOOT_GUID = uefi.Guid{
    .time_low = 0xccd15fec,
    .time_mid = 0x6f73,
    .time_high_and_version = 0x4eec,
    .clock_seq_high_and_reserved = 0x83,
    .clock_seq_low = 0x95,
    .node = .{ 0x3e, 0x69, 0xe4, 0xb9, 0x40, 0xbf },
};

// EFI_RT_PROPERTIES_TABLE: tells the OS which runtime services work after
// ExitBootServices. We relocate nothing into the OS address space, so we
// advertise zero supported, and the kernel never calls one (no efi=noruntime).
const RT_PROPERTIES_GUID = uefi.Guid{
    .time_low = 0xeb66918a,
    .time_mid = 0x7eef,
    .time_high_and_version = 0x402a,
    .clock_seq_high_and_reserved = 0x84,
    .clock_seq_low = 0x2e,
    .node = .{ 0x93, 0x1d, 0x21, 0xc3, 0x8a, 0xe9 },
};

// ACPI_20_TABLE_GUID: how the OS finds the RSDP in the EFI configuration table.
const ACPI_20_GUID = uefi.Guid{
    .time_low = 0x8868e871,
    .time_mid = 0xe4f1,
    .time_high_and_version = 0x11d3,
    .clock_seq_high_and_reserved = 0xbc,
    .clock_seq_low = 0x22,
    .node = .{ 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 },
};

const RtPropertiesTable = extern struct {
    version: u16,
    length: u16,
    runtime_services_supported: u32,
};

var rt_properties: RtPropertiesTable = .{
    .version = 1,
    .length = 8,
    .runtime_services_supported = 0,
};

const RiscvBootProtocol = extern struct {
    revision: u64,
    get_boot_hartid: *const fn (*RiscvBootProtocol, *usize) callconv(.c) Status,
};

// Single bump allocator from the high half of RAM, shared by AllocatePool and
// AllocatePages. The Linux EFI stub asks for multi-MiB buffers (2 MiB FDT, the
// relocated kernel), so it lives in conventional RAM, not a firmware array.
var page_next: usize = PAGE_POOL_BASE;
var map_key_seq: usize = 1;

// Regions the bump allocator must not hand out: addresses the app pinned via
// AllocatePages(AllocateAddress) (relocated kernel / FDT). The live initrd is
// tracked separately (initrd.region). Both stop a later allocation from
// aliasing a still-live buffer.
const Region = struct { start: usize, end: usize };
var reserved: [16]Region = undefined;
var reserved_n: usize = 0;

fn reserveRegion(start: usize, end: usize) void {
    if (start >= end or reserved_n >= reserved.len) return;
    reserved[reserved_n] = .{ .start = start, .end = end };
    reserved_n += 1;
}

// If [start, end) overlaps a reserved region (or the live initrd), return the
// highest end it hits so the caller can skip past all of them.
fn reservedConflict(start: usize, end: usize) ?usize {
    var skip: ?usize = null;
    if (initrd.region()) |r| {
        const rend = r.base + r.len;
        if (start < rend and r.base < end and (skip == null or rend > skip.?)) skip = rend;
    }
    for (reserved[0..reserved_n]) |r| {
        if (start < r.end and r.start < end and (skip == null or r.end > skip.?)) skip = r.end;
    }
    return skip;
}

// Bump-allocate `size` bytes aligned to `alignment`, stepping over any reserved
// region in the way. Null when RAM is exhausted.
fn bumpAlloc(size: usize, alignment: usize) ?usize {
    var aligned = (page_next + alignment - 1) & ~(alignment - 1);
    var guard: usize = 0;
    while (guard <= reserved_n + 1) : (guard += 1) {
        if (aligned + size > RAM_END) return null;
        if (reservedConflict(aligned, aligned + size)) |skip| {
            aligned = (skip + alignment - 1) & ~(alignment - 1);
            continue;
        }
        page_next = aligned + size;
        return aligned;
    }
    return null;
}

const ok = @intFromEnum(Status.success);

// Images loaded through the LoadImage boot service (the bootloader loading a
// kernel). Each keeps its entry point and a LoadedImage protocol the app reads
// and edits (systemd-boot sets the kernel command line on it before StartImage).
const MAX_LOADED_IMAGES = 4;
const LoadedImage = struct {
    used: bool = false,
    handle: ?*handledb.Handle = null,
    entry: usize = 0,
    li: uefi.protocol.LoadedImage = undefined, // zippy:ignore unsafe_undefined
};
var loaded_images: [MAX_LOADED_IMAGES]LoadedImage = undefined;

fn loadedImageSlot() ?*LoadedImage {
    for (&loaded_images) |*a| {
        if (!a.used) return a;
    }
    return null;
}

fn findLoadedImage(h: *handledb.Handle) ?*LoadedImage {
    for (&loaded_images) |*a| {
        if (a.used and a.handle == h) return a;
    }
    return null;
}

/// Toggle to trace the app's boot-service call sequence.
const trace = false;
fn tr(comptime name: []const u8) void {
    if (trace) console.out.writeAll("[uefi] " ++ name ++ "\n") catch {};
}

/// Generic stub for unimplemented services: returns unsupported.
fn stub() callconv(.c) usize {
    tr("<unimplemented boot service>");
    return @intFromEnum(Status.unsupported);
}

const not_found = @intFromEnum(Status.not_found);

fn guidEql(a: *const uefi.Guid, b: *const uefi.Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn getBootHartid(self: *RiscvBootProtocol, out: *usize) callconv(.c) usize {
    _ = self;
    out.* = boot_hartid;
    return ok;
}

/// HandleProtocol: look up a protocol interface on a handle in the database.
fn handleProtocol(
    handle: uefi.Handle,
    guid: *const uefi.Guid,
    out: *?*anyopaque,
) callconv(.c) usize {
    const h: *handledb.Handle = @ptrCast(@alignCast(handle));
    if (handledb.handleProtocol(h, guid)) |iface| {
        out.* = iface;
        return ok;
    }
    return not_found;
}

/// OpenProtocol: like HandleProtocol but the out-param may be null (presence test).
fn openProtocol( // zippy:ignore too_many_params UEFI OpenProtocol ABI is fixed
    handle: uefi.Handle,
    guid: *const uefi.Guid,
    out: ?*?*anyopaque,
    agent: uefi.Handle,
    controller: uefi.Handle,
    attr: u32,
) callconv(.c) usize {
    _ = agent;
    _ = controller;
    _ = attr;
    const h: *handledb.Handle = @ptrCast(@alignCast(handle));
    const iface = handledb.handleProtocol(h, guid) orelse return not_found;
    if (out) |o| o.* = iface;
    return ok;
}

/// LocateProtocol: find the first handle carrying `guid` and return its interface.
fn locateProtocol(
    guid: *const uefi.Guid,
    registration: ?*anyopaque,
    out: *?*anyopaque,
) callconv(.c) usize {
    _ = registration;
    if (handledb.locateProtocol(guid)) |iface| {
        out.* = iface;
        return ok;
    }
    return not_found;
}

/// LocateHandle (by-protocol): fill the caller's buffer with matching handles.
fn locateHandle(
    search_type: u32,
    guid: ?*const uefi.Guid,
    key: ?*anyopaque,
    buffer_size: *usize,
    buffer: ?[*]uefi.Handle,
) callconv(.c) usize {
    _ = search_type;
    _ = key;
    const g = guid orelse return @intFromEnum(Status.invalid_parameter);
    var tmp: [32]*handledb.Handle = undefined;
    const n = handledb.locateHandles(g, &tmp);
    const needed = n * @sizeOf(uefi.Handle);
    if (buffer == null or buffer_size.* < needed) {
        buffer_size.* = needed;
        return @intFromEnum(Status.buffer_too_small);
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buffer.?[i] = @ptrCast(tmp[i]);
    buffer_size.* = needed;
    return if (n > 0) ok else not_found;
}

/// LocateHandleBuffer: like LocateHandle but allocates the result buffer.
fn locateHandleBuffer(
    search_type: u32,
    guid: ?*const uefi.Guid,
    key: ?*anyopaque,
    num: *usize,
    buffer: *[*]uefi.Handle,
) callconv(.c) usize {
    _ = search_type;
    _ = key;
    const g = guid orelse return @intFromEnum(Status.invalid_parameter);
    var tmp: [32]*handledb.Handle = undefined;
    const n = handledb.locateHandles(g, &tmp);
    if (n == 0) return not_found;
    var out: ?*anyopaque = null;
    if (allocatePool(0, n * @sizeOf(uefi.Handle), &out) != ok) {
        return @intFromEnum(Status.out_of_resources);
    }
    const handles: [*]uefi.Handle = @ptrCast(@alignCast(out.?));
    var i: usize = 0;
    while (i < n) : (i += 1) handles[i] = @ptrCast(tmp[i]);
    buffer.* = handles;
    num.* = n;
    return ok;
}

/// LocateDevicePath: the Linux EFI stub uses this to find the LoadFile2 handle
/// that serves the initrd.
fn locateDevicePath(
    guid: *const uefi.Guid,
    dp: **const anyopaque,
    device: *?uefi.Handle,
) callconv(.c) usize {
    if (initrd.matchLoadFile2(guid, dp, device)) return ok;
    return not_found;
}

/// InstallProtocolInterface: a driver (or Weir) adds a protocol to a handle.
fn installProtocolInterface(
    handle: *?*anyopaque,
    guid: *const uefi.Guid,
    itype: u32,
    interface: *anyopaque,
) callconv(.c) usize {
    _ = itype;
    const existing: ?*handledb.Handle = if (handle.*) |hp| @ptrCast(@alignCast(hp)) else null;
    const h = handledb.install(existing, guid, interface) orelse
        return @intFromEnum(Status.out_of_resources);
    handle.* = @ptrCast(h);
    return ok;
}

/// InstallMultipleProtocolInterfaces: install a null-terminated list of
/// (guid, interface) pairs on one handle, creating it when `*handle` is null.
/// systemd-boot registers the Linux initrd with it (a Device Path plus a
/// LoadFile2 on a fresh handle).
fn installMultipleProtocolInterfaces(handle: *?*anyopaque, ...) callconv(.c) usize {
    var va = @cVaStart();
    defer @cVaEnd(&va);
    while (true) {
        const guid = @cVaArg(&va, ?*const uefi.Guid) orelse break;
        const interface = @cVaArg(&va, *anyopaque);
        const existing: ?*handledb.Handle = if (handle.*) |hp| @ptrCast(@alignCast(hp)) else null;
        const h = handledb.install(existing, guid, interface) orelse
            return @intFromEnum(Status.out_of_resources);
        handle.* = @ptrCast(h);
    }
    return ok;
}

/// InstallConfigurationTable: add, replace, or remove a config table entry. The
/// Linux EFI stub uses it for the memreserve table and to update the device tree.
fn installConfigurationTable(guid: *const uefi.Guid, table: ?*anyopaque) callconv(.c) usize {
    var i: usize = 0;
    while (i < config_count) : (i += 1) {
        if (!guidEql(&config_table[i].vendor_guid, guid)) continue;
        if (table) |t| {
            config_table[i].vendor_table = t;
        } else {
            var j = i;
            while (j + 1 < config_count) : (j += 1) config_table[j] = config_table[j + 1];
            config_count -= 1;
        }
        system_table.number_of_table_entries = config_count;
        return ok;
    }
    if (table) |t| {
        if (config_count >= config_table.len) return @intFromEnum(Status.out_of_resources);
        config_table[config_count] = .{ .vendor_guid = guid.*, .vendor_table = t };
        config_count += 1;
        system_table.number_of_table_entries = config_count;
        return ok;
    }
    return not_found;
}

/// Stub for the SimpleTextOutput controls we treat as no-ops.
fn textOk() callconv(.c) usize {
    return ok;
}

/// Point every pointer field of a table at a stub, leaving `hdr` alone.
fn stubAll(comptime T: type, table: *T) void {
    inline for (std.meta.fields(T)) |f| {
        if (comptime std.mem.eql(u8, f.name, "hdr")) continue;
        if (comptime @typeInfo(f.type) == .pointer) {
            @field(table.*, f.name) = @ptrFromInt(@intFromPtr(&stub));
        }
    }
}

/// Install a typed implementation into a service-table field by its name.
fn put(table: anytype, comptime field: []const u8, impl: anytype) void {
    @field(table.*, field) = @ptrFromInt(@intFromPtr(impl));
}

// --- Simple Text Output -----------------------------------------------------

fn outResetOut(self: *uefi.protocol.SimpleTextOutput, extended: bool) callconv(.c) usize {
    _ = self;
    _ = extended;
    return ok;
}

// --- Simple Text Input (a bootloader needs an input device to exist) --------

fn inReset(self: *uefi.protocol.SimpleTextInput, verify: bool) callconv(.c) usize {
    _ = self;
    _ = verify;
    return ok;
}

// EFI_INPUT_KEY: the 4-byte keystroke the basic Simple Text Input fills. Kept
// local so it stays 4 bytes, apart from the wider Ex key data.
const InputKey = extern struct { scan_code: u16, unicode_char: u16 };

// EFI scan codes for the non-character keys a boot menu uses.
const SCAN_UP: u16 = 0x01;
const SCAN_DOWN: u16 = 0x02;
const SCAN_RIGHT: u16 = 0x03;
const SCAN_LEFT: u16 = 0x04;
const SCAN_HOME: u16 = 0x05;
const SCAN_END: u16 = 0x06;
const SCAN_INSERT: u16 = 0x07;
const SCAN_DELETE: u16 = 0x08;
const SCAN_PAGE_UP: u16 = 0x09;
const SCAN_PAGE_DOWN: u16 = 0x0a;
const SCAN_F1: u16 = 0x0b;
const SCAN_ESC: u16 = 0x17;

// A decoded key and how many FIFO bytes it consumed. `used == 0` means the FIFO
// holds the start of an escape sequence whose rest has not arrived yet.
const KeyDecode = struct { scan: u16, char: u16, used: usize };

/// Decode the key at the front of `buf`. `buf` is never empty.
fn decodeKey(buf: []const u8) KeyDecode {
    if (buf[0] != 0x1b) {
        // A plain byte. Deliver a line feed as the UEFI carriage return (Enter).
        const c: u16 = if (buf[0] == '\n') '\r' else buf[0];
        return .{ .scan = 0, .char = c, .used = 1 };
    }
    // ESC. A lone ESC, or ESC followed by a byte that does not start a control
    // sequence, is the Escape key. CSI (ESC [) and SS3 (ESC O) start the arrow
    // and function keys.
    if (buf.len < 2) return .{ .scan = 0, .char = 0, .used = 0 }; // wait for more
    if (buf[1] != '[' and buf[1] != 'O') return .{ .scan = SCAN_ESC, .char = 0, .used = 1 };
    if (buf.len < 3) return .{ .scan = 0, .char = 0, .used = 0 }; // wait for the final byte

    // Letter-final forms: the arrows (A-D), Home (H), End (F), and F1-F4 (P-S).
    const scan: u16 = switch (buf[2]) {
        'A' => SCAN_UP,
        'B' => SCAN_DOWN,
        'C' => SCAN_RIGHT,
        'D' => SCAN_LEFT,
        'H' => SCAN_HOME,
        'F' => SCAN_END,
        'P', 'Q', 'R', 'S' => SCAN_F1 + (buf[2] - 'P'),
        else => 0,
    };
    if (scan != 0) return .{ .scan = scan, .char = 0, .used = 3 };

    // Numeric forms: ESC [ <digits> ~ (Insert, Delete, Page Up/Down, Home, End).
    if (buf[1] == '[' and buf[2] >= '0' and buf[2] <= '9') {
        var k: usize = 2;
        var num: u16 = 0;
        while (k < buf.len and buf[k] >= '0' and buf[k] <= '9') : (k += 1) {
            num = num * 10 + (buf[k] - '0');
        }
        if (k >= buf.len) return .{ .scan = 0, .char = 0, .used = 0 }; // wait for '~'
        const s: u16 = switch (num) {
            1, 7 => SCAN_HOME,
            2 => SCAN_INSERT,
            3 => SCAN_DELETE,
            4, 8 => SCAN_END,
            5 => SCAN_PAGE_UP,
            6 => SCAN_PAGE_DOWN,
            else => 0,
        };
        return .{ .scan = s, .char = 0, .used = k + 1 }; // consume through '~'
    }

    // An unrecognised 3-byte sequence: consume it so it does not wedge the FIFO.
    return .{ .scan = 0, .char = 0, .used = 3 };
}

fn inReadKey(self: *uefi.protocol.SimpleTextInput, key: *anyopaque) callconv(.c) usize {
    _ = self;
    fillKeys();
    if (key_len == 0) return @intFromEnum(Status.not_ready);

    // Give a partial escape sequence a short window to finish arriving. A
    // terminal sends the whole sequence back to back, so a few milliseconds is
    // plenty. Past the window a lone ESC is the Escape key.
    const deadline = clint.time() + timerTicks(20_000); // 2 ms in 100 ns units
    var dec = decodeKey(key_buf[0..key_len]);
    while (dec.used == 0) {
        if (clint.time() >= deadline) {
            dec = .{ .scan = SCAN_ESC, .char = 0, .used = 1 };
            break;
        }
        fillKeys();
        dec = decodeKey(key_buf[0..key_len]);
    }

    dropKeys(dec.used);
    const k: *InputKey = @ptrCast(@alignCast(key));
    k.* = .{ .scan_code = dec.scan, .unicode_char = dec.char };
    // A consumed-but-unmapped sequence (scan and char both zero) is not a key.
    if (dec.scan == 0 and dec.char == 0) return @intFromEnum(Status.not_ready);
    return ok;
}

fn outString(self: *uefi.protocol.SimpleTextOutput, str: [*:0]const u16) callconv(.c) usize {
    _ = self;
    var i: usize = 0;
    while (str[i] != 0) : (i += 1) {
        const c = str[i];
        console.out.writeByte(if (c < 0x80) @truncate(c) else '?') catch {};
    }
    return ok;
}

// --- Boot Services ----------------------------------------------------------

fn allocatePool(pool_type: u32, size: usize, buffer: *?*anyopaque) callconv(.c) usize {
    tr("allocatePool");
    _ = pool_type;
    const addr = bumpAlloc(size, 8) orelse return @intFromEnum(Status.out_of_resources);
    buffer.* = @ptrFromInt(addr);
    return ok;
}

fn freePool(buffer: *anyopaque) callconv(.c) usize {
    _ = buffer; // bump allocator: freeing is a no-op
    return ok;
}

fn allocatePages(alloc_type: u32, mem_type: u32, pages: usize, memory: *usize) callconv(.c) usize {
    _ = mem_type;
    const size = pages * 4096;
    if (trace) console.out.print(
        "[uefi] allocatePages type={d} pages={d} at={x}\n",
        .{ alloc_type, pages, memory.* },
    ) catch {};
    // AllocateAddress (2): honour the requested address, but reject placements
    // outside RAM or onto the running firmware, and record the region so later
    // bump allocations cannot alias it.
    if (alloc_type == 2) {
        const req = memory.*;
        if (req < FW_RESERVED_END or req +% size < req or req + size > RAM_END) {
            return @intFromEnum(Status.out_of_resources);
        }
        reserveRegion(req, req + size);
        return ok;
    }
    const addr = bumpAlloc(size, 4096) orelse return @intFromEnum(Status.out_of_resources);
    memory.* = addr;
    if (trace) console.out.print("[uefi]   -> pages at {x}\n", .{addr}) catch {};
    return ok;
}

fn freePages(memory: usize, pages: usize) callconv(.c) usize {
    _ = memory;
    _ = pages;
    return ok;
}

// Weir itself (code + bss) lives below this line. The firmware keeps running in
// M-mode after the OS starts, so the OS must reserve this region.
const FW_RESERVED_END = mem.fw_reserved_end;

fn getMemoryMap(
    mmap_size: *usize,
    mmap: ?[*]u8,
    map_key: *usize,
    desc_size: *usize,
    desc_ver: *u32,
) callconv(.c) usize {
    tr("getMemoryMap");
    const dsize = @sizeOf(tables.MemoryDescriptor);
    const have_acpi = acpi_qemu.rsdp() != 0;

    // Carve the live initrd (page-rounded) out of conventional memory so the OS
    // cannot allocate over it before the stub fetches it via LoadFile2. Marked
    // boot-services-data: protected during boot services, reclaimable after
    // ExitBootServices (by when the stub has copied it out). When present it
    // splits the free region, adding two descriptors.
    const ir: ?Region = blk: {
        if (initrd.region()) |r| {
            const s = r.base & ~@as(usize, 4095);
            const e = (r.base + r.len + 4095) & ~@as(usize, 4095);
            if (s >= PAGE_POOL_BASE and e <= RAM_END and e > s) {
                break :blk .{ .start = s, .end = e };
            }
        }
        break :blk null;
    };

    // base: firmware-reserved + boot-services-data. Plus ACPI reclaim if linked,
    // plus the free region(s): one normally, three when the initrd splits them.
    const acpi_descs: usize = if (have_acpi) 1 else 0;
    const free_descs: usize = if (ir != null) 3 else 1;
    const count: usize = 2 + acpi_descs + free_descs;
    const needed = count * dsize;
    desc_size.* = dsize;
    desc_ver.* = 1;
    if (mmap == null or mmap_size.* < needed) {
        mmap_size.* = needed;
        return @intFromEnum(Status.buffer_too_small);
    }

    // EFI_MEMORY_WB: ordinary writeback-cacheable RAM.
    const attr: tables.MemoryDescriptorAttribute = @bitCast(@as(u64, 0x8));
    const descs: [*]tables.MemoryDescriptor = @ptrCast(@alignCast(mmap.?));
    var next: usize = 0;
    const emit = struct {
        fn d(
            slot: *tables.MemoryDescriptor,
            t: tables.MemoryType,
            start: usize,
            end: usize,
            a: tables.MemoryDescriptorAttribute,
        ) void {
            slot.* = .{
                .type = t,
                .physical_start = start,
                .virtual_start = 0,
                .number_of_pages = (end - start) / 4096,
                .attribute = a,
            };
        }
    }.d;

    // The running firmware: reserved so the OS never reclaims it.
    emit(&descs[next], .reserved_memory_type, RAM_BASE, FW_RESERVED_END, attr);
    next += 1;
    // The loaded image and low boot allocations, up to the ACPI pool if present.
    const bsd_end = if (have_acpi) acpi_qemu.POOL_BASE else PAGE_POOL_BASE;
    emit(&descs[next], .boot_services_data, FW_RESERVED_END, bsd_end, attr);
    next += 1;
    if (have_acpi) {
        // The linked ACPI tables: reclaimable once the OS has parsed them.
        emit(
            &descs[next],
            .acpi_reclaim_memory,
            acpi_qemu.POOL_BASE,
            acpi_qemu.POOL_BASE + acpi_qemu.POOL_SIZE,
            attr,
        );
        next += 1;
    }
    // Free conventional memory for the OS, with the initrd carved out if present.
    if (ir) |reg| {
        emit(&descs[next], .conventional_memory, PAGE_POOL_BASE, reg.start, attr);
        next += 1;
        emit(&descs[next], .boot_services_data, reg.start, reg.end, attr);
        next += 1;
        emit(&descs[next], .conventional_memory, reg.end, RAM_END, attr);
        next += 1;
    } else {
        emit(&descs[next], .conventional_memory, PAGE_POOL_BASE, RAM_END, attr);
        next += 1;
    }
    mmap_size.* = needed;
    map_key.* = map_key_seq;
    map_key_seq += 1;
    return ok;
}

fn copyMem(dest: [*]u8, src: [*]const u8, len: usize) callconv(.c) void {
    // UEFI CopyMem must handle overlapping regions (memmove semantics): the
    // Linux EFI stub routes its memmove through here, and libfdt relies on the
    // overlap-safe direction. @memmove is overlap-safe and word-wide, so it does
    // not pay a per-byte store (a byte loop crawls on the slow-write DDR fabric).
    @memmove(dest[0..len], src[0..len]);
}

fn setMem(buffer: [*]u8, size: usize, value: u8) callconv(.c) void {
    @memset(buffer[0..size], value);
}

fn stall(microseconds: usize) callconv(.c) usize {
    tr("stall");
    // 1 microsecond is 10 UEFI timer units (100 ns each). timerTicks turns those
    // into CLINT ticks through the SoC timebase, so the delay holds on a board
    // whose mtime does not run at 10 MHz.
    const target = clint.time() + timerTicks(@as(u64, microseconds) * 10);
    while (clint.time() < target) {}
    return ok;
}

fn setWatchdogTimer(
    timeout: usize,
    code: u64,
    data_size: usize,
    data: ?[*]const u16,
) callconv(.c) usize {
    tr("setWatchdogTimer");
    _ = timeout;
    _ = code;
    _ = data_size;
    _ = data;
    return ok;
}

fn exitBootServices(image: uefi.Handle, map_key: usize) callconv(.c) usize {
    tr("exitBootServices");
    _ = image;
    _ = map_key;
    // The application takes over the machine. Nothing to tear down here.
    return ok;
}

fn raiseTpl(new_tpl: usize) callconv(.c) usize {
    _ = new_tpl;
    return 0; // old TPL
}

fn restoreTpl(old_tpl: usize) callconv(.c) void {
    _ = old_tpl;
}

fn exitApp(
    image: uefi.Handle,
    status: usize,
    data_size: usize,
    data: ?*const anyopaque,
) callconv(.c) usize {
    _ = image;
    _ = status;
    _ = data_size;
    _ = data;
    finisher().* = 0x5555; // power off
    cpu.halt();
}

// --- Image loading ----------------------------------------------------------

/// Pull the file path out of a device path as an ASCII string into `out`. A
/// bootloader builds `<device nodes>/FilePath(\EFI\...\kernel.efi)/End`, so walk
/// the nodes and return the first Media/FilePath (type 4, subtype 4) payload.
fn devicePathFile(dp: [*]const u8, out: []u8) ?[]const u8 {
    var p: usize = 0;
    // A device path is short. Bound the walk well above any real one so a
    // malformed path (no End node) cannot run off into unrelated memory.
    while (p + 4 <= 4096) {
        const dtype = dp[p];
        const subtype = dp[p + 1];
        const len = @as(usize, dp[p + 2]) | (@as(usize, dp[p + 3]) << 8);
        if (len < 4) return null;
        if (dtype == 0x7f) return null; // end of device path, no file node
        if (dtype == 0x04 and subtype == 0x04) {
            var n: usize = 0;
            var q: usize = p + 4;
            while (q + 2 <= p + len and n + 1 < out.len) : (q += 2) {
                const ch = @as(u16, dp[q]) | (@as(u16, dp[q + 1]) << 8);
                if (ch == 0) break;
                out[n] = if (ch < 0x80) @intCast(ch) else '?';
                n += 1;
            }
            return out[0..n];
        }
        p += len;
    }
    return null;
}

/// LoadImage: load an EFI image the bootloader hands us, from an explicit source
/// buffer or from the file named by `device_path` on the ESP. The image lands in
/// a fresh region so it never overwrites the still-running caller at LOAD_BASE.
fn loadImage( // zippy:ignore too_many_params UEFI LoadImage ABI is fixed
    boot_policy: bool,
    parent: uefi.Handle,
    device_path: ?*const anyopaque,
    source_buffer: ?[*]const u8,
    source_size: usize,
    out_handle: *uefi.Handle,
) callconv(.c) usize {
    _ = boot_policy;
    _ = parent;
    tr("loadImage");

    // The image bytes: an explicit buffer, or the file the device path names.
    const src: []const u8 = if (source_buffer) |sb| blk: {
        if (source_size == 0) return @intFromEnum(Status.invalid_parameter);
        break :blk sb[0..source_size];
    } else blk: {
        const dp = device_path orelse return @intFromEnum(Status.invalid_parameter);
        var name_buf: [256]u8 = undefined;
        const path = devicePathFile(@ptrCast(dp), &name_buf) orelse return not_found;
        const fsize = fat.fileSize(path) orelse return not_found;
        const scratch = bumpAlloc(fsize, 8) orelse return @intFromEnum(Status.out_of_resources);
        const sbuf = @as([*]u8, @ptrFromInt(scratch))[0..fsize];
        // A multi-MiB image over polled SPI takes many seconds. Announce the read
        // so a slow load reads as progress, not a hang.
        const got = fat.readFile(path, sbuf) orelse return @intFromEnum(Status.device_error);
        if (got != fsize) return @intFromEnum(Status.device_error);
        break :blk sbuf;
    };

    // Place the image in a fresh page-aligned region above the loaded bootloader,
    // and reserve it so no later allocation aliases the loaded image.
    const image_size = pe.sizeOf(src) catch return @intFromEnum(Status.load_error);
    const base = bumpAlloc(image_size, 4096) orelse return @intFromEnum(Status.out_of_resources);
    reserveRegion(base, base + image_size);
    const loaded = pe.loadAt(src, base, image_size) catch return @intFromEnum(Status.load_error);

    const slot = loadedImageSlot() orelse return @intFromEnum(Status.out_of_resources);
    const h = handledb.create() orelse return @intFromEnum(Status.out_of_resources);
    slot.used = true;
    slot.handle = h;
    slot.entry = loaded.entry;
    // The app reads its own LoadedImage (and sets load_options for the command
    // line) before StartImage, so publish one on the new handle.
    slot.li = .{
        .revision = 0x1000,
        .parent_handle = imageHandle(),
        .system_table = &system_table,
        .device_handle = loaded_image.device_handle,
        .file_path = &end_path,
        .reserved = @ptrCast(&image_marker),
        .load_options_size = 0,
        .load_options = null,
        .image_base = @ptrFromInt(loaded.base),
        .image_size = loaded.size,
        .image_code_type = .loader_code,
        .image_data_type = .loader_data,
        ._unload = @ptrFromInt(@intFromPtr(&stub)),
    };
    addProtocol(h, &uefi.protocol.LoadedImage.guid, &slot.li);
    out_handle.* = @ptrCast(h);
    return ok;
}

/// StartImage: enter a loaded image in S-mode, exactly as an EFI loader would,
/// with a0 = its image handle and a1 = the system table. It returns only if it
/// does not boot (a kernel calls ExitBootServices and never comes back).
fn startImage(image: uefi.Handle, exit_data_size: ?*usize, exit_data: ?*[*]u16) callconv(.c) usize {
    tr("startImage");
    _ = exit_data;
    if (exit_data_size) |s| s.* = 0;
    const h: *handledb.Handle = @ptrCast(@alignCast(image));
    const slot = findLoadedImage(h) orelse return @intFromEnum(Status.invalid_parameter);
    const EntryFn = *const fn (uefi.Handle, *tables.SystemTable) callconv(.c) Status;
    const entry: EntryFn = @ptrFromInt(slot.entry);
    return @intFromEnum(entry(image, &system_table));
}

/// UnloadImage: drop a loaded image the app chose not to start. The bump
/// allocator keeps the region, so this only frees the registry slot and handle.
fn unloadImage(image: uefi.Handle) callconv(.c) usize {
    const h: *handledb.Handle = @ptrCast(@alignCast(image));
    if (findLoadedImage(h)) |slot| {
        slot.used = false;
        if (slot.handle) |hh| hh.used = false;
    }
    return ok;
}

// --- Events and the timer ---------------------------------------------------
//
// A bootloader creates a timer event, arms it, and waits on it together with the
// console's key event to run a menu countdown. Weir keeps a small event pool.
// The timer runs off the CLINT, the key event off the UART. Neither uses an
// interrupt: WaitForEvent polls both until one is ready.

const EVT_TIMER: u32 = 0x8000_0000;
const EventNotify = *const fn (*anyopaque, ?*anyopaque) callconv(.c) void;

const Event = struct {
    used: bool = false,
    is_timer: bool = false,
    is_wait_key: bool = false,
    signaled: bool = false, // set by an explicit SignalEvent
    notify_fn: ?EventNotify = null,
    notify_ctx: ?*anyopaque = null,
    timer_armed: bool = false,
    periodic: bool = false,
    period: u64 = 0, // CLINT ticks between periodic firings
    deadline: u64 = 0, // CLINT time value the timer fires at
};

const MAX_EVENTS = 16;
var events: [MAX_EVENTS]Event = undefined;
// The one key event ConIn exposes as WaitForKey. prepare() allocates it.
var wait_key_event: *Event = undefined; // zippy:ignore unsafe_undefined

// Raw console bytes read from the UART but not yet decoded into keystrokes. An
// arrow key arrives as a multi-byte escape sequence (ESC [ A), so a small FIFO
// holds the bytes until ReadKeyStroke can form a whole key.
var key_buf: [8]u8 = undefined;
var key_len: usize = 0;

/// Pull every waiting UART byte into the FIFO, up to its capacity. Non-blocking.
// Console input is disabled during the UEFI phase. A floating or noisy UART RX
// line otherwise delivers phantom bytes that a boot manager (systemd-boot) reads
// as keystrokes, which cancel its auto-boot countdown and leave the machine
// parked at the menu forever. The OS reads the UART directly after handoff, so
// its own console still works. To restore interactive menus, drain real key
// bytes here again (and fix the RX line's idle state).
fn fillKeys() void {}

/// Drop the first `n` bytes of the FIFO once a key consumes them.
fn dropKeys(n: usize) void {
    var i: usize = n;
    var j: usize = 0;
    while (i < key_len) : (i += 1) {
        key_buf[j] = key_buf[i];
        j += 1;
    }
    key_len = j;
}

/// True when console input is waiting. Drains the UART into the FIFO first.
fn keyReady() bool {
    fillKeys();
    return key_len > 0;
}

// UEFI timer units are 100 ns. Convert to CLINT ticks via the SoC timebase, so
// the timing holds on a board whose mtime does not run at 10 MHz.
fn timerTicks(hundred_ns: u64) u64 {
    return hundred_ns * soc.timebase_hz / 10_000_000;
}

fn eventAlloc() ?*Event {
    for (&events) |*e| {
        if (!e.used) {
            e.* = .{};
            e.used = true;
            return e;
        }
    }
    return null;
}

/// Validate an EFI_EVENT before dereferencing it: a bogus handle must not deref
/// wild. Checks the pointer lands on a live slot of the event pool.
fn eventOf(handle: ?*anyopaque) ?*Event {
    const e: *Event = @ptrCast(@alignCast(handle orelse return null));
    const base = @intFromPtr(&events[0]);
    const p = @intFromPtr(e);
    if (p < base or p >= base + @sizeOf(Event) * MAX_EVENTS) return null;
    if ((p - base) % @sizeOf(Event) != 0) return null;
    return if (e.used) e else null;
}

/// Is the event ready (its wait would return it now)? Advances a periodic timer
/// and disarms a one-shot timer that has just fired.
fn eventReady(e: *Event) bool {
    if (e.signaled) return true;
    if (e.is_wait_key) return keyReady();
    if (e.is_timer and e.timer_armed and clint.time() >= e.deadline) {
        if (e.periodic) e.deadline += e.period else e.timer_armed = false;
        return true;
    }
    return false;
}

fn createEvent(
    etype: u32,
    notify_tpl: usize,
    notify_fn: ?EventNotify,
    notify_ctx: ?*anyopaque,
    out: *?*anyopaque,
) callconv(.c) usize {
    _ = notify_tpl;
    const e = eventAlloc() orelse return @intFromEnum(Status.out_of_resources);
    e.is_timer = (etype & EVT_TIMER) != 0;
    e.notify_fn = notify_fn;
    e.notify_ctx = notify_ctx;
    out.* = @ptrCast(e);
    return ok;
}

fn createEventEx( // zippy:ignore too_many_params UEFI CreateEventEx ABI is fixed
    etype: u32,
    notify_tpl: usize,
    notify_fn: ?EventNotify,
    notify_ctx: ?*anyopaque,
    group: ?*const anyopaque,
    out: *?*anyopaque,
) callconv(.c) usize {
    _ = group; // event groups are not tracked: no grouped signalling is used
    return createEvent(etype, notify_tpl, notify_fn, notify_ctx, out);
}

fn setTimer(event: ?*anyopaque, delay: u32, trigger_time: u64) callconv(.c) usize {
    const e = eventOf(event) orelse return @intFromEnum(Status.invalid_parameter);
    switch (delay) {
        0 => { // cancel
            e.timer_armed = false;
            e.periodic = false;
        },
        1 => { // periodic
            e.timer_armed = true;
            e.periodic = true;
            e.period = timerTicks(trigger_time);
            e.deadline = clint.time() + e.period;
        },
        2 => { // relative
            e.timer_armed = true;
            e.periodic = false;
            e.deadline = clint.time() + timerTicks(trigger_time);
        },
        else => return @intFromEnum(Status.invalid_parameter),
    }
    return ok;
}

fn waitForEvent(event_len: usize, evs: [*]const ?*anyopaque, index: *usize) callconv(.c) usize {
    if (event_len == 0) return @intFromEnum(Status.invalid_parameter);
    var i: usize = 0;
    while (i < event_len) : (i += 1) {
        if (eventOf(evs[i]) == null) {
            index.* = i;
            return @intFromEnum(Status.invalid_parameter);
        }
    }
    // Poll the events until one is ready. This blocks, as WaitForEvent must.
    while (true) {
        i = 0;
        while (i < event_len) : (i += 1) {
            const e = eventOf(evs[i]).?;
            if (eventReady(e)) {
                e.signaled = false;
                index.* = i;
                return ok;
            }
        }
    }
}

fn checkEvent(event: ?*anyopaque) callconv(.c) usize {
    const e = eventOf(event) orelse return @intFromEnum(Status.invalid_parameter);
    if (eventReady(e)) {
        e.signaled = false;
        return ok;
    }
    return @intFromEnum(Status.not_ready);
}

fn signalEvent(event: ?*anyopaque) callconv(.c) usize {
    const e = eventOf(event) orelse return @intFromEnum(Status.invalid_parameter);
    e.signaled = true;
    if (e.notify_fn) |f| f(@ptrCast(e), e.notify_ctx);
    return ok;
}

fn closeEvent(event: ?*anyopaque) callconv(.c) usize {
    const e = eventOf(event) orelse return @intFromEnum(Status.invalid_parameter);
    // The key event belongs to ConIn, not the app: keep it alive.
    if (e != wait_key_event) e.used = false;
    return ok;
}

// --- Runtime Services -------------------------------------------------------

fn setVirtualAddressMap(
    mmap_size: usize,
    desc_size: usize,
    desc_ver: u32,
    virtual_map: ?*anyopaque,
) callconv(.c) usize {
    _ = mmap_size;
    _ = desc_size;
    _ = desc_ver;
    _ = virtual_map;
    // We keep runtime services identity-mapped, so this is a no-op success.
    return ok;
}

// --- EFI variable runtime services (flash-backed) ---------------------------

fn statusOf(r: varstore.Result) usize {
    return @intFromEnum(switch (r) {
        .success => Status.success,
        .not_found => Status.not_found,
        .buffer_too_small => Status.buffer_too_small,
        .invalid => Status.invalid_parameter,
        .out_of_resources => Status.out_of_resources,
        .device_error => Status.device_error,
    });
}

fn getVariable(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attrs: ?*u32,
    data_size: *usize,
    data: ?[*]u8,
) callconv(.c) usize {
    return statusOf(varstore.get(name, guid, attrs, data_size, data));
}

fn setVariable(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attributes: u32,
    data_size: usize,
    data: ?[*]const u8,
) callconv(.c) usize {
    return statusOf(varstore.set(name, guid, attributes, data_size, data));
}

fn getNextVariableName(name_size: *usize, name: [*:0]u16, guid: *[16]u8) callconv(.c) usize {
    return statusOf(varstore.next(name_size, name, guid));
}

fn queryVariableInfo(
    attributes: u32,
    max_storage: *u64,
    remaining: *u64,
    max_var: *u64,
) callconv(.c) usize {
    _ = attributes;
    if (!varstore.available()) return @intFromEnum(Status.unsupported);
    varstore.queryInfo(max_storage, remaining, max_var);
    return ok;
}

fn getTime(t: *uefi.Time, caps: ?*uefi.TimeCapabilities) callconv(.c) usize {
    const dt = time.now();
    t.* = .{
        .year = dt.year,
        .month = dt.month,
        .day = dt.day,
        .hour = dt.hour,
        .minute = dt.minute,
        .second = dt.second,
        ._pad1 = 0,
        .nanosecond = 0,
        // Weir keeps time in UTC and tracks no timezone or daylight offset.
        .timezone = uefi.Time.unspecified_timezone,
        .daylight = .{ .in_daylight = false, .adjust_daylight = false, ._ = 0 },
        ._pad2 = 0,
    };
    // 1 Hz resolution: Weir tracks whole seconds.
    if (caps) |c| c.* = .{ .resolution = 1, .accuracy = 0, .sets_to_zero = false };
    return ok;
}

fn setTime(t: *const uefi.Time) callconv(.c) usize {
    const written = time.set(.{
        .year = t.year,
        .month = t.month,
        .day = t.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
    });
    // A present but read-only RTC cannot take the write.
    return if (written) ok else @intFromEnum(Status.device_error);
}

fn resetSystem(
    reset_type: u32,
    status: usize,
    data_size: usize,
    data: ?[*]const u16,
) callconv(.c) noreturn {
    _ = reset_type;
    _ = status;
    _ = data_size;
    _ = data;
    finisher().* = 0x5555; // power off
    cpu.halt();
}

// --- Table construction -----------------------------------------------------

var image_handle: ?*handledb.Handle = null;

pub fn imageHandle() uefi.Handle {
    return @ptrCast(image_handle orelse @as(*handledb.Handle, @ptrCast(@alignCast(&image_marker))));
}

fn fixCrc(comptime T: type, hdr: *tables.TableHeader, table: *const T) void {
    hdr.crc32 = 0;
    const bytes = @as([*]const u8, @ptrCast(table))[0..@sizeOf(T)];
    hdr.crc32 = std.hash.crc.Crc32.hash(bytes);
}

// The handle DB has spare capacity during table construction, so install never
// returns null here.
fn addProtocol(handle: ?*handledb.Handle, guid: *const uefi.Guid, iface: *anyopaque) void {
    _ = handledb.install(handle, guid, iface); // zippy:ignore discarded_error
}

/// Build the EFI System Table and return its address (passed to the app in a1).
/// `dtb`/`hartid` are published to the OS (config table + RISC-V boot protocol).
/// `image_base`/`image_size` describe the loaded app for LoadedImage.
pub fn prepare(dtb: usize, hartid: usize, image_base: usize, image_size: usize) usize {
    dtb_addr = dtb;
    boot_hartid = hartid;
    image_handle = handledb.create();
    for (&loaded_images) |*a| a.used = false;

    // Size the memory map to real RAM from the comptime SoC tree (soc.zig),
    // clamped above our page pool so a large kernel + initrd has room.
    const ram_top = soc.ram_base + soc.ram_size;
    if (ram_top > PAGE_POOL_BASE + 0x100000) RAM_END = ram_top;

    // Simple Text Output: real output, the rest succeed as no-ops.
    con_out_mode = .{
        .max_mode = 1,
        .mode = 0,
        .attribute = 0x07,
        .cursor_column = 0,
        .cursor_row = 0,
        .cursor_visible = true,
    };
    con_out = .{
        ._reset = @ptrFromInt(@intFromPtr(&outResetOut)),
        ._output_string = @ptrFromInt(@intFromPtr(&outString)),
        ._test_string = @ptrFromInt(@intFromPtr(&textOk)),
        ._query_mode = @ptrFromInt(@intFromPtr(&textOk)),
        ._set_mode = @ptrFromInt(@intFromPtr(&textOk)),
        ._set_attribute = @ptrFromInt(@intFromPtr(&textOk)),
        ._clear_screen = @ptrFromInt(@intFromPtr(&textOk)),
        ._set_cursor_position = @ptrFromInt(@intFromPtr(&textOk)),
        ._enable_cursor = @ptrFromInt(@intFromPtr(&textOk)),
        .mode = &con_out_mode,
    };

    // Event pool, and the single key event ConIn exposes as WaitForKey. The pool
    // is empty here, so the allocation cannot fail.
    for (&events) |*e| e.used = false;
    wait_key_event = eventAlloc().?;
    wait_key_event.is_wait_key = true;

    con_in = .{
        ._reset = @ptrFromInt(@intFromPtr(&inReset)),
        ._read_key_stroke = @ptrFromInt(@intFromPtr(&inReadKey)),
        .wait_for_key = @ptrCast(wait_key_event),
    };

    // Boot Services: stub everything, then install what a bootloader needs.
    stubAll(tables.BootServices, &boot_services);
    put(&boot_services, "raiseTpl", &raiseTpl);
    put(&boot_services, "restoreTpl", &restoreTpl);
    put(&boot_services, "_allocatePages", &allocatePages);
    put(&boot_services, "_freePages", &freePages);
    put(&boot_services, "_getMemoryMap", &getMemoryMap);
    put(&boot_services, "_allocatePool", &allocatePool);
    put(&boot_services, "_freePool", &freePool);
    put(&boot_services, "_handleProtocol", &handleProtocol);
    put(&boot_services, "_locateProtocol", &locateProtocol);
    put(&boot_services, "_openProtocol", &openProtocol);
    put(&boot_services, "_locateHandle", &locateHandle);
    put(&boot_services, "_locateHandleBuffer", &locateHandleBuffer);
    put(&boot_services, "_installProtocolInterface", &installProtocolInterface);
    put(&boot_services, "_installMultipleProtocolInterfaces", &installMultipleProtocolInterfaces);
    put(&boot_services, "_loadImage", &loadImage);
    put(&boot_services, "_startImage", &startImage);
    put(&boot_services, "_unloadImage", &unloadImage);
    put(&boot_services, "_locateDevicePath", &locateDevicePath);
    put(&boot_services, "_installConfigurationTable", &installConfigurationTable);
    put(&boot_services, "_exit", &exitApp);
    put(&boot_services, "_exitBootServices", &exitBootServices);
    put(&boot_services, "_stall", &stall);
    put(&boot_services, "_setWatchdogTimer", &setWatchdogTimer);
    put(&boot_services, "_createEvent", &createEvent);
    put(&boot_services, "_createEventEx", &createEventEx);
    put(&boot_services, "_setTimer", &setTimer);
    put(&boot_services, "_waitForEvent", &waitForEvent);
    put(&boot_services, "_checkEvent", &checkEvent);
    put(&boot_services, "_signalEvent", &signalEvent);
    put(&boot_services, "_closeEvent", &closeEvent);
    put(&boot_services, "_copyMem", &copyMem);
    put(&boot_services, "_setMem", &setMem);
    boot_services.hdr = .{
        .signature = tables.BootServices.signature,
        .revision = tables.SystemTable.revision_2_70,
        .header_size = @sizeOf(tables.BootServices),
        .crc32 = 0,
        .reserved = 0,
    };
    fixCrc(tables.BootServices, &boot_services.hdr, &boot_services);

    // Runtime Services: stub everything, then a working ResetSystem.
    stubAll(tables.RuntimeServices, &runtime_services);
    put(&runtime_services, "_resetSystem", &resetSystem);
    put(&runtime_services, "_setVirtualAddressMap", &setVirtualAddressMap);
    put(&runtime_services, "_getVariable", &getVariable);
    put(&runtime_services, "_setVariable", &setVariable);
    put(&runtime_services, "_getNextVariableName", &getNextVariableName);
    put(&runtime_services, "_queryVariableInfo", &queryVariableInfo);
    put(&runtime_services, "_getTime", &getTime);
    put(&runtime_services, "_setTime", &setTime);
    runtime_services.hdr = .{
        .signature = tables.RuntimeServices.signature,
        .revision = tables.SystemTable.revision_2_70,
        .header_size = @sizeOf(tables.RuntimeServices),
        .crc32 = 0,
        .reserved = 0,
    };
    fixCrc(tables.RuntimeServices, &runtime_services.hdr, &runtime_services);

    // RISC-V boot protocol (boot hartid) for the kernel stub.
    riscv_boot = .{
        .revision = 0x00010000,
        .get_boot_hartid = @ptrFromInt(@intFromPtr(&getBootHartid)),
    };

    // A bare End-of-Hardware device path for the loaded image.
    end_path = .{ .type = @enumFromInt(0x7f), .subtype = 0xff, .length = 4 };

    // Loaded Image protocol: where the app sits and its command line.
    loaded_image = .{
        .revision = 0x1000,
        .parent_handle = imageHandle(),
        .system_table = &system_table,
        .device_handle = imageHandle(),
        .file_path = &end_path,
        .reserved = @ptrCast(&image_marker),
        .load_options_size = @intCast((cmdline.len + 1) * 2),
        .load_options = @ptrCast(&cmdline),
        .image_base = @ptrFromInt(image_base),
        .image_size = image_size,
        .image_code_type = .loader_code,
        .image_data_type = .loader_data,
        ._unload = @ptrFromInt(@intFromPtr(&stub)),
    };

    // Hand the device tree to the OS through the configuration table.
    config_count = 0;
    if (dtb_addr != 0) {
        config_table[config_count] = .{
            .vendor_guid = DEVICE_TREE_GUID,
            .vendor_table = @ptrFromInt(dtb_addr),
        };
        config_count += 1;
    }

    // Advertise our (empty) runtime-services support so the OS does not call
    // services we never relocate into its address space (see RT_PROPERTIES_GUID).
    config_table[config_count] = .{
        .vendor_guid = RT_PROPERTIES_GUID,
        .vendor_table = @ptrCast(&rt_properties),
    };
    config_count += 1;

    // Publish SMBIOS/DMI so the OS sees real board info (dmidecode, /sys dmi).
    smbios.build(RAM_END - RAM_BASE);
    config_table[config_count] = .{
        .vendor_guid = smbios.SMBIOS3_GUID,
        .vendor_table = smbios.entryPoint(),
    };
    config_count += 1;

    // Publish the ACPI RSDP (if we linked QEMU's tables) so the OS can boot on
    // ACPI rather than the device tree.
    if (acpi_qemu.rsdp() != 0) {
        config_table[config_count] = .{
            .vendor_guid = ACPI_20_GUID,
            .vendor_table = @ptrFromInt(acpi_qemu.rsdp()),
        };
        config_count += 1;
    }

    system_table = .{
        .hdr = .{
            .signature = tables.SystemTable.signature,
            .revision = tables.SystemTable.revision_2_70,
            .header_size = @sizeOf(tables.SystemTable),
            .crc32 = 0,
            .reserved = 0,
        },
        .firmware_vendor = &vendor,
        .firmware_revision = 0x00010001,
        .console_in_handle = imageHandle(),
        .con_in = &con_in,
        .console_out_handle = imageHandle(),
        .con_out = &con_out,
        .standard_error_handle = imageHandle(),
        .std_err = &con_out,
        .runtime_services = &runtime_services,
        .boot_services = &boot_services,
        .number_of_table_entries = config_count,
        .configuration_table = &config_table,
    };
    fixCrc(tables.SystemTable, &system_table.hdr, &system_table);

    // Populate the handle/protocol database: Loaded Image on the image handle,
    // and the RISC-V boot protocol.
    addProtocol(image_handle, &uefi.protocol.LoadedImage.guid, &loaded_image);
    addProtocol(null, &RISCV_BOOT_GUID, &riscv_boot);
    // EFI_TCG2_PROTOCOL so the bootloader can measure into the same event log
    // and read it back for attestation.
    if (tpm.isAvailable()) tcg2.install();
    // Install a whole-disk Block I/O only if the boot manager has not already
    // published the ESP partition as its own volume. Two Block I/O views of the
    // same data collide in a bootloader's unique-sector matching.
    var existing_bio: [4]*handledb.Handle = undefined;
    if (handledb.locateHandles(&uefi.protocol.BlockIo.guid, &existing_bio) == 0) {
        _ = blockio.install(); // zippy:ignore discarded_error - no disk is acceptable
    }

    // The loaded image's device handle is the ESP volume. systemd-boot opens
    // Simple File System on it to read \loader\entries, so prefer a handle that
    // carries Simple File System. The boot manager put both Block I/O and Simple
    // File System on the ESP handle, so this also satisfies a Block I/O match
    // (Limine). Fall back to a bare Block I/O handle when no volume was published.
    var sfs_hs: [4]*handledb.Handle = undefined;
    const n_sfs = handledb.locateHandles(&uefi.protocol.SimpleFileSystem.guid, &sfs_hs);
    var bio_hs: [4]*handledb.Handle = undefined;
    const n_bio = handledb.locateHandles(&uefi.protocol.BlockIo.guid, &bio_hs);
    if (n_sfs > 0) {
        loaded_image.device_handle = @ptrCast(sfs_hs[0]);
    } else if (n_bio > 0) {
        loaded_image.device_handle = @ptrCast(bio_hs[0]);
    }

    return @intFromPtr(&system_table);
}
