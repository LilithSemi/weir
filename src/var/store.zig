//! The EFI variable store. It puts the variable log on the SPI flash or on the
//! QEMU CFI flash, as the device tree tells at build time.

const std = @import("std");
const builtin = @import("builtin");
const soc = @import("soc");
const build_options = @import("build_options");
const console = @import("../console/console.zig");
const cfi = @import("../flash/cfi.zig");
const spi_nor = @import("../flash/spi_nor.zig");
const log = @import("log.zig");
const efi = @import("efi.zig");

pub const Result = efi.Result;
pub const weir_guid = efi.weir_guid;

const Backend = enum { spi, cfi, none };

const backend: Backend = if (soc.flash_ctrl_base != null and soc.vars_partition_index != null)
    .spi
else if (soc.cfi_vars_base != null)
    .cfi
else
    .none;

/// The `river-vars` partition. Bank 0 is in the first half and bank 1 in the second half.
const SpiFlash = struct {
    const partition = soc.flash_partitions[soc.vars_partition_index.?];
    const half: usize = @intCast(partition.size / 2);
    const geometry: log.Geometry = .{
        .bank_offsets = .{ 0, half },
        .bank_len = @min(half, 128 * 1024),
        .erase_size = spi_nor.sector_size,
    };

    const xip = soc.flash_xip orelse @compileError("the SPI flash needs an xip region in reg-names");

    comptime {
        if (partition.offset + partition.size > xip.size)
            @compileError("the river-vars partition is past the xip region");
        if (partition.size < 32 * 1024) @compileError("the river-vars partition must be at least 32 KiB");
        if (partition.size % 8192 != 0 or partition.offset % 8192 != 0)
            @compileError("the river-vars partition offset and size must be multiples of 8 KiB");
        if (partition.offset + partition.size > 1 << 24)
            @compileError("the river-vars partition must be in the first 16 MiB of the flash");
    }

    driver: spi_nor.Driver(spi_nor.Mmio),

    pub fn read(self: *SpiFlash, off: usize, buf: []u8) void {
        _ = self;
        const src: [*]const u8 = @ptrFromInt(xip.base + partition.offset + off);
        @memcpy(buf, src[0..buf.len]);
    }

    /// The data cache can hold old lines of the xip window. On River only `fence.i`
    /// empties the data cache, so the next read gets the bytes from the flash.
    pub fn sync(self: *SpiFlash) void {
        _ = self;
        switch (builtin.cpu.arch) {
            .riscv64 => asm volatile ("fence.i" ::: .{ .memory = true }),
            else => @compileError("the SPI flash store needs riscv64"),
        }
    }

    pub fn erase(self: *SpiFlash, off: usize) bool {
        return self.driver.eraseSector(@intCast(partition.offset + off));
    }

    pub fn program(self: *SpiFlash, off: usize, bytes: []const u8) bool {
        return self.driver.program(@intCast(partition.offset + off), bytes);
    }
};

/// Block 0 and block 1 of the second CFI bank.
const CfiFlash = struct {
    const erase_size = 256 * 1024;
    const geometry: log.Geometry = .{
        .bank_offsets = .{ 0, erase_size },
        .bank_len = 128 * 1024,
        .erase_size = erase_size,
    };

    bank: cfi.Bank,

    pub fn read(self: *CfiFlash, off: usize, buf: []u8) void {
        self.bank.read(off, buf);
    }

    /// The bank is in read array mode after each erase and program.
    pub fn sync(self: *CfiFlash) void {
        _ = self;
    }

    pub fn erase(self: *CfiFlash, off: usize) bool {
        return self.bank.eraseBlock(off);
    }

    /// The bank programs whole words. The log gives word aligned offsets and lengths.
    pub fn program(self: *CfiFlash, off: usize, bytes: []const u8) bool {
        std.debug.assert(off % 4 == 0 and bytes.len % 4 == 0);
        return self.bank.program(off, bytes);
    }
};

const Flash = switch (backend) {
    .spi => SpiFlash,
    .cfi => CfiFlash,
    .none => void,
};

const Store = switch (backend) {
    .spi, .cfi => log.Store(Flash, Flash.geometry),
    .none => void,
};

var spi_bus: spi_nor.Mmio = .{ .base = soc.flash_ctrl_base orelse 0 };
var flash: Flash = undefined;
// Set up in place by `init`, because it is too large for the stack.
var store: Store = undefined;
var ready = false;
var sealed = false;

pub fn init() void {
    if (backend == .none) {
        console.out.writeAll("[var] no variable store on this platform\n") catch {};
    } else {
        initStore();
    }
}

fn initStore() void {
    switch (backend) {
        .spi => {
            flash = .{ .driver = .{ .bus = &spi_bus } };
            switch (flash.driver.quadEnable()) {
                .ok => {},
                .failed => console.out.writeAll("[flash] quad enable failed. Reads use one data line\n") catch {},
                .unknown_id => console.out.writeAll("[flash] unknown flash id. Reads use one data line\n") catch {},
            }
        },
        .cfi => {
            const bank = cfi.Bank.init(soc.cfi_vars_base.?) orelse return noFlash();
            console.out.print(
                "[flash] cfi NOR @ {x}, {d} MiB, {d} KiB blocks\n",
                .{ bank.base, cfi.SIZE >> 20, bank.block_size >> 10 },
            ) catch {};
            if (bank.block_size != CfiFlash.erase_size) return noFlash();
            flash = .{ .bank = bank };
        },
        .none => comptime unreachable,
    }
    store.setup(&flash);
    const loaded = store.load();
    ready = true;

    var count: usize = 0;
    var key = store.next(null);
    while (key) |k| : (key = store.next(k)) count += 1;
    switch (backend) {
        .spi => console.out.print("[var] spi flash store @ {x}, {d} variable(s)\n", .{ SpiFlash.partition.offset, count }) catch {},
        .cfi => console.out.print("[var] cfi flash store @ {x}, {d} variable(s)\n", .{ flash.bank.base, count }) catch {},
        .none => comptime unreachable,
    }
    if (loaded == .recovered) console.out.writeAll("[var] recovered after an incomplete write\n") catch {};

    if (backend == .spi) applyFlashLock();
    if (build_options.var_selftest) selfTest();
}

fn noFlash() void {
    console.out.writeAll("[var] no flash. Variables are unavailable\n") catch {};
}

fn wide(comptime s: []const u8) []const u16 {
    const w = std.unicode.utf8ToUtf16LeStringLiteral(s);
    return w.ptr[0 .. w.len + 1];
}

comptime {
    // The lock mask has one bit for each partition.
    if (soc.flash_partitions.len > 32) @compileError("the lock mask holds at most 32 flash partitions");
}

/// Locks the partitions that the non-volatile `FlashLock` variable names, one bit for each partition.
fn applyFlashLock() void {
    const entry = store.get(wide("FlashLock"), &weir_guid) orelse return;
    if (entry.attributes & efi.non_volatile == 0 or entry.data.len != 4) return;
    const requested = std.mem.readInt(u32, entry.data[0..4], .little);
    const mask = efi.lockMask(requested, soc.vars_partition_index.?, soc.flash_partitions.len);
    if (mask == 0) return;
    if (!flash.driver.lock(mask) or (flash.driver.lockMask() & mask) != mask) {
        console.out.writeAll("[flash] lock failed\n") catch {};
        return;
    }
    console.out.writeAll("[flash] locked partitions:") catch {};
    for (soc.flash_partitions, 0..) |p, i| {
        if (mask >> @intCast(i) & 1 != 0) console.out.print(" {s}", .{p.label}) catch {};
    }
    console.out.writeAll("\n") catch {};
}

pub fn available() bool {
    return ready;
}

/// Applies the rules for the time after ExitBootServices. Nothing clears it.
pub fn seal() void {
    @atomicStore(bool, &sealed, true, .release);
}

fn isSealed() bool {
    return @atomicLoad(bool, &sealed, .acquire);
}

/// Copy a variable's data out. On buffer_too_small, sets `data_size` to the required size.
pub fn get(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attributes: ?*u32,
    data_size: *usize,
    data: ?[*]u8,
) Result {
    if (backend == .none or !ready) return .not_found;
    const units = efi.nameUnits(name, log.max_name_units) orelse return .not_found;
    const entry = store.get(name[0..units], guid) orelse return .not_found;
    if (!efi.visible(isSealed(), entry.attributes)) return .not_found;
    if (attributes) |a| a.* = entry.attributes;
    if (data == null or data_size.* < entry.data.len) {
        data_size.* = entry.data.len;
        return .buffer_too_small;
    }
    @memcpy(data.?[0..entry.data.len], entry.data);
    data_size.* = entry.data.len;
    return .success;
}

/// Set or replace a variable. A `data_size` or `attributes` of 0 removes it.
pub fn set(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attributes: u32,
    data_size: usize,
    data: ?[*]const u8,
) Result {
    const kind = efi.setKind(attributes, data_size);
    if (backend == .none or !ready) return if (kind == .remove) .not_found else .device_error;
    if (kind == .invalid) return .invalid;
    const units = efi.nameUnits(name, log.max_name_units) orelse return .out_of_resources;
    if (units == 1) return .invalid;
    const key = name[0..units];
    if (isSealed()) {
        const existing = if (store.get(key, guid)) |e| e.attributes else null;
        if (efi.sealedSet(kind, attributes, existing)) |result| return result;
    }
    if (kind == .remove) {
        const existed = store.remove(key, guid) catch |err| return efi.fromSetError(err);
        return if (existed) .success else .not_found;
    }
    if (data_size > log.max_data_len) return .invalid;
    const bytes = data orelse return .invalid;
    store.set(key, guid, attributes, bytes[0..data_size]) catch |err| return efi.fromSetError(err);
    return .success;
}

/// Enumerate variables. An empty `name` starts the walk. Else `name` and `guid`
/// give the previous variable, and they get the next one. A `name` with no
/// terminator in its `name_size` bytes is invalid.
pub fn next(name_size: *usize, name: [*:0]u16, guid: *[16]u8) Result {
    if (backend == .none or !ready) return .not_found;
    var prev: ?log.Key = null;
    const units = efi.nextNameUnits(name, name_size.*) orelse return .invalid;
    if (units > 1) {
        prev = .{ .name = name[0..units], .guid = guid };
        const old = store.get(prev.?.name, guid);
        if (!efi.nextPrevValid(isSealed(), if (old) |e| e.attributes else null)) return .invalid;
    }
    var found = store.next(prev);
    if (isSealed()) {
        while (found) |k| : (found = store.next(k)) {
            const entry = store.get(k.name, k.guid) orelse continue;
            if (efi.visible(true, entry.attributes)) break;
        }
    }
    const key = found orelse return .not_found;
    const bytes = key.name.len * 2;
    if (name_size.* < bytes) {
        name_size.* = bytes;
        return .buffer_too_small;
    }
    @memcpy(name[0..key.name.len], key.name);
    guid.* = key.guid.*;
    name_size.* = bytes;
    return .success;
}

pub fn queryInfo(max_storage: *u64, remaining: *u64, max_var: *u64) void {
    if (backend == .none or !ready) {
        max_storage.* = 0;
        remaining.* = 0;
        max_var.* = 0;
        return;
    }
    const usage = store.usage();
    max_storage.* = usage.capacity;
    remaining.* = usage.capacity - usage.live;
    max_var.* = efi.maxVarSize(usage.capacity);
}

const SelfTestError = error{ Read, Write, ReadBack, VolatileSet, VolatileGet, VolatileRemove };

fn selfTest() void {
    const boots = runSelfTest() catch |err| {
        console.out.print("[var] self-test: failed at {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    console.out.print("[var] self-test: boot {d}, set and get ok\n", .{boots}) catch {};
}

fn runSelfTest() SelfTestError!u32 {
    const all = efi.non_volatile | efi.boot_service_access | efi.runtime_access;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("SelfTestBoots");
    var raw: [4]u8 = undefined;
    var size: usize = raw.len;
    const boots: u32 = switch (get(name, &weir_guid, null, &size, &raw)) {
        .not_found => 1,
        .success => if (size == raw.len)
            std.math.add(u32, std.mem.readInt(u32, &raw, .little), 1) catch return error.Read
        else
            return error.Read,
        else => return error.Read,
    };
    std.mem.writeInt(u32, &raw, boots, .little);
    if (set(name, &weir_guid, all, raw.len, &raw) != .success) return error.Write;
    var back: [4]u8 = undefined;
    size = back.len;
    if (get(name, &weir_guid, null, &size, &back) != .success) return error.ReadBack;
    if (size != back.len or !std.mem.eql(u8, &back, &raw)) return error.ReadBack;

    const temp = std.unicode.utf8ToUtf16LeStringLiteral("SelfTestVolatile");
    const value = "weir";
    const ram = efi.boot_service_access | efi.runtime_access;
    if (set(temp, &weir_guid, ram, value.len, value) != .success) return error.VolatileSet;
    size = back.len;
    if (get(temp, &weir_guid, null, &size, &back) != .success) return error.VolatileGet;
    if (!std.mem.eql(u8, &back, value)) return error.VolatileGet;
    if (set(temp, &weir_guid, 0, 0, null) != .success) return error.VolatileRemove;
    if (get(temp, &weir_guid, null, &size, &back) != .not_found) return error.VolatileRemove;
    return boots;
}
