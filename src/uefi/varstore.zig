//! Non-volatile EFI variable store, backed by CFI NOR flash.
//!
//! Lets Weir act like a real EFI BIOS: GetVariable/SetVariable persist across
//! reboots. Variables live in a RAM cache loaded from flash at boot. SetVariable
//! updates the cache and rewrites the flash block. TODO: append-log instead of
//! full-rewrite.
//!
//! Flash layout in block 0: a u32 magic, a run of valid records, then erased
//! (0xFF) space. A record is
//!   state u32 | attributes u32 | guid[16] | name_bytes u32 | data_bytes u32 |
//!   name (UTF-16) | data, padded to 4 bytes.

const std = @import("std");
const cfi = @import("../flash/cfi.zig");
const console = @import("../console/console.zig");

const MAGIC: u32 = 0x31535657; // "WVS1"
const STATE_VALID: u32 = 0x00000001;
const STATE_ERASED: u32 = 0xffffffff;

pub const MAX_VARS = 64;
pub const NAME_UNITS = 128; // u16 units incl null terminator
pub const DATA_BYTES = 1024;
const STORE_LIMIT = 64 * 1024; // bytes of flash we use for the store

pub const Var = struct {
    used: bool = false,
    attributes: u32 = 0,
    guid: [16]u8 = undefined,
    name: [NAME_UNITS]u16 = undefined, // null-terminated UTF-16
    name_units: usize = 0, // includes the null terminator
    data: [DATA_BYTES]u8 = undefined,
    data_len: usize = 0,
};

var vars: [MAX_VARS]Var = undefined;
var image: [STORE_LIMIT]u8 align(4) = undefined;
var loaded = false;

fn u16len(name: [*:0]const u16) usize {
    var n: usize = 0;
    while (name[n] != 0) n += 1;
    return n + 1; // include terminator
}

fn nameEql(a: []const u16, an: usize, b: [*:0]const u16) bool {
    var i: usize = 0;
    while (i < an) : (i += 1) {
        if (a[i] != b[i]) return false;
        if (a[i] == 0) return true;
    }
    return false;
}

fn find(name: [*:0]const u16, guid: *const [16]u8) ?*Var {
    for (&vars) |*v| {
        if (!v.used) continue;
        if (!std.mem.eql(u8, &v.guid, guid)) continue;
        if (nameEql(v.name[0..v.name_units], v.name_units, name)) return v;
    }
    return null;
}

fn freeSlot() ?*Var {
    for (&vars) |*v| if (!v.used) return v;
    return null;
}

/// Load the store from flash into the RAM cache.
pub fn init() void {
    for (&vars) |*v| v.used = false;
    if (!cfi.init()) {
        console.writeStr("[var] no flash; variables are unavailable\n");
        loaded = false;
        return;
    }
    loaded = true;

    var hdr: [4]u8 = undefined;
    cfi.read(0, &hdr);
    if (std.mem.readInt(u32, &hdr, .little) != MAGIC) {
        console.writeStr("[var] flash store empty, starting fresh\n");
        return;
    }

    var pos: usize = 4;
    var count: usize = 0;
    while (pos + 32 <= STORE_LIMIT) {
        var rec: [32]u8 = undefined;
        cfi.read(pos, &rec);
        const state = std.mem.readInt(u32, rec[0..4], .little);
        if (state != STATE_VALID) break; // erased -> end of log
        const attributes = std.mem.readInt(u32, rec[4..8], .little);
        const name_bytes = std.mem.readInt(u32, rec[24..28], .little);
        const data_bytes = std.mem.readInt(u32, rec[28..32], .little);
        const nu = name_bytes / 2;
        if (nu > NAME_UNITS or data_bytes > DATA_BYTES) break; // corrupt
        if (freeSlot()) |v| {
            v.used = true;
            v.attributes = attributes;
            @memcpy(&v.guid, rec[8..24]);
            v.name_units = nu;
            cfi.read(pos + 32, std.mem.sliceAsBytes(v.name[0..nu]));
            v.data_len = data_bytes;
            cfi.read(pos + 32 + name_bytes, v.data[0..data_bytes]);
            count += 1;
        }
        pos += 32 + name_bytes + data_bytes;
        pos = (pos + 3) & ~@as(usize, 3);
    }
    console.printf("[var] loaded {d} variable(s) from flash\n", .{count});
}

/// Rewrite the flash store from the RAM cache. Returns false on flash error.
fn save() bool {
    if (!loaded) return false;
    @memset(&image, 0xff);
    std.mem.writeInt(u32, image[0..4], MAGIC, .little);
    var pos: usize = 4;
    for (&vars) |*v| {
        if (!v.used) continue;
        const name_bytes = v.name_units * 2;
        const total = 32 + name_bytes + v.data_len;
        if (pos + total + 4 > STORE_LIMIT) return false;
        std.mem.writeInt(u32, image[pos..][0..4], STATE_VALID, .little);
        std.mem.writeInt(u32, image[pos + 4 ..][0..4], v.attributes, .little);
        @memcpy(image[pos + 8 ..][0..16], &v.guid);
        std.mem.writeInt(u32, image[pos + 24 ..][0..4], @intCast(name_bytes), .little);
        std.mem.writeInt(u32, image[pos + 28 ..][0..4], @intCast(v.data_len), .little);
        @memcpy(image[pos + 32 ..][0..name_bytes], std.mem.sliceAsBytes(v.name[0..v.name_units]));
        @memcpy(image[pos + 32 + name_bytes ..][0..v.data_len], v.data[0..v.data_len]);
        pos += total;
        pos = (pos + 3) & ~@as(usize, 3);
    }

    var b: usize = 0;
    while (b < pos) : (b += cfi.blockSize()) {
        if (!cfi.eraseBlock(b)) return false;
    }
    return cfi.program(0, image[0..pos]);
}

pub fn available() bool {
    return loaded;
}

// --- Operations used by the EFI variable runtime services -------------------

pub const Result = enum { success, not_found, buffer_too_small, invalid, out_of_resources, device_error };

/// Copy a variable's data out. On buffer_too_small, sets `data_size` to the
/// required size.
pub fn get(name: [*:0]const u16, guid: *const [16]u8, attributes: ?*u32, data_size: *usize, data: ?[*]u8) Result {
    const v = find(name, guid) orelse return .not_found;
    if (attributes) |a| a.* = v.attributes;
    if (data_size.* < v.data_len or data == null) {
        data_size.* = v.data_len;
        return .buffer_too_small;
    }
    @memcpy(data.?[0..v.data_len], v.data[0..v.data_len]);
    data_size.* = v.data_len;
    return .success;
}

/// Set, replace, or (data_size==0) delete a variable, persisting to flash.
pub fn set(name: [*:0]const u16, guid: *const [16]u8, attributes: u32, data_size: usize, data: ?[*]const u8) Result {
    const nu = u16len(name);
    if (nu > NAME_UNITS or data_size > DATA_BYTES) return .out_of_resources;

    const existing = find(name, guid);
    if (data_size == 0) {
        // Delete.
        if (existing) |v| {
            v.used = false;
            return if (save()) .success else .device_error;
        }
        return .not_found;
    }

    const v = existing orelse (freeSlot() orelse return .out_of_resources);
    v.used = true;
    v.attributes = attributes;
    @memcpy(&v.guid, guid);
    v.name_units = nu;
    @memcpy(v.name[0..nu], name[0..nu]);
    v.data_len = data_size;
    if (data) |d| @memcpy(v.data[0..data_size], d[0..data_size]);
    return if (save()) .success else .device_error;
}

/// Enumerate variables. `name` is in/out: empty (name[0]==0) starts iteration,
/// otherwise it names the previous variable and we return the next.
pub fn next(name_size: *usize, name: [*:0]u16, guid: *[16]u8) Result {
    var return_next = (name[0] == 0);
    for (&vars) |*v| {
        if (!v.used) continue;
        if (return_next) {
            const bytes = v.name_units * 2;
            if (name_size.* < bytes) {
                name_size.* = bytes;
                return .buffer_too_small;
            }
            @memcpy(name[0..v.name_units], v.name[0..v.name_units]);
            @memcpy(guid, &v.guid);
            name_size.* = bytes;
            return .success;
        }
        if (std.mem.eql(u8, &v.guid, guid) and nameEql(v.name[0..v.name_units], v.name_units, name)) {
            return_next = true;
        }
    }
    return .not_found;
}

pub fn queryInfo(max_storage: *u64, remaining: *u64, max_var: *u64) void {
    var used: u64 = 0;
    for (&vars) |*v| {
        if (v.used) used += 32 + v.name_units * 2 + v.data_len;
    }
    max_storage.* = STORE_LIMIT;
    remaining.* = if (used < STORE_LIMIT) STORE_LIMIT - used else 0;
    max_var.* = DATA_BYTES;
}
