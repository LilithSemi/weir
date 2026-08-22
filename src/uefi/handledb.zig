//! UEFI handle / protocol database.
//!
//! A UEFI handle is an opaque token carrying GUID-keyed protocol interfaces, the
//! core of the driver model: Weir installs Block IO + Device Path on disk
//! handles, consumers find interfaces via HandleProtocol / LocateProtocol /
//! LocateHandle.

const std = @import("std");
const uefi = std.os.uefi;

const MAX_HANDLES = 32;
const MAX_PROTOCOLS = 8;

const ProtocolEntry = struct {
    guid: [16]u8,
    interface: *anyopaque,
};

pub const Handle = struct {
    used: bool = false,
    // Only protocols[0..count] ever gets read, so the tail can start undefined.
    protocols: [MAX_PROTOCOLS]ProtocolEntry = undefined, // zippy:ignore unsafe_undefined
    count: usize = 0,
};

var handles: [MAX_HANDLES]Handle = undefined;
var inited = false;

fn ensureInit() void {
    if (inited) return;
    for (&handles) |*h| h.used = false;
    inited = true;
}

/// Allocate a fresh handle.
pub fn create() ?*Handle {
    ensureInit();
    for (&handles) |*h| {
        if (!h.used) {
            h.used = true;
            h.count = 0;
            return h;
        }
    }
    return null;
}

fn guidBytes(g: *const uefi.Guid) *const [16]u8 {
    return @ptrCast(g);
}

/// Install `interface` for `guid` on `handle` (creating a handle if null).
/// Returns the handle the interface landed on, or null if full.
pub fn install(handle: ?*Handle, guid: *const uefi.Guid, interface: *anyopaque) ?*Handle {
    const h = handle orelse (create() orelse return null);
    if (h.count >= MAX_PROTOCOLS) return null;
    h.protocols[h.count] = .{ .guid = guidBytes(guid).*, .interface = interface };
    h.count += 1;
    return h;
}

/// Is `h` one of our handles? Validates before dereferencing, since a caller may
/// pass a stale or bogus EFI_HANDLE.
pub fn isValid(h: ?*Handle) bool {
    const p = @intFromPtr(h orelse return false);
    const base = @intFromPtr(&handles[0]);
    const span = @sizeOf(Handle) * MAX_HANDLES;
    if (p < base or p >= base + span) return false;
    if ((p - base) % @sizeOf(Handle) != 0) return false;
    return h.?.used;
}

/// Look up a protocol interface on a specific handle.
pub fn handleProtocol(handle: *Handle, guid: *const uefi.Guid) ?*anyopaque {
    if (!isValid(handle)) return null;
    const want = guidBytes(guid);
    for (handle.protocols[0..handle.count]) |p| {
        if (std.mem.eql(u8, &p.guid, want)) return p.interface;
    }
    return null;
}

/// Find the first handle carrying `guid` and return its interface.
pub fn locateProtocol(guid: *const uefi.Guid) ?*anyopaque {
    ensureInit();
    const want = guidBytes(guid);
    for (&handles) |*h| {
        if (!h.used) continue;
        for (h.protocols[0..h.count]) |p| {
            if (std.mem.eql(u8, &p.guid, want)) return p.interface;
        }
    }
    return null;
}

/// Fill `buf` with the handles carrying `guid`. Returns the count (which may
/// exceed buf.len, in which case buf is filled up to its length).
pub fn locateHandles(guid: *const uefi.Guid, buf: []*Handle) usize {
    ensureInit();
    const want = guidBytes(guid);
    var n: usize = 0;
    for (&handles) |*h| {
        if (!h.used) continue;
        for (h.protocols[0..h.count]) |p| {
            if (std.mem.eql(u8, &p.guid, want)) {
                if (n < buf.len) buf[n] = h;
                n += 1;
                break;
            }
        }
    }
    return n;
}
