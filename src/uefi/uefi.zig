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
const var_store = @import("../var/store.zig");
const rt = @import("rt.zig");
const handledb = @import("handledb.zig");
const blockio = @import("blockio.zig");
const initrd = @import("initrd.zig");
const page_alloc = @import("page_alloc.zig");
const pe = @import("../loader/pe.zig");
const fat = @import("../fs/fat.zig");
const soc = @import("soc");
const smbios = @import("../smbios/smbios.zig");
const display = @import("display.zig");
const unit_id = @import("../drivers/unit_id.zig");
const acpi_qemu = @import("../acpi/qemu.zig");
const mem = @import("../mem.zig");
const tpm = @import("../tpm/tpm.zig");
const tcg2 = @import("../tpm/tcg2.zig");
const time = @import("../time.zig");
const copy_mem = @import("copy_mem.zig");
const config = @import("../config.zig");

const Status = uefi.Status;
const tables = uefi.tables;

const SbiReset = enum(usize) { shutdown = 0, cold_reboot = 1, warm_reboot = 2 };

/// Asks the SBI layer for a system reset. The devices that do it are in M-mode.
fn sbiReset(kind: SbiReset) noreturn {
    asm volatile ("ecall"
        :
        : [kind] "{x10}" (@intFromEnum(kind)),
          [reason] "{x11}" (0),
          [fid] "{x16}" (0),
          [eid] "{x17}" (0x53525354),
        : .{ .x10 = true, .x11 = true, .memory = true });
    cpu.halt();
}

// Memory layout advertised to the app, derived from build-time ram_base (see
// mem.zig). Firmware and loaded image sit low. Pages come from the pool above.
const RAM_BASE = mem.ram_base;
// Usable RAM ceiling. The 256 MiB default is too small for a large netboot
// initrd, so prepare() replaces it with real top-of-RAM from the DTB /memory.
var RAM_END: usize = mem.ram_end_default;
// prepare() sets it. See poolBase.
var page_pool_base: usize = mem.page_pool_base orelse mem.load_base;

// prepare() builds these EFI tables and protocol structs before the app can
// read them, so an undefined start is safe. Zero-init would only add cost.
var system_table: tables.SystemTable = undefined; // zippy:ignore unsafe_undefined
var boot_services: tables.BootServices = undefined; // zippy:ignore unsafe_undefined
var con_out: uefi.protocol.SimpleTextOutput = undefined; // zippy:ignore unsafe_undefined
var con_out_mode: uefi.protocol.SimpleTextOutput.Mode = undefined; // zippy:ignore unsafe_undefined
var con_in: uefi.protocol.SimpleTextInput = undefined; // zippy:ignore unsafe_undefined
var config_table: [16]tables.ConfigurationTable = undefined;
var config_count: usize = 0;
var image_marker: u8 = 0;
var vendor = std.unicode.utf8ToUtf16LeStringLiteral("Lilith Semiconductor Weir").*;

// State an EFI app (the Linux kernel stub) needs: its loaded image, the boot
// hartid, the device tree, and a kernel command line. prepare() fills the
// structs below before the app can read them.
var loaded_image: uefi.protocol.LoadedImage = undefined; // zippy:ignore unsafe_undefined
var end_path: uefi.protocol.DevicePath = undefined; // zippy:ignore unsafe_undefined
var riscv_boot: RiscvBootProtocol = undefined; // zippy:ignore unsafe_undefined
var boot_hartid: usize = 0;
var dtb_addr: usize = 0;
var cmdline = std.unicode.utf8ToUtf16LeStringLiteral("earlycon=sbi console=ttyS0 keep_bootcon").*;
var load_options: ?[:0]u16 = &cmdline;

/// Set the load options of the first image. Null gives none. The buffer must
/// stay valid while the image runs.
pub fn setLoadOptions(options: ?[:0]u16) void {
    load_options = options;
}

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
// ExitBootServices. Only the variable services work, and only with a store.
// SetVirtualAddressMap is not in the list, so the OS keeps the runtime region
// at its physical address.
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

// One allocator over [page_pool_base, RAM_END), shared by AllocatePool and
// AllocatePages. The Linux EFI stub asks for multi-MiB buffers (2 MiB FDT, the
// relocated kernel), so it lives in conventional RAM, not a firmware array.
// prepare() sets it up. Until then it holds no memory.
var pages: page_alloc.PageAllocator = .init(0, 0);
var pool: page_alloc.Pool = .init(&pages);

const Region = struct { start: usize, end: usize };

// The first image, below the pool. The memory map reports it as loader code.
var first_image: Region = .{ .start = 0, .end = 0 };

const image_tag: page_alloc.Tag = .{ .kind = .loader_code, .owner = .firmware };
const boot_data_tag: page_alloc.Tag = .{ .kind = .boot_services_data, .owner = .firmware };

/// The page pool base for a first image that ends at `image_end`. The small
/// layout has no fixed base. There the pool starts after the image, 2 MiB aligned.
fn poolBase(image_end: usize) usize {
    if (mem.page_pool_base) |base| return base;
    return std.mem.alignForward(usize, @max(image_end, mem.load_base), 0x200000);
}

// The part of [start, end) that lies in the pool, or null.
fn poolPart(start: usize, end: usize) ?Region {
    const s = @max(start, pages.base);
    const e = @min(end, pages.end);
    return if (s < e) .{ .start = s, .end = e } else null;
}

// Linux reserves its image up to the next 2 MiB boundary. A large allocation
// that starts below that boundary would overlap it.
fn pageAlignment(size: usize) usize {
    return if (size >= 0x200000) 0x200000 else 4096;
}

fn wholePages(size: usize) ?usize {
    const padded = std.math.add(usize, size, 4095) catch return null;
    return padded & ~@as(usize, 4095);
}

const ok = @backingInt(Status.success);

// Images loaded through the LoadImage boot service (the bootloader loading a
// kernel). Each keeps its entry point and a LoadedImage protocol the app reads
// and edits (systemd-boot sets the kernel command line on it before StartImage).
const MAX_LOADED_IMAGES = 4;
const LoadedImage = struct {
    used: bool = false,
    handle: ?*handledb.Handle = null,
    entry: usize = 0,
    /// The pool block that holds the image.
    block: Region = .{ .start = 0, .end = 0 },
    /// UnloadImage keeps the block of a started image, as its code can still run.
    started: bool = false,
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
    return @backingInt(Status.unsupported);
}

const not_found = @backingInt(Status.not_found);

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
    const g = guid orelse return @backingInt(Status.invalid_parameter);
    var tmp: [32]*handledb.Handle = undefined;
    const n = handledb.locateHandles(g, &tmp);
    const needed = n * @sizeOf(uefi.Handle);
    if (buffer == null or buffer_size.* < needed) {
        buffer_size.* = needed;
        return @backingInt(Status.buffer_too_small);
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
    const g = guid orelse return @backingInt(Status.invalid_parameter);
    var tmp: [32]*handledb.Handle = undefined;
    const n = handledb.locateHandles(g, &tmp);
    if (n == 0) return not_found;
    var out: ?*anyopaque = null;
    if (allocatePool(@backingInt(tables.MemoryType.boot_services_data), n * @sizeOf(uefi.Handle), &out) != ok) {
        return @backingInt(Status.out_of_resources);
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
        return @backingInt(Status.out_of_resources);
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
            return @backingInt(Status.out_of_resources);
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
        if (config_count >= config_table.len) return @backingInt(Status.out_of_resources);
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
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime std.mem.eql(u8, name, "hdr")) continue;
        if (comptime @typeInfo(field_type) == .pointer) {
            @field(table.*, name) = @ptrFromInt(@intFromPtr(&stub));
        }
    }
}

/// Install typed implementations into a service table. Each field of `impls`
/// names the table field it fills.
fn install(table: anytype, impls: anytype) void {
    inline for (@typeInfo(@TypeOf(impls)).@"struct".field_names) |name| {
        @field(table.*, name) = @ptrFromInt(@intFromPtr(@field(impls, name)));
    }
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
    if (key_len == 0) return @backingInt(Status.not_ready);

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
    if (dec.scan == 0 and dec.char == 0) return @backingInt(Status.not_ready);
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
    const kind = page_alloc.Kind.fromEfi(pool_type) orelse return @backingInt(Status.invalid_parameter);
    const addr = pool.alloc(size, kind) orelse return @backingInt(Status.out_of_resources);
    buffer.* = @ptrFromInt(addr);
    if (trace) console.out.print("[uefi]   -> pool at {x} size={d}\n", .{ addr, size }) catch {};
    return ok;
}

fn freePool(buffer: *anyopaque) callconv(.c) usize {
    const addr = @intFromPtr(buffer);
    if (trace) console.out.print("[uefi] freePool at={x}\n", .{addr}) catch {};
    return if (pool.free(addr)) ok else @backingInt(Status.invalid_parameter);
}

fn allocatePages(alloc_type: u32, mem_type: u32, page_count: usize, memory: *usize) callconv(.c) usize {
    const kind = page_alloc.Kind.fromEfi(mem_type) orelse return @backingInt(Status.invalid_parameter);
    const tag: page_alloc.Tag = .{ .kind = kind, .owner = .caller };
    const out_of_resources = @backingInt(Status.out_of_resources);
    if (trace) console.out.print(
        "[uefi] allocatePages type={d} pages={d} at={x}\n",
        .{ alloc_type, page_count, memory.* },
    ) catch {};
    const size = std.math.mul(usize, page_count, 4096) catch return out_of_resources;
    const limit: usize = switch (alloc_type) {
        // AllocateAnyPages
        0 => pages.end,
        // AllocateMaxAddress: the block ends at or below memory.*.
        1 => memory.* +| 1,
        // AllocateAddress: reject placements outside RAM or onto the running
        // firmware. The part in the pool must be free and page aligned. The
        // part below the pool is not managed.
        2 => {
            const req = memory.*;
            const end = std.math.add(usize, req, size) catch return out_of_resources;
            if (req < FW_RESERVED_END or end > RAM_END) return out_of_resources;
            if (poolPart(req, end)) |p| {
                if (!pages.allocAt(p.start, p.end - p.start, tag)) return not_found;
            }
            if (trace) console.out.print("[uefi]   -> pages at {x}\n", .{req}) catch {};
            return ok;
        },
        else => return @backingInt(Status.invalid_parameter),
    };
    const addr = pages.alloc(size, pageAlignment(size), limit, tag) orelse return out_of_resources;
    memory.* = addr;
    if (trace) console.out.print("[uefi]   -> pages at {x}\n", .{addr}) catch {};
    return ok;
}

// A range outside the pool is accepted and left alone. In the pool, only pages
// that AllocatePages gave out can be freed.
fn freePages(memory: usize, page_count: usize) callconv(.c) usize {
    if (trace) console.out.print("[uefi] freePages at={x} pages={d}\n", .{ memory, page_count }) catch {};
    if (memory % 4096 != 0) return @backingInt(Status.invalid_parameter);
    const size = std.math.mul(usize, page_count, 4096) catch return @backingInt(Status.invalid_parameter);
    const end = std.math.add(usize, memory, size) catch return @backingInt(Status.invalid_parameter);
    if (poolPart(memory, end)) |p| {
        if (!pages.free(p.start, p.end - p.start, .caller)) return not_found;
    }
    return ok;
}

// Weir itself (code + bss) lives below this line. The firmware keeps running in
// M-mode after the OS starts, so the OS must reserve this region.
const FW_RESERVED_END = mem.fw_reserved_end;

/// The runtime region, when it lies in order inside the firmware reserved
/// window. Else the memory map reports the window as one reserved region.
fn runtimeRegion() ?rt.Bounds {
    const r = rt.bounds();
    const in_place = RAM_BASE <= r.text_start and r.text_start <= r.text_end and
        r.text_end == r.data_start and r.data_start <= r.data_end and r.data_end <= FW_RESERVED_END;
    return if (in_place) r else null;
}

// EFI_MEMORY_WB: ordinary writeback cacheable RAM. EFI_MEMORY_RUNTIME: the OS
// maps the range to call the runtime services.
const attr_wb: u64 = 0x8;
const attr_runtime: u64 = 1 << 63;

/// Builds the memory map. With no buffer it only counts, so the size query and
/// the fill give the same map. A descriptor joins its lower neighbour when both
/// have the same type and attributes.
const MapWriter = struct {
    out: ?[*]tables.MemoryDescriptor,
    count: usize = 0,
    last_type: tables.MemoryType = .reserved_memory_type,
    last_attr: u64 = 0,
    last_end: usize = 0,

    fn add(w: *MapWriter, t: tables.MemoryType, start: usize, end: usize, attr: u64) void {
        std.debug.assert(start <= end);
        if (start == end) return;
        // The map has no gap and no overlap, from RAM_BASE through the pool.
        std.debug.assert(start == if (w.count == 0) RAM_BASE else w.last_end);
        const n = (end - start) / 4096;
        if (w.count > 0 and t == w.last_type and attr == w.last_attr and start == w.last_end) {
            if (w.out) |o| o[w.count - 1].number_of_pages += n;
        } else {
            if (w.out) |o| o[w.count] = .{
                .type = t,
                .physical_start = start,
                .virtual_start = 0,
                .number_of_pages = n,
                .attribute = @bitCast(attr),
            };
            w.count += 1;
        }
        w.last_type = t;
        w.last_attr = attr;
        w.last_end = end;
    }
};

fn memoryType(kind: page_alloc.Kind) tables.MemoryType {
    return switch (kind) {
        .reserved => .reserved_memory_type,
        .loader_code => .loader_code,
        .loader_data => .loader_data,
        .boot_services_code => .boot_services_code,
        .boot_services_data => .boot_services_data,
        .runtime_services_code => .runtime_services_code,
        .runtime_services_data => .runtime_services_data,
        .acpi_reclaim => .acpi_reclaim_memory,
        .acpi_nvs => .acpi_memory_nvs,
    };
}

fn writeMap(w: *MapWriter) void {
    const have_acpi = acpi_qemu.rsdp() != 0;
    // In the small layout the ACPI pool is the top of the firmware window.
    const acpi_in_window = mem.acpi_pool_base < FW_RESERVED_END;
    const reserved_end = if (have_acpi and acpi_in_window) acpi_qemu.POOL_BASE else FW_RESERVED_END;
    const acpi_end = acpi_qemu.POOL_BASE + acpi_qemu.POOL_SIZE;

    // The running firmware: reserved so the OS never reclaims it. The OS maps
    // the runtime code and data to call the variable services.
    if (runtimeRegion()) |r| {
        w.add(.reserved_memory_type, RAM_BASE, r.text_start, attr_wb);
        w.add(.runtime_services_code, r.text_start, r.text_end, attr_wb | attr_runtime);
        w.add(.runtime_services_data, r.data_start, r.data_end, attr_wb | attr_runtime);
        w.add(.reserved_memory_type, r.data_end, reserved_end, attr_wb);
    } else {
        w.add(.reserved_memory_type, RAM_BASE, reserved_end, attr_wb);
    }
    // The linked ACPI tables: reclaimable once the OS has parsed them.
    if (have_acpi and acpi_in_window) w.add(.acpi_reclaim_memory, acpi_qemu.POOL_BASE, acpi_end, attr_wb);
    // Low boot allocations up to the ACPI pool if present. The first image in
    // this region is loader code.
    const bsd_end = if (have_acpi and !acpi_in_window) acpi_qemu.POOL_BASE else page_pool_base;
    const image_start = @min(@max(first_image.start, FW_RESERVED_END), bsd_end);
    const image_end = @min(@max(first_image.end, image_start), bsd_end);
    w.add(.boot_services_data, FW_RESERVED_END, image_start, attr_wb);
    w.add(.loader_code, image_start, image_end, attr_wb);
    w.add(.boot_services_data, image_end, bsd_end, attr_wb);
    if (have_acpi and !acpi_in_window) w.add(.acpi_reclaim_memory, acpi_qemu.POOL_BASE, acpi_end, attr_wb);
    // The pool: free memory is conventional, allocated memory has its tag.
    var it = pages.walk();
    while (it.next()) |s| {
        const tag = s.tag orelse {
            w.add(.conventional_memory, s.start, s.end, attr_wb);
            continue;
        };
        const runtime = tag.kind == .runtime_services_code or tag.kind == .runtime_services_data;
        w.add(memoryType(tag.kind), s.start, s.end, if (runtime) attr_wb | attr_runtime else attr_wb);
    }
}

// The map key is the allocator generation, so any change to the map gives a new key.
fn getMemoryMap(
    mmap_size: *usize,
    mmap: ?[*]u8,
    map_key: *usize,
    desc_size: *usize,
    desc_ver: *u32,
) callconv(.c) usize {
    tr("getMemoryMap");
    var counter: MapWriter = .{ .out = null };
    writeMap(&counter);
    const needed = counter.count * @sizeOf(tables.MemoryDescriptor);
    desc_size.* = @sizeOf(tables.MemoryDescriptor);
    desc_ver.* = 1;
    if (mmap == null or mmap_size.* < needed) {
        mmap_size.* = needed;
        return @backingInt(Status.buffer_too_small);
    }
    var w: MapWriter = .{ .out = @ptrCast(@alignCast(mmap.?)) };
    writeMap(&w);
    std.debug.assert(w.count == counter.count);
    mmap_size.* = needed;
    map_key.* = pages.generation;
    return ok;
}

fn copyMem(dest: [*]u8, src: [*]const u8, len: usize) callconv(.c) void {
    // The Linux EFI stub routes memmove through CopyMem; preserve overlap
    // semantics while using aligned 64-bit operations on the River DDR path.
    copy_mem.copyMem(dest, src, len);
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
    // A key from an earlier map: the caller gets the map again and retries.
    if (map_key != pages.generation) return @backingInt(Status.invalid_parameter);
    // The application takes over the machine. Only the variable services stay.
    // A second call does the same work again, so a retry is safe.
    rt.seal();
    const info = @typeInfo(tables.RuntimeServices).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime @typeInfo(field_type) == .pointer and !rt.keepsAtRuntime(name)) {
            @field(rt.table, name) = @ptrFromInt(@intFromPtr(&rt.unsupported));
        }
    }
    fixCrc(tables.RuntimeServices, &rt.table.hdr, &rt.table);
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
    sbiReset(.shutdown);
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
    // A file goes to a scratch block that is freed once the image is loaded.
    var scratch: ?Region = null;
    defer if (scratch) |s| {
        _ = pages.free(s.start, s.end - s.start, .firmware);
    };
    const src: []const u8 = if (source_buffer) |sb| blk: {
        if (source_size == 0) return @backingInt(Status.invalid_parameter);
        break :blk sb[0..source_size];
    } else blk: {
        const dp = device_path orelse return @backingInt(Status.invalid_parameter);
        var name_buf: [256]u8 = undefined;
        const path = devicePathFile(@ptrCast(dp), &name_buf) orelse return not_found;
        const fsize = fat.fileSize(path) orelse return not_found;
        const ssize = wholePages(fsize) orelse return @backingInt(Status.out_of_resources);
        const sbase = pages.alloc(ssize, 4096, pages.end, boot_data_tag) orelse return @backingInt(Status.out_of_resources);
        scratch = .{ .start = sbase, .end = sbase + ssize };
        const sbuf = @as([*]u8, @ptrFromInt(sbase))[0..fsize];
        // A multi-MiB image over polled SPI takes many seconds. Announce the read
        // so a slow load reads as progress, not a hang.
        const got_opt = fat.readFile(path, sbuf);
        const got = got_opt orelse return @backingInt(Status.device_error);
        if (got != fsize) return @backingInt(Status.device_error);
        break :blk sbuf;
    };

    // Place the image in a fresh pool block, aligned as AllocatePages aligns a
    // block of its size. The block stays allocated until UnloadImage.
    const image_size = pe.sizeOf(src) catch return @backingInt(Status.load_error);
    const block_size = wholePages(image_size) orelse return @backingInt(Status.out_of_resources);
    const base = pages.alloc(block_size, pageAlignment(block_size), pages.end, image_tag) orelse return @backingInt(Status.out_of_resources);
    var keep_image = false;
    defer if (!keep_image) {
        _ = pages.free(base, block_size, .firmware);
    };
    const loaded = pe.loadAt(src, base, image_size) catch return @backingInt(Status.load_error);

    const slot = loadedImageSlot() orelse return @backingInt(Status.out_of_resources);
    const h = handledb.create() orelse return @backingInt(Status.out_of_resources);
    keep_image = true;
    slot.used = true;
    slot.handle = h;
    slot.entry = loaded.entry;
    slot.block = .{ .start = base, .end = base + block_size };
    slot.started = false;
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

fn ticksToUs(ticks: u64) u64 {
    return if (soc.timebase_hz == 0) 0 else ticks * 1_000_000 / soc.timebase_hz;
}

/// StartImage: enter a loaded image in S-mode, exactly as an EFI loader would,
/// with a0 = its image handle and a1 = the system table. It returns only if it
/// does not boot (a kernel calls ExitBootServices and never comes back).
fn startImage(image: uefi.Handle, exit_data_size: ?*usize, exit_data: ?*[*]u16) callconv(.c) usize {
    tr("startImage");
    _ = exit_data;
    if (exit_data_size) |s| s.* = 0;
    const h: *handledb.Handle = @ptrCast(@alignCast(image));
    const slot = findLoadedImage(h) orelse return @backingInt(Status.invalid_parameter);
    const EntryFn = *const fn (uefi.Handle, *tables.SystemTable) callconv(.c) Status;
    const entry: EntryFn = @ptrFromInt(slot.entry);
    slot.started = true;
    return @backingInt(entry(image, &system_table));
}

/// UnloadImage: drop a loaded image. This frees the registry slot and the
/// handle, and the image block when the image was never started.
fn unloadImage(image: uefi.Handle) callconv(.c) usize {
    const h: *handledb.Handle = @ptrCast(@alignCast(image));
    if (findLoadedImage(h)) |slot| {
        slot.used = false;
        if (slot.handle) |hh| hh.used = false;
        if (!slot.started) _ = pages.free(slot.block.start, slot.block.end - slot.block.start, .firmware);
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
    const e = eventAlloc() orelse return @backingInt(Status.out_of_resources);
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
    const e = eventOf(event) orelse return @backingInt(Status.invalid_parameter);
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
        else => return @backingInt(Status.invalid_parameter),
    }
    return ok;
}

fn waitForEvent(event_len: usize, evs: [*]const ?*anyopaque, index: *usize) callconv(.c) usize {
    if (event_len == 0) return @backingInt(Status.invalid_parameter);
    var i: usize = 0;
    while (i < event_len) : (i += 1) {
        if (eventOf(evs[i]) == null) {
            index.* = i;
            return @backingInt(Status.invalid_parameter);
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
    const e = eventOf(event) orelse return @backingInt(Status.invalid_parameter);
    if (eventReady(e)) {
        e.signaled = false;
        return ok;
    }
    return @backingInt(Status.not_ready);
}

fn signalEvent(event: ?*anyopaque) callconv(.c) usize {
    const e = eventOf(event) orelse return @backingInt(Status.invalid_parameter);
    e.signaled = true;
    if (e.notify_fn) |f| f(@ptrCast(e), e.notify_ctx);
    return ok;
}

fn closeEvent(event: ?*anyopaque) callconv(.c) usize {
    const e = eventOf(event) orelse return @backingInt(Status.invalid_parameter);
    // The key event belongs to ConIn, not the app: keep it alive.
    if (e != wait_key_event) e.used = false;
    return ok;
}

// --- Runtime Services -------------------------------------------------------

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
    return if (written) ok else @backingInt(Status.device_error);
}

const efi_reset_warm = 1;
const efi_reset_shutdown = 2;

fn resetSystem(
    reset_type: u32,
    status: usize,
    data_size: usize,
    data: ?[*]const u16,
) callconv(.c) noreturn {
    _ = status;
    _ = data_size;
    _ = data;
    sbiReset(switch (reset_type) {
        efi_reset_warm => .warm_reboot,
        efi_reset_shutdown => .shutdown,
        else => .cold_reboot,
    });
}

// --- Table construction -----------------------------------------------------

var image_handle: ?*handledb.Handle = null;

pub fn imageHandle() uefi.Handle {
    return @ptrCast(image_handle orelse @as(*handledb.Handle, @ptrCast(@alignCast(&image_marker))));
}

fn fixCrc(comptime T: type, hdr: *tables.TableHeader, table: *const T) void {
    hdr.crc32 = 0;
    const bytes = @as([*]const u8, @ptrCast(table))[0..@sizeOf(T)];
    hdr.crc32 = std.hash.Crc32.hash(bytes);
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
    page_pool_base = poolBase(image_base + image_size);
    first_image = .{ .start = image_base & ~@as(usize, 4095), .end = std.mem.alignForward(usize, image_base + image_size, 4096) };
    const ram_top = soc.ram_base + soc.ram_size;
    if (ram_top > page_pool_base + 0x100000) RAM_END = ram_top;

    // The boot sources install the initrd before they call prepare(), and the
    // first allocation comes later through a boot service. Take the page
    // rounded initrd out of the pool so nothing is allocated over it. It is
    // boot services data: the OS can reclaim it once the stub has copied it.
    pages = .init(page_pool_base, RAM_END);
    pool = .init(&pages);
    // A kernel too large for the first image window loads in the pool. The
    // memory map then reports it through the pool walk.
    if (poolPart(first_image.start, first_image.end)) |p| {
        if (!pages.allocAt(p.start, p.end - p.start, image_tag)) {
            console.err.print("[uefi] the first image at {x} overlaps used pool memory, halting\n", .{image_base}) catch {};
            cpu.halt();
        }
    }
    if (initrd.region()) |r| {
        const s = r.base & ~@as(usize, 4095);
        const e = std.mem.alignForward(usize, r.base + r.len, 4096);
        if (poolPart(s, e)) |p| _ = pages.allocAt(p.start, p.end - p.start, boot_data_tag);
    }
    display.setup(&pages, &pool);

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
    install(&boot_services, .{
        .raiseTpl = &raiseTpl,
        .restoreTpl = &restoreTpl,
        ._allocatePages = &allocatePages,
        ._freePages = &freePages,
        ._getMemoryMap = &getMemoryMap,
        ._allocatePool = &allocatePool,
        ._freePool = &freePool,
        ._handleProtocol = &handleProtocol,
        ._locateProtocol = &locateProtocol,
        ._openProtocol = &openProtocol,
        ._locateHandle = &locateHandle,
        ._locateHandleBuffer = &locateHandleBuffer,
        ._installProtocolInterface = &installProtocolInterface,
        ._installMultipleProtocolInterfaces = &installMultipleProtocolInterfaces,
        ._loadImage = &loadImage,
        ._startImage = &startImage,
        ._unloadImage = &unloadImage,
        ._locateDevicePath = &locateDevicePath,
        ._installConfigurationTable = &installConfigurationTable,
        ._exit = &exitApp,
        ._exitBootServices = &exitBootServices,
        ._stall = &stall,
        ._setWatchdogTimer = &setWatchdogTimer,
        ._createEvent = &createEvent,
        ._createEventEx = &createEventEx,
        ._setTimer = &setTimer,
        ._waitForEvent = &waitForEvent,
        ._checkEvent = &checkEvent,
        ._signalEvent = &signalEvent,
        ._closeEvent = &closeEvent,
        ._copyMem = &copyMem,
        ._setMem = &setMem,
    });
    boot_services.hdr = .{
        .signature = tables.BootServices.signature,
        .revision = tables.SystemTable.revision_2_70,
        .header_size = @sizeOf(tables.BootServices),
        .crc32 = 0,
        .reserved = 0,
    };
    fixCrc(tables.BootServices, &boot_services.hdr, &boot_services);

    // Runtime Services: stub everything, then a working ResetSystem.
    stubAll(tables.RuntimeServices, &rt.table);
    install(&rt.table, .{
        ._resetSystem = &resetSystem,
        ._getVariable = &rt.getVariable,
        ._setVariable = &rt.setVariable,
        ._getNextVariableName = &rt.getNextVariableName,
        ._queryVariableInfo = &rt.queryVariableInfo,
        ._getTime = &getTime,
        ._setTime = &setTime,
    });
    rt.table.hdr = .{
        .signature = tables.RuntimeServices.signature,
        .revision = tables.SystemTable.revision_2_70,
        .header_size = @sizeOf(tables.RuntimeServices),
        .crc32 = 0,
        .reserved = 0,
    };
    fixCrc(tables.RuntimeServices, &rt.table.hdr, &rt.table);

    // RISC-V boot protocol (boot hartid) for the kernel stub.
    riscv_boot = .{
        .revision = 0x00010000,
        .get_boot_hartid = @ptrFromInt(@intFromPtr(&getBootHartid)),
    };

    // A bare End-of-Hardware device path for the loaded image.
    end_path = .{ .type = @fromBackingInt(@intCast(0x7f)), .subtype = 0xff, .length = 4 };

    // Loaded Image protocol: where the app sits and its command line.
    loaded_image = .{
        .revision = 0x1000,
        .parent_handle = imageHandle(),
        .system_table = &system_table,
        .device_handle = imageHandle(),
        .file_path = &end_path,
        .reserved = @ptrCast(&image_marker),
        .load_options_size = if (load_options) |o| @intCast((o.len + 1) * 2) else 0,
        .load_options = if (load_options) |o| @ptrCast(o.ptr) else null,
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

    // Tell the OS which runtime services it can call (see RT_PROPERTIES_GUID).
    // 0x2070 is GetVariable, GetNextVariableName, SetVariable and QueryVariableInfo.
    // The mask is 0 when there is no store or the runtime region is not in place.
    rt_properties.runtime_services_supported = if (var_store.available() and runtimeRegion() != null) 0x2070 else 0;
    config_table[config_count] = .{
        .vendor_guid = RT_PROPERTIES_GUID,
        .vendor_table = @ptrCast(&rt_properties),
    };
    config_count += 1;

    // Publish SMBIOS/DMI so the OS sees real board info (dmidecode, /sys dmi).
    smbios.build(RAM_END - RAM_BASE, unit_id.read());
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
        // Major in the high 16 bits, minor in the low 16, the usual layout an
        // OS reads from the system table.
        .firmware_revision = @as(u32, @intCast(config.version.major)) << 16 |
            @as(u32, @intCast(config.version.minor)),
        .console_in_handle = imageHandle(),
        .con_in = &con_in,
        .console_out_handle = imageHandle(),
        .con_out = &con_out,
        .standard_error_handle = imageHandle(),
        .std_err = &con_out,
        .runtime_services = &rt.table,
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
