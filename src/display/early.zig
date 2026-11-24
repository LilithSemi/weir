//! Starts each display early in the boot, before storage and netboot, with a
//! framebuffer and the boot splash. UEFI later reserves the same framebuffers
//! and puts the graphics output protocol on them.

const std = @import("std");
const soc = @import("soc");
const console = @import("../console/console.zig");
const mem = @import("../mem.zig");
const page_alloc = @import("../uefi/page_alloc.zig");
const placer = @import("../uefi/framebuffer_place.zig");
const bmp = @import("bmp.zig");
const gop = @import("gop.zig");
const harbor = @import("harbor.zig");
const splash = @import("splash.zig");

pub const Framebuffer = struct {
    address: usize,
    /// Bytes, a whole number of pages.
    size: usize,
    surface: gop.Surface,
    /// The top left corner of the splash. Null when it was not drawn.
    splash: ?splash.Offset,
};

/// The splash image. The build fails when the file is not a BMP that Weir can draw.
pub const image: ?bmp.Image = if (soc.displays.len == 0) null else bmp.parse(@embedFile("boot_splash")) catch |err|
    @compileError("the boot splash is not an uncompressed 24 or 32 bit BMP: " ++ @errorName(err));

var framebuffers: [soc.displays.len]?Framebuffer = @splat(null);

// The framebuffers come from the top of RAM. The UEFI page pool does not exist
// yet, so a scratch allocator over the same memory chooses the addresses.
var scratch: page_alloc.PageAllocator = undefined; // zippy:ignore unsafe_undefined

/// Gives each display a framebuffer, draws the splash and starts the display.
/// RAM above the lowest framebuffer is then not free for the boot.
pub fn setup() void {
    scratch = .init(mem.load_limit, mem.ram_end_default);
    var top = mem.ram_end_default;
    for (soc.displays, &framebuffers) |display, *slot| {
        slot.* = null;
        const driver: harbor.Display(harbor.Mmio) = .{ .bus = .{ .base = display.base } };
        const mode = driver.mode() orelse {
            console.err.print("[display] no mode that Weir can draw at {x}\n", .{display.base}) catch {};
            continue;
        };
        const size = std.mem.alignForward(usize, mode.size(), page_alloc.page_size);
        const address = placer.place(&scratch, .{
            .size = size,
            .alignment = harbor.alignment(mode.stride),
            .fixed = range(display.fixed),
            .scanout = range(display.scanout),
        }, &top) orelse {
            console.err.print("[display] no memory for the framebuffer at {x}\n", .{display.base}) catch {};
            continue;
        };
        const surface: gop.Surface = .{ .pixels = @ptrFromInt(address), .mode = mode };
        surface.clear();
        const offset = if (image) |picture| splash.draw(surface, picture) else null;
        driver.start(@intCast(address));
        slot.* = .{ .address = address, .size = size, .surface = surface, .splash = offset };

        console.out.print(
            "[display] {d}x{d} {s}, framebuffer at {x}\n",
            .{ mode.width, mode.height, mode.format.name(), address },
        ) catch {};
        if (image) |picture| if (offset == null) console.err.print(
            "[display] the splash of {d}x{d} is larger than the screen\n",
            .{ picture.width, picture.height },
        ) catch {};
    }
    mem.usable_end = @min(mem.usable_end, top);
}

/// The framebuffer of display `index`, in the order of `soc.displays`.
pub fn framebuffer(index: usize) ?Framebuffer {
    return framebuffers[index];
}

/// Where the splash is on the first display that shows it, for the ACPI BGRT.
pub fn shownSplash() ?splash.Offset {
    for (framebuffers) |slot| {
        if (slot) |fb| if (fb.splash) |offset| return offset;
    }
    return null;
}

/// The bytes of the BMP file of the splash.
pub fn splashFile() []const u8 {
    return if (soc.displays.len == 0) &.{} else @embedFile("boot_splash");
}

fn range(memory: ?soc.Framebuffer) ?placer.Range {
    const m = memory orelse return null;
    return .{ .base = m.base, .size = m.size };
}
