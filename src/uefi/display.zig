//! The graphics output protocol on the framebuffer of each display. The early
//! display setup chose the framebuffers. Here they are reserved in the memory
//! map, so the OS can keep the picture.

const std = @import("std");
const uefi = std.os.uefi;
const soc = @import("soc");
const console = @import("../console/console.zig");
const gop = @import("../display/gop.zig");
const early = @import("../display/early.zig");
const handledb = @import("handledb.zig");
const page_alloc = @import("page_alloc.zig");

const Status = uefi.Status;
const Gop = uefi.protocol.GraphicsOutput;

const State = struct {
    protocol: Gop,
    mode: Gop.Mode = undefined, // zippy:ignore unsafe_undefined
    info: Gop.Mode.Info = undefined, // zippy:ignore unsafe_undefined
    /// Null while the display has no framebuffer.
    surface: ?gop.Surface = null,
    installed: bool = false,
};

var states: [soc.displays.len]State = @splat(.{
    .protocol = .{
        ._query_mode = &queryMode,
        ._set_mode = &setMode,
        ._blt = &blt,
        .mode = undefined, // zippy:ignore unsafe_undefined
    },
});

var pool: ?*page_alloc.Pool = null;

/// Reserves the framebuffer of each display and installs the protocol. Call
/// when the page pool is new, before the first allocation of a loader.
pub fn setup(pages: *page_alloc.PageAllocator, memory_pool: *page_alloc.Pool) void {
    pool = memory_pool;
    for (&states, 0..) |*state, index| {
        state.surface = null;
        const fb = early.framebuffer(index) orelse continue;
        // A framebuffer outside the pool has no other user.
        const in_pool = fb.address + fb.size > pages.base and fb.address < pages.end;
        if (in_pool and !pages.allocAt(fb.address, fb.size, tag)) {
            console.err.print("[display] the framebuffer at {x} is in use\n", .{fb.address}) catch {};
            continue;
        }
        const surface = fb.surface;
        const mode = surface.mode;
        const address = fb.address;
        state.surface = surface;
        state.info = mode.info();
        state.mode = .{
            .max_mode = 1,
            .mode = 0,
            .info = &state.info,
            .size_of_info = @sizeOf(Gop.Mode.Info),
            .frame_buffer_base = address,
            .frame_buffer_size = mode.size(),
        };
        state.protocol.mode = &state.mode;
        if (!state.installed) {
            state.installed = handledb.install(null, &Gop.guid, @ptrCast(&state.protocol)) != null;
        }
    }
}

const tag: page_alloc.Tag = .{ .kind = .reserved, .owner = .firmware };

fn stateOf(protocol: *const Gop) ?*State {
    for (&states) |*state| {
        if (&state.protocol == protocol) return state;
    }
    return null;
}

fn queryMode(self: *const Gop, number: u32, size: *usize, info: **Gop.Mode.Info) callconv(uefi.cc) Status {
    const state = stateOf(self) orelse return .invalid_parameter;
    if (number != 0 or state.surface == null) return .invalid_parameter;
    // The caller frees the information with FreePool.
    const memory = (pool orelse return .device_error).alloc(@sizeOf(Gop.Mode.Info), .boot_services_data) orelse
        return .out_of_resources;
    const copy: *Gop.Mode.Info = @ptrFromInt(memory);
    copy.* = state.info;
    size.* = @sizeOf(Gop.Mode.Info);
    info.* = copy;
    return .success;
}

fn setMode(self: *Gop, number: u32) callconv(uefi.cc) Status {
    const state = stateOf(self) orelse return .device_error;
    const surface = state.surface orelse return .device_error;
    if (number != 0) return .unsupported;
    surface.clear();
    return .success;
}

fn blt(
    self: *Gop,
    buffer: ?[*]Gop.BltPixel,
    operation: Gop.BltOperation,
    source_x: usize,
    source_y: usize,
    dest_x: usize,
    dest_y: usize,
    width: usize,
    height: usize,
    delta: usize,
) callconv(uefi.cc) Status {
    const state = stateOf(self) orelse return .device_error;
    const surface = state.surface orelse return .device_error;
    surface.blt(buffer, operation, source_x, source_y, dest_x, dest_y, width, height, delta) catch
        return .invalid_parameter;
    return .success;
}
