//! A framebuffer for each display of the device tree, and the graphics output
//! protocol on it. A display with no fixed framebuffer gets one from the page
//! pool, reserved in the memory map, so the OS can keep the picture.

const std = @import("std");
const uefi = std.os.uefi;
const soc = @import("soc");
const console = @import("../console/console.zig");
const gop = @import("../display/gop.zig");
const harbor = @import("../display/harbor.zig");
const handledb = @import("handledb.zig");
const page_alloc = @import("page_alloc.zig");
const placer = @import("framebuffer_place.zig");

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

/// Gives each display a framebuffer and starts it. Call when the page pool
/// is new, before the first allocation of a loader. The framebuffers from
/// the pool go below `pool_top`.
pub fn setup(pages: *page_alloc.PageAllocator, memory_pool: *page_alloc.Pool, pool_top: usize) void {
    pool = memory_pool;
    // The framebuffers go to the top of the pool, one below the other, so
    // the low memory stays in one piece for the OS image.
    var top = pool_top;
    for (soc.displays, &states) |display, *state| {
        state.surface = null;
        const driver: harbor.Display(harbor.Mmio) = .{ .bus = .{ .base = display.base } };
        const mode = driver.mode() orelse {
            console.err.print("[display] no mode that Weir can draw at {x}\n", .{display.base}) catch {};
            continue;
        };
        const address = placer.place(pages, .{
            .size = std.mem.alignForward(usize, mode.size(), page_alloc.page_size),
            .alignment = harbor.alignment(mode.stride),
            .fixed = range(display.fixed),
            .scanout = range(display.scanout),
        }, &top) orelse {
            console.err.print("[display] no memory for the framebuffer at {x}\n", .{display.base}) catch {};
            continue;
        };
        const surface: gop.Surface = .{ .pixels = @ptrFromInt(address), .mode = mode };
        surface.clear();
        driver.start(@intCast(address));

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
        console.out.print(
            "[display] {d}x{d} {s}, framebuffer at {x}\n",
            .{ mode.width, mode.height, mode.format.name(), address },
        ) catch {};
    }
}

fn range(memory: ?soc.Framebuffer) ?placer.Range {
    const m = memory orelse return null;
    return .{ .base = m.base, .size = m.size };
}

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
