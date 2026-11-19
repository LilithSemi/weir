//! Netboot through an ESP32 with the AT command firmware. Weir reads one disk
//! image from an HTTP server into RAM and gives it to the boot manager as a
//! block device. The WiFi name and password are in the module, not in Weir.

const std = @import("std");
const conduit = @import("conduit");
const soc = @import("soc");
const config = @import("../config.zig");
const console = @import("../console/console.zig");
const clint = @import("../arch/riscv/clint.zig");
const mem = @import("../mem.zig");
const block = @import("../block/block.zig");
const ramdisk = @import("../block/ramdisk.zig");
const esp_at = @import("esp_at.zig");
const fetch = @import("fetch.zig");
const http = @import("http.zig");

/// True when the device tree has the module and the build has a URL.
pub const enabled = soc.esp_at != null and config.netboot_url.len != 0;

pub const Region = struct { base: usize, len: usize };

const reset_baud = 115200;
const reset_low_ms = 350;
const ready_ms = 5000;
const network_ms = 30_000;
const piece = 64 * 1024;
const image_align = 2 << 20;
const mib = 1 << 20;

var disk: ramdisk.RamDisk = undefined; // zippy:ignore unsafe_undefined
var loaded: ?Region = null;

/// The memory of the image. The memory map must keep it until the OS starts.
pub fn region() ?Region {
    return loaded;
}

/// The 16550 UART of the module, by polls.
const Port = struct {
    overran: bool = false,

    const modem = soc.esp_at.?;
    const rbr = 0;
    const dll = 0;
    const dlm = 1;
    const fcr = 2;
    const lcr = 3;
    const mcr = 4;
    const lsr = 5;
    const lsr_ready = 0x01;
    const lsr_overrun = 0x02;
    const lsr_thr_empty = 0x20;
    const lsr_tx_empty = 0x40;

    inline fn get(index: usize) u8 {
        const addr = modem.uart_base + (index << modem.reg_shift);
        if (modem.io_width == 4) return @truncate(@as(*volatile u32, @ptrFromInt(addr)).*);
        return @as(*volatile u8, @ptrFromInt(addr)).*;
    }

    inline fn put(index: usize, value: u8) void {
        const addr = modem.uart_base + (index << modem.reg_shift);
        if (modem.io_width == 4) {
            @as(*volatile u32, @ptrFromInt(addr)).* = value;
        } else {
            @as(*volatile u8, @ptrFromInt(addr)).* = value;
        }
    }

    fn divisor(baud: u32) ?u16 {
        const step = 16 * @as(u64, baud);
        const div = (modem.uart_clock + step / 2) / step;
        if (div == 0 or div > 0xffff) return null;
        return @intCast(div);
    }

    pub fn setBaud(self: *Port, baud: u32) bool {
        const div = divisor(baud) orelse return false;
        while (get(lsr) & lsr_tx_empty == 0) {}
        put(lcr, 0x80);
        put(dll, @truncate(div));
        put(dlm, @truncate(div >> 8));
        put(lcr, 0x03);
        // The FIFOs are on and empty.
        put(fcr, 0x07);
        put(mcr, 0x03);
        self.overran = false;
        return true;
    }

    pub fn read(self: *Port, buf: []u8) usize {
        var count: usize = 0;
        while (count < buf.len) : (count += 1) {
            // A read of the status clears the overrun bit, so each read must
            // keep it.
            const status = get(lsr);
            if (status & lsr_overrun != 0) self.overran = true;
            if (status & lsr_ready == 0) break;
            buf[count] = get(rbr);
        }
        return count;
    }

    pub fn write(_: *Port, bytes: []const u8) void {
        for (bytes) |byte| {
            while (get(lsr) & lsr_thr_empty == 0) {}
            put(rbr, byte);
        }
    }

    pub fn takeOverrun(self: *Port) bool {
        defer self.overran = false;
        return self.overran;
    }

    pub fn now(_: *Port) u64 {
        return ms();
    }
};

const Client = esp_at.Client(*Port);

fn ms() u64 {
    const ticks_per_ms = comptime @max(1, soc.timebase_hz / 1000);
    return clint.time() / ticks_per_ms;
}

fn pause(time: u64) void {
    const end = ms() + time;
    while (ms() < end) {}
}

fn drive(pin: soc.Pin, active: bool) void {
    const gpio = conduit.driver.harbor_gpio.bind(conduit.Mmio.direct(pin.base));
    gpio.set(pin.pin, active != pin.active_low);
    gpio.direction(pin.pin, .output);
}

/// Reads the image and gives the block device of it. Null when a step fails.
/// The module is in reset again when this returns.
pub fn load() ?block.Device {
    const url = comptime http.Url.parse(config.netboot_url) orelse
        @compileError("the netboot URL must have the form http://host[:port]/path");
    const modem = soc.esp_at.?;
    defer drive(modem.enable, false);

    var port: Port = .{};
    var client: Client = .{ .port = &port };
    const start = ms();
    readImage(&port, &client, url) catch |err| {
        console.err.print("[net] netboot stopped: {s}\n", .{@errorName(err)}) catch {};
        return null;
    };
    const image = loaded.?;
    console.out.print("[net] image at {x}, {d} bytes in {d} s\n", .{ image.base, image.len, (ms() - start) / 1000 }) catch {};
    disk = .{ .bytes = @as([*]u8, @ptrFromInt(image.base))[0..image.len] };
    return disk.block();
}

fn readImage(port: *Port, client: *Client, comptime url: http.Url) !void {
    const modem = soc.esp_at.?;
    console.out.print("[net] netboot from {s}\n", .{config.netboot_url}) catch {};

    // The module answers commands only after a reset.
    if (modem.select) |select| drive(select, true);
    drive(modem.enable, false);
    if (!port.setBaud(reset_baud)) return error.BaudRate;
    pause(reset_low_ms);
    drive(modem.enable, true);
    try client.waitReady(ready_ms);
    try client.setup();
    if (config.netboot_baud != reset_baud) {
        try client.setBaud(config.netboot_baud);
        console.out.print("[net] modem at {d} baud\n", .{config.netboot_baud}) catch {};
    }

    // The module joins the network that it has in its flash. A connect fails
    // until it has an address.
    const deadline = ms() + network_ms;
    while (true) {
        if (client.connect(url.host, url.port, 15_000)) |_| break else |err| {
            if (ms() >= deadline) return err;
            client.close();
            pause(1000);
        }
    }
    var fetcher: fetch.Fetcher(Client) = .{ .conn = client, .url = url, .open = true };
    defer fetcher.drop();
    errdefer if (fetcher.status != 0)
        console.err.print("[net] the server gave status {d}, it must give 206 for a range\n", .{fetcher.status}) catch {};

    const size = try fetcher.size();
    const memory = place(size) orelse {
        console.err.print("[net] no memory for an image of {d} bytes\n", .{size}) catch {};
        return error.NoMemory;
    };
    console.out.print("[net] image of {d} bytes\n", .{size}) catch {};

    var offset: usize = 0;
    while (offset < memory.len) {
        const count = @min(piece, memory.len - offset);
        try fetcher.read(offset, memory[offset..][0..count]);
        if ((offset + count) / mib != offset / mib)
            console.out.print("[net] {d} of {d} MiB\n", .{ (offset + count) / mib, memory.len / mib }) catch {};
        offset += count;
    }
    if (fetcher.retries != 0)
        console.out.print("[net] {d} pieces came again\n", .{fetcher.retries}) catch {};
    loaded = .{ .base = @intFromPtr(memory.ptr), .len = memory.len };
}

/// The memory for an image of `size` bytes, at the top of RAM and above the
/// buffer that the boot manager reads files into.
fn place(size: u64) ?[]u8 {
    if (mem.small_layout or size == 0) return null;
    const floor = mem.kernel_read_base + mem.kernel_read_size;
    const end = mem.ram_end_default;
    if (floor >= end or size > end - floor) return null;
    const len: usize = @intCast(size);
    const base = std.mem.alignBackward(usize, end - len, image_align);
    if (base < floor) return null;
    return @as([*]u8, @ptrFromInt(base))[0..len];
}
