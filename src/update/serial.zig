//! Serial update mode. A host sends framed requests over the UART, and Weir
//! writes or checks blocks on the boot storage. The engine is generic over the
//! transport, so host tests drive it with a fake. See docs/serial-update.md.
//!
//! A transport has these methods:
//! `readByte(ms: u32) ?u8`, `write(bytes: []const u8) void`, `drain() void`,
//! `now() u64` in milliseconds, `baudValid(baud: u32) bool` and
//! `setBaud(baud: u32) bool`.

const std = @import("std");
const conduit = @import("conduit");

pub const max_payload = 4112;
pub const block_size = 512;
pub const max_write_blocks = 8;
pub const max_crc_blocks = 2048;
pub const default_baud = 115200;
pub const gap_ms = 500;
pub const confirm_ms = 2000;
pub const version = 1;

const header_len = 6;
const crc_len = 4;
const write_args_len = 10;
const crc_args_len = 13;
const info_head_len = 3;
const info_entry_len = 14;
const request_magic = [2]u8{ 'W', 'U' };
const reply_magic = [2]u8{ 'w', 'u' };

pub const Command = enum(u8) { ping = 0, info = 1, write = 2, crc = 3, baud = 4, boot = 5, rescan = 6, probe = 7, write_trace = 8, read_trace = 9, sd_command = 10, sd_register = 11, _ };

pub const max_trace_blocks = 8;

/// Board services for the rescan, probe and trace commands. A command with no
/// service gets the unknown command status.
pub fn Hooks(comptime Entry: type) type {
    return struct {
        /// Finds the block devices again and gives the new list.
        rescan: ?*const fn () []const Entry = null,
        /// Traces the bring-up of SD host `index` into `out`. It gives the
        /// number of bytes, or null when the host does not exist.
        probe: ?*const fn (index: u8, out: []u8) ?usize = null,
        /// Writes one block to the card on SD host `index` and traces each
        /// step into `out`, which can overlap `data`. It gives the number of
        /// bytes, or null when the host has no card or `lba` is out of range.
        write_trace: ?*const fn (index: u8, lba: u64, data: *const [block_size]u8, out: []u8) ?usize = null,
        /// Reads `count` blocks, max_trace_blocks at most, from the card on
        /// SD host `index` and traces each step into `out`. It gives the
        /// number of bytes, or null when the host has no card or `lba` is out
        /// of range.
        read_trace: ?*const fn (index: u8, lba: u64, count: u8, out: []u8) ?usize = null,
        /// Sends one SD command with no data on SD host `index` and writes
        /// its record to `out`. It gives the number of bytes, or null when
        /// the host does not exist.
        sd_command: ?*const fn (index: u8, opcode: u8, resp: u8, arg: u32, out: []u8) ?usize = null,
        /// Reads a register of SD host `index`, after a write of `value` when
        /// `write` is set. It gives null for a host or an offset that does
        /// not exist.
        sd_register: ?*const fn (index: u8, offset: u8, write: bool, value: u32) ?u32 = null,
    };
}

pub const Status = enum(u8) {
    ok = 0,
    bad_crc = 1,
    unknown_command = 2,
    bad_argument = 3,
    io_error = 4,
    read_only = 5,
};

// Requests, replies and crc reads share this buffer. The write data and the crc
// reads start at the same offset, 16 bytes into the frame.
// zippy:ignore unsafe_undefined
var frame: [header_len + max_payload + crc_len]u8 align(16) = undefined;
const data_offset = header_len + write_args_len;

comptime {
    std.debug.assert(data_offset + max_write_blocks * block_size <= frame.len);
    std.debug.assert(data_offset % 16 == 0);
}

const Request = struct { code: u8, seq: u8, payload: []const u8 };
const Received = union(enum) { request: Request, bad_crc: u8, timeout };

/// Runs the engine for `transport` over `Entry` devices. An entry has a `kind`
/// enum with the tags virtio, sdhci and sd_spi, and a `dev` of type
/// conduit.device.Block.
pub fn Engine(comptime Transport: type, comptime Entry: type) type {
    return struct {
        const Self = @This();

        transport: *Transport,
        devices: []const Entry,
        hooks: Hooks(Entry) = .{},
        rate: u32 = default_baud,

        /// Handles requests until the boot command, then returns. The UART is
        /// at default_baud again on return.
        pub fn run(self: *Self) void {
            while (true) {
                switch (self.receive(null)) {
                    .timeout => {},
                    .bad_crc => |seq| self.reply(.bad_crc, seq, 0),
                    .request => |req| {
                        if (self.handle(req)) return;
                    },
                }
            }
        }

        fn handle(self: *Self, req: Request) bool {
            switch (@as(Command, @fromBackingInt(@intCast(req.code)))) {
                .ping => self.reply(emptyStatus(req), req.seq, 0),
                .info => self.info(req),
                .write => self.reply(self.write(req.payload), req.seq, 0),
                .crc => self.crc(req),
                .baud => self.baud(req),
                .boot => {
                    const status = emptyStatus(req);
                    self.reply(status, req.seq, 0);
                    self.transport.drain();
                    if (status != .ok) return false;
                    if (self.rate != default_baud) _ = self.transport.setBaud(default_baud);
                    return true;
                },
                .rescan => self.rescan(req),
                .probe => self.probe(req),
                .write_trace => self.writeTrace(req),
                .read_trace => self.readTrace(req),
                .sd_command => self.sdCommand(req),
                .sd_register => self.sdRegister(req),
                _ => self.reply(.unknown_command, req.seq, 0),
            }
            return false;
        }

        fn rescan(self: *Self, req: Request) void {
            const service = self.hooks.rescan orelse return self.reply(.unknown_command, req.seq, 0);
            if (req.payload.len != 0) return self.reply(.bad_argument, req.seq, 0);
            self.devices = service();
            frame[header_len] = @intCast(@min(self.devices.len, 255));
            self.reply(.ok, req.seq, 1);
        }

        fn sdCommand(self: *Self, req: Request) void {
            const service = self.hooks.sd_command orelse return self.reply(.unknown_command, req.seq, 0);
            const args = req.payload;
            if (args.len != 7 or args[2] > 4) return self.reply(.bad_argument, req.seq, 0);
            const index = args[0];
            const opcode = args[1];
            const resp = args[2];
            const arg = std.mem.readInt(u32, args[3..7], .little);
            const len = service(index, opcode, resp, arg, frame[header_len..][0..max_payload]) orelse
                return self.reply(.bad_argument, req.seq, 0);
            self.reply(.ok, req.seq, @intCast(len));
        }

        fn sdRegister(self: *Self, req: Request) void {
            const service = self.hooks.sd_register orelse return self.reply(.unknown_command, req.seq, 0);
            const args = req.payload;
            if (args.len != 7 or args[2] > 1) return self.reply(.bad_argument, req.seq, 0);
            const value = std.mem.readInt(u32, args[3..7], .little);
            const result = service(args[0], args[1], args[2] == 1, value) orelse
                return self.reply(.bad_argument, req.seq, 0);
            std.mem.writeInt(u32, frame[header_len..][0..4], result, .little);
            self.reply(.ok, req.seq, 4);
        }

        fn probe(self: *Self, req: Request) void {
            const service = self.hooks.probe orelse return self.reply(.unknown_command, req.seq, 0);
            if (req.payload.len != 1) return self.reply(.bad_argument, req.seq, 0);
            // The reply payload goes where the request payload is.
            const index = req.payload[0];
            const len = service(index, frame[header_len..][0..max_payload]) orelse
                return self.reply(.bad_argument, req.seq, 0);
            self.reply(.ok, req.seq, @intCast(len));
        }

        // The request has the layout of a write of one block.
        fn writeTrace(self: *Self, req: Request) void {
            const service = self.hooks.write_trace orelse return self.reply(.unknown_command, req.seq, 0);
            const args = req.payload;
            if (args.len != write_args_len + block_size or args[9] != 1) return self.reply(.bad_argument, req.seq, 0);
            const index = args[0];
            const lba = std.mem.readInt(u64, args[1..9], .little);
            const data = args[write_args_len..][0..block_size];
            const len = service(index, lba, data, frame[header_len..][0..max_payload]) orelse
                return self.reply(.bad_argument, req.seq, 0);
            self.reply(.ok, req.seq, @intCast(len));
        }

        // The request has the arguments of a write and no data.
        fn readTrace(self: *Self, req: Request) void {
            const service = self.hooks.read_trace orelse return self.reply(.unknown_command, req.seq, 0);
            const args = req.payload;
            if (args.len != write_args_len or args[9] > max_trace_blocks) return self.reply(.bad_argument, req.seq, 0);
            const index = args[0];
            const lba = std.mem.readInt(u64, args[1..9], .little);
            const count = args[9];
            const len = service(index, lba, count, frame[header_len..][0..max_payload]) orelse
                return self.reply(.bad_argument, req.seq, 0);
            self.reply(.ok, req.seq, @intCast(len));
        }

        fn info(self: *Self, req: Request) void {
            if (req.payload.len != 0) return self.reply(.bad_argument, req.seq, 0);
            const room = (max_payload - info_head_len) / info_entry_len;
            const count = @min(self.devices.len, room, 255);
            const out = frame[header_len..];
            out[0] = version;
            out[1] = max_write_blocks;
            out[2] = @intCast(count);
            for (self.devices[0..count], 0..) |entry, i| {
                const at = out[info_head_len + i * info_entry_len ..][0..info_entry_len];
                at[0] = kindCode(entry.kind);
                at[1] = @intFromBool(entry.dev.writable());
                std.mem.writeInt(u32, at[2..6], entry.dev.block_size, .little);
                std.mem.writeInt(u64, at[6..14], entry.dev.num_blocks, .little);
            }
            self.reply(.ok, req.seq, @intCast(info_head_len + count * info_entry_len));
        }

        fn write(self: *Self, args: []const u8) Status {
            if (args.len < write_args_len) return .bad_argument;
            const count = args[9];
            if (count < 1 or count > max_write_blocks) return .bad_argument;
            if (args.len != write_args_len + @as(usize, count) * block_size) return .bad_argument;
            const dev = self.device(args[0]) orelse return .bad_argument;
            const lba = std.mem.readInt(u64, args[1..9], .little);
            if (!inRange(dev, lba, count)) return .bad_argument;
            if (!dev.writable()) return .read_only;
            if (!dev.writeBlocks(lba, count, args[write_args_len..])) return .io_error;
            return .ok;
        }

        fn crc(self: *Self, req: Request) void {
            const status, const sum = self.crcBlocks(req.payload);
            if (status != .ok) return self.reply(status, req.seq, 0);
            std.mem.writeInt(u32, frame[header_len..][0..4], sum, .little);
            self.reply(.ok, req.seq, 4);
        }

        fn crcBlocks(self: *Self, args: []const u8) struct { Status, u32 } {
            if (args.len != crc_args_len) return .{ .bad_argument, 0 };
            const dev = self.device(args[0]) orelse return .{ .bad_argument, 0 };
            const lba = std.mem.readInt(u64, args[1..9], .little);
            const count = std.mem.readInt(u32, args[9..13], .little);
            if (count < 1 or count > max_crc_blocks) return .{ .bad_argument, 0 };
            if (!inRange(dev, lba, count)) return .{ .bad_argument, 0 };
            var hash = std.hash.Crc32.init();
            var done: u32 = 0;
            while (done < count) {
                const n: u32 = @min(max_write_blocks, count - done);
                const buf = frame[data_offset..][0 .. n * block_size];
                if (!dev.readBlocks(lba + done, n, buf)) return .{ .io_error, 0 };
                hash.update(buf);
                done += n;
            }
            return .{ .ok, hash.final() };
        }

        // The reply goes out at the old rate. Then the host has confirm_ms to
        // ping at the new rate, else the rate goes back to default_baud.
        fn baud(self: *Self, req: Request) void {
            if (req.payload.len != 4) return self.reply(.bad_argument, req.seq, 0);
            const rate = std.mem.readInt(u32, req.payload[0..4], .little);
            if (!self.transport.baudValid(rate)) return self.reply(.bad_argument, req.seq, 0);
            self.reply(.ok, req.seq, 0);
            self.transport.drain();
            if (!self.transport.setBaud(rate)) return;
            self.rate = rate;
            const deadline = self.transport.now() + confirm_ms;
            while (true) {
                switch (self.receive(deadline)) {
                    .timeout => {
                        _ = self.transport.setBaud(default_baud);
                        self.rate = default_baud;
                        return;
                    },
                    .bad_crc => {},
                    .request => |ping| if (ping.code == @backingInt(Command.ping) and ping.payload.len == 0) {
                        self.reply(.ok, ping.seq, 0);
                        return;
                    },
                }
            }
        }

        fn device(self: *Self, index: u8) ?*const conduit.device.Block {
            if (index >= self.devices.len) return null;
            const dev = &self.devices[index].dev;
            if (dev.block_size != block_size) return null;
            return dev;
        }

        // Waits for the magic, then reads one frame. A dropped frame starts the
        // search again. With a deadline, no frame in time gives `.timeout`.
        fn receive(self: *Self, deadline: ?u64) Received {
            search: while (true) {
                var matched: usize = 0;
                while (matched < request_magic.len) {
                    const b = if (matched == 0)
                        self.waitByte(deadline) orelse return .timeout
                    else
                        self.transport.readByte(gap_ms) orelse {
                            matched = 0;
                            continue;
                        };
                    if (b == request_magic[matched]) {
                        matched += 1;
                    } else {
                        matched = @intFromBool(b == request_magic[0]);
                    }
                }
                for (frame[request_magic.len..header_len]) |*slot| {
                    slot.* = self.transport.readByte(gap_ms) orelse continue :search;
                }
                const len = std.mem.readInt(u16, frame[4..6], .little);
                if (len > max_payload) continue :search;
                for (frame[header_len..][0 .. len + crc_len]) |*slot| {
                    slot.* = self.transport.readByte(gap_ms) orelse continue :search;
                }
                const sent = std.mem.readInt(u32, frame[header_len + len ..][0..crc_len], .little);
                if (sent != std.hash.Crc32.hash(frame[2 .. header_len + len])) return .{ .bad_crc = frame[3] };
                return .{ .request = .{ .code = frame[2], .seq = frame[3], .payload = frame[header_len..][0..len] } };
            }
        }

        fn waitByte(self: *Self, deadline: ?u64) ?u8 {
            while (true) {
                var wait: u32 = gap_ms;
                if (deadline) |end| {
                    const now = self.transport.now();
                    if (now >= end) return null;
                    wait = @intCast(@min(end - now, gap_ms));
                }
                if (self.transport.readByte(wait)) |b| return b;
            }
        }

        // The reply payload is already in the frame at header_len.
        fn reply(self: *Self, status: Status, seq: u8, len: u16) void {
            frame[0..2].* = reply_magic;
            frame[2] = @backingInt(status);
            frame[3] = seq;
            std.mem.writeInt(u16, frame[4..6], len, .little);
            const sum = std.hash.Crc32.hash(frame[2 .. header_len + len]);
            std.mem.writeInt(u32, frame[header_len + len ..][0..crc_len], sum, .little);
            self.transport.write(frame[0 .. header_len + len + crc_len]);
        }
    };
}

fn emptyStatus(req: Request) Status {
    return if (req.payload.len == 0) .ok else .bad_argument;
}

fn kindCode(kind: anytype) u8 {
    return switch (kind) {
        .virtio => 0,
        .sdhci => 1,
        .sd_spi => 2,
    };
}

fn inRange(dev: *const conduit.device.Block, lba: u64, count: u64) bool {
    return lba <= dev.num_blocks and count <= dev.num_blocks - lba;
}

const testing = std.testing;

const FakeLink = struct {
    const clock_hz = 24_000_000;

    pub const Byte = struct {
        value: u8,
        /// Milliseconds between the previous byte and this one.
        delay: u32 = 0,
        /// The rate the host sends at. A byte at another rate arrives garbled.
        baud: u32 = default_baud,
    };

    input: []const Byte,
    pos: usize = 0,
    waited: u32 = 0,
    clock: u64 = 0,
    idle_reads: u32 = 0,
    baud: u32 = default_baud,
    out: [8192]u8 = undefined,
    out_len: usize = 0,
    drained: bool = true,
    /// Set when the engine changes the rate before the transmitter is empty.
    early_switch: bool = false,
    baud_calls: [4]u32 = @splat(0),
    baud_count: usize = 0,

    pub fn readByte(self: *FakeLink, ms: u32) ?u8 {
        if (self.pos == self.input.len) {
            self.idle_reads += 1;
            if (self.idle_reads > 1000) @panic("the engine waits for input after the script ended");
            self.clock += ms;
            return null;
        }
        const next = self.input[self.pos];
        const left = next.delay - self.waited;
        if (left > ms) {
            self.waited += ms;
            self.clock += ms;
            return null;
        }
        self.clock += left;
        self.waited = 0;
        self.pos += 1;
        return if (next.baud == self.baud) next.value else next.value ^ 0xa5;
    }

    pub fn write(self: *FakeLink, bytes: []const u8) void {
        @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
        self.out_len += bytes.len;
        self.drained = false;
    }

    pub fn drain(self: *FakeLink) void {
        self.drained = true;
    }

    pub fn now(self: *FakeLink) u64 {
        return self.clock;
    }

    pub fn baudValid(_: *FakeLink, rate: u32) bool {
        if (rate == 0) return false;
        const div = clock_hz / rate;
        return div != 0 and div <= 0xffff;
    }

    pub fn setBaud(self: *FakeLink, rate: u32) bool {
        if (!self.drained) self.early_switch = true;
        self.baud_calls[self.baud_count] = rate;
        self.baud_count += 1;
        self.baud = rate;
        return true;
    }
};

const Disk = struct {
    const count = 64;

    blocks: [count][block_size]u8 = @splat(@splat(0)),
    read_only: bool = false,
    fail: bool = false,
    size: u32 = block_size,

    fn read(ctx: ?*anyopaque, lba: u64, n: u32, dst: [*]u8) bool {
        const self: *Disk = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return false;
        for (0..n) |i| @memcpy(dst[i * block_size ..][0..block_size], &self.blocks[lba + i]);
        return true;
    }

    fn write(ctx: ?*anyopaque, lba: u64, n: u32, src: [*]const u8) bool {
        const self: *Disk = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return false;
        for (0..n) |i| @memcpy(&self.blocks[lba + i], src[i * block_size ..][0..block_size]);
        return true;
    }

    fn block(self: *Disk) conduit.device.Block {
        return .{
            .ctx = self,
            .block_size = self.size,
            .num_blocks = count,
            .read_blocks = read,
            .write_blocks = if (self.read_only) null else write,
        };
    }
};

const TestKind = enum { virtio, sdhci, sd_spi };
const TestEntry = struct { kind: TestKind, dev: conduit.device.Block };

const Script = struct {
    bytes: [16384]FakeLink.Byte = undefined,
    len: usize = 0,

    fn raw(self: *Script, data: []const u8, delay: u32, rate: u32) void {
        for (data, 0..) |b, i| {
            self.bytes[self.len] = .{ .value = b, .delay = if (i == 0) delay else 0, .baud = rate };
            self.len += 1;
        }
    }

    fn request(self: *Script, code: u8, seq: u8, payload: []const u8) void {
        self.requestAt(code, seq, payload, 0, default_baud);
    }

    fn requestAt(self: *Script, code: u8, seq: u8, payload: []const u8, delay: u32, rate: u32) void {
        var head: [header_len]u8 = undefined;
        head[0..2].* = request_magic;
        head[2] = code;
        head[3] = seq;
        std.mem.writeInt(u16, head[4..6], @intCast(payload.len), .little);
        var hash = std.hash.Crc32.init();
        hash.update(head[2..]);
        hash.update(payload);
        var tail: [crc_len]u8 = undefined;
        std.mem.writeInt(u32, &tail, hash.final(), .little);
        self.raw(&head, delay, rate);
        self.raw(payload, 0, rate);
        self.raw(&tail, 0, rate);
    }

    fn boot(self: *Script, seq: u8) void {
        self.request(@backingInt(Command.boot), seq, &.{});
    }
};

const Reply = struct { status: u8, seq: u8, payload: []const u8 };

const Rig = struct {
    link: FakeLink,
    entries: [3]TestEntry,
    replies: [16]Reply = undefined,
    reply_count: usize = 0,

    fn run(self: *Rig, script: *const Script, devices: usize) !void {
        self.link = .{ .input = script.bytes[0..script.len] };
        var engine: Engine(FakeLink, TestEntry) = .{ .transport = &self.link, .devices = self.entries[0..devices] };
        engine.run();
        try testing.expectEqual(script.len, self.link.pos);
        try self.parse();
    }

    fn parse(self: *Rig) !void {
        var rest = self.link.out[0..self.link.out_len];
        while (rest.len > 0) {
            try testing.expect(rest.len >= header_len + crc_len);
            try testing.expectEqualSlices(u8, &reply_magic, rest[0..2]);
            const len = std.mem.readInt(u16, rest[4..6], .little);
            const sum = std.mem.readInt(u32, rest[header_len + len ..][0..crc_len], .little);
            try testing.expectEqual(std.hash.Crc32.hash(rest[2 .. header_len + len]), sum);
            self.replies[self.reply_count] = .{ .status = rest[2], .seq = rest[3], .payload = rest[header_len..][0..len] };
            self.reply_count += 1;
            rest = rest[header_len + len + crc_len ..];
        }
    }

    fn expectReplies(self: *Rig, expected: []const [2]u8) !void {
        try testing.expectEqual(expected.len, self.reply_count);
        for (expected, self.replies[0..self.reply_count]) |want, got| {
            try testing.expectEqual(want[0], got.status);
            try testing.expectEqual(want[1], got.seq);
        }
    }
};

fn writeArgs(buf: []u8, dev: u8, lba: u64, count: u8, fill: u8) []const u8 {
    buf[0] = dev;
    std.mem.writeInt(u64, buf[1..9], lba, .little);
    buf[9] = count;
    const data = buf[write_args_len..][0 .. @as(usize, count) * block_size];
    for (data, 0..) |*b, i| b.* = fill +% @as(u8, @truncate(i / block_size)) +% @as(u8, @truncate(i));
    return buf[0 .. write_args_len + data.len];
}

fn crcArgs(buf: *[crc_args_len]u8, dev: u8, lba: u64, count: u32) []const u8 {
    buf[0] = dev;
    std.mem.writeInt(u64, buf[1..9], lba, .little);
    std.mem.writeInt(u32, buf[9..13], count, .little);
    return buf;
}

const ok = @backingInt(Status.ok);
const cmd_write = @backingInt(Command.write);
const cmd_crc = @backingInt(Command.crc);
const cmd_baud = @backingInt(Command.baud);
const cmd_ping = @backingInt(Command.ping);

fn testRig(disks: *[3]Disk) Rig {
    disks[1].read_only = true;
    return .{
        .link = undefined,
        .entries = .{
            .{ .kind = .sdhci, .dev = disks[0].block() },
            .{ .kind = .virtio, .dev = disks[1].block() },
            .{ .kind = .sd_spi, .dev = disks[2].block() },
        },
    };
}

test "ping gets an ok reply with the same seq, and boot ends the engine" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(cmd_ping, 7, &.{});
    script.boot(8);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 7 }, .{ ok, 8 } });
    try testing.expectEqual(0, rig.replies[0].payload.len);
    try testing.expect(rig.link.drained);
}

test "info lists each device in order with its kind, write flag, block size and count" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(@backingInt(Command.info), 1, &.{});
    script.boot(2);
    try rig.run(&script, 2);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 } });
    const head = [_]u8{ 1, 8, 2 };
    const sdhci = [_]u8{ 1, 1, 0x00, 0x02, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0 };
    const virtio = [_]u8{ 0, 0, 0x00, 0x02, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0 };
    const expected = head ++ sdhci ++ virtio;
    try testing.expectEqualSlices(u8, &expected, rig.replies[0].payload);
}

test "a write of 1 block and of 8 blocks lands at the requested lba" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var one: [max_payload]u8 = undefined;
    var eight: [max_payload]u8 = undefined;
    const one_args = writeArgs(&one, 0, 3, 1, 0x10);
    const eight_args = writeArgs(&eight, 2, 56, 8, 0x40);
    script.request(cmd_write, 1, one_args);
    script.request(cmd_write, 2, eight_args);
    script.boot(3);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 }, .{ ok, 3 } });
    try testing.expectEqualSlices(u8, one_args[write_args_len..], &disks[0].blocks[3]);
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[0].blocks[2]);
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[0].blocks[4]);
    try testing.expectEqualSlices(u8, eight_args[write_args_len..], std.mem.asBytes(disks[2].blocks[56..64]));
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[2].blocks[55]);
}

test "write arguments out of range get bad argument, a read only device gets read only" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var buf: [max_payload]u8 = undefined;
    script.request(cmd_write, 1, writeArgs(&buf, 1, 0, 1, 0x22));
    script.request(cmd_write, 2, writeArgs(&buf, 0, 0, 0, 0));
    // Nine blocks of data do not fit in a frame, so the request has the arguments only.
    var nine: [write_args_len]u8 = @splat(0);
    nine[9] = 9;
    script.request(cmd_write, 3, &nine);
    script.request(cmd_write, 4, writeArgs(&buf, 0, 57, 8, 0));
    script.request(cmd_write, 5, writeArgs(&buf, 3, 0, 1, 0));
    script.request(cmd_write, 6, writeArgs(&buf, 0, std.math.maxInt(u64), 1, 0));
    script.request(cmd_write, 7, writeArgs(&buf, 0, 0, 2, 0)[0 .. write_args_len + block_size]);
    script.boot(8);
    try rig.run(&script, 3);
    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{
        .{ @backingInt(Status.read_only), 1 },
        .{ bad, 2 },
        .{ bad, 3 },
        .{ bad, 4 },
        .{ bad, 5 },
        .{ bad, 6 },
        .{ bad, 7 },
        .{ ok, 8 },
    });
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[1].blocks[0]);
}

test "a device that fails the write or read gets an io error" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    disks[0].fail = true;
    var script: Script = .{};
    var buf: [max_payload]u8 = undefined;
    var args: [crc_args_len]u8 = undefined;
    script.request(cmd_write, 1, writeArgs(&buf, 0, 0, 1, 0));
    script.request(cmd_crc, 2, crcArgs(&args, 0, 0, 1));
    script.boot(3);
    try rig.run(&script, 3);
    const io = @backingInt(Status.io_error);
    try rig.expectReplies(&.{ .{ io, 1 }, .{ io, 2 }, .{ ok, 3 } });
}

test "crc gives the CRC-32 of the blocks across several chunks and checks its arguments" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    for (&disks[1].blocks, 0..) |*blk, i| {
        for (blk, 0..) |*b, j| b.* = @truncate(i * 7 + j * 3);
    }
    var script: Script = .{};
    var args: [5][crc_args_len]u8 = undefined;
    script.request(cmd_crc, 1, crcArgs(&args[0], 1, 5, 20));
    script.request(cmd_crc, 2, crcArgs(&args[1], 1, 0, 0));
    script.request(cmd_crc, 3, crcArgs(&args[2], 1, 0, max_crc_blocks + 1));
    script.request(cmd_crc, 4, crcArgs(&args[3], 1, 60, 5));
    script.request(cmd_crc, 5, crcArgs(&args[4], 3, 0, 1));
    script.boot(6);
    try rig.run(&script, 3);
    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ bad, 2 }, .{ bad, 3 }, .{ bad, 4 }, .{ bad, 5 }, .{ ok, 6 } });
    const want = std.hash.Crc32.hash(std.mem.asBytes(disks[1].blocks[5..25]));
    try testing.expectEqual(want, std.mem.readInt(u32, rig.replies[0].payload[0..4], .little));
}

test "a device with another block size gets bad argument for write and crc" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    disks[2].size = 4096;
    rig.entries[2].dev = disks[2].block();
    var script: Script = .{};
    var buf: [max_payload]u8 = undefined;
    var args: [crc_args_len]u8 = undefined;
    script.request(cmd_write, 1, writeArgs(&buf, 2, 0, 1, 0));
    script.request(cmd_crc, 2, crcArgs(&args, 2, 0, 1));
    script.boot(3);
    try rig.run(&script, 3);
    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ bad, 1 }, .{ bad, 2 }, .{ ok, 3 } });
}

test "a bad frame CRC gets status 1 with the seq of the frame" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(cmd_ping, 42, &.{});
    script.bytes[script.len - 1].value ^= 0xff;
    script.boot(43);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ @backingInt(Status.bad_crc), 42 }, .{ ok, 43 } });
}

test "garbage before the magic is skipped" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.raw("xyWWW\x00U", 0, default_baud);
    script.request(cmd_ping, 1, &.{});
    script.boot(2);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 } });
}

test "a frame cut off in the payload is dropped after the gap and the next frame works" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var buf: [max_payload]u8 = undefined;
    script.request(cmd_write, 1, writeArgs(&buf, 0, 0, 1, 0x33));
    script.len -= 300;
    script.requestAt(cmd_ping, 2, &.{}, gap_ms + 1, default_baud);
    script.boot(3);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 2 }, .{ ok, 3 } });
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[0].blocks[0]);
}

test "a byte gap at the limit keeps the frame" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(cmd_ping, 1, &.{});
    script.bytes[script.len - 1].delay = gap_ms;
    script.boot(2);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 } });
}

test "a length over the limit drops the frame without a reply" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var head = [_]u8{ 'W', 'U', cmd_ping, 1, 0, 0 };
    std.mem.writeInt(u16, head[4..6], max_payload + 1, .little);
    script.raw(&head, 0, default_baud);
    script.requestAt(cmd_ping, 2, &.{}, gap_ms + 1, default_baud);
    script.boot(3);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 2 }, .{ ok, 3 } });
}

test "an unknown command gets status 2" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(0x99, 5, &.{});
    script.boot(6);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ @backingInt(Status.unknown_command), 5 }, .{ ok, 6 } });
}

test "a baud change confirmed by a ping at the new rate stays" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var rate: [4]u8 = undefined;
    std.mem.writeInt(u32, &rate, 921600, .little);
    script.request(cmd_baud, 1, &rate);
    script.requestAt(cmd_ping, 2, &.{}, 50, 921600);
    script.requestAt(@backingInt(Command.boot), 3, &.{}, 0, 921600);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 }, .{ ok, 3 } });
    // The boot command puts the rate back for the rest of the boot.
    try testing.expectEqualSlices(u32, &.{ 921600, default_baud }, rig.link.baud_calls[0..rig.link.baud_count]);
    try testing.expectEqual(default_baud, rig.link.baud);
    try testing.expect(!rig.link.early_switch);
}

test "a baud change with no ping in time goes back to 115200" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var rate: [4]u8 = undefined;
    std.mem.writeInt(u32, &rate, 921600, .little);
    script.request(cmd_baud, 1, &rate);
    script.requestAt(cmd_ping, 2, &.{}, confirm_ms + 100, default_baud);
    script.boot(3);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 }, .{ ok, 3 } });
    try testing.expectEqual(2, rig.link.baud_count);
    try testing.expectEqualSlices(u32, &.{ 921600, default_baud }, rig.link.baud_calls[0..2]);
}

test "a baud with a divisor of 0 or over 0xffff gets bad argument and no change" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var fast: [4]u8 = undefined;
    var slow: [4]u8 = undefined;
    std.mem.writeInt(u32, &fast, FakeLink.clock_hz + 1, .little);
    std.mem.writeInt(u32, &slow, 300, .little);
    script.request(cmd_baud, 1, &fast);
    script.request(cmd_baud, 2, &slow);
    script.request(cmd_baud, 3, &.{ 0, 0, 0, 0 });
    script.boot(4);
    try rig.run(&script, 3);
    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ bad, 1 }, .{ bad, 2 }, .{ bad, 3 }, .{ ok, 4 } });
    try testing.expectEqual(0, rig.link.baud_count);
}

test "boot with a payload gets bad argument and does not end the engine" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(@backingInt(Command.boot), 1, &.{0});
    script.boot(2);
    try rig.run(&script, 3);
    try rig.expectReplies(&.{ .{ @backingInt(Status.bad_argument), 1 }, .{ ok, 2 } });
}

test "rescan and probe get unknown command with no service" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    script.request(@backingInt(Command.rescan), 1, &.{});
    script.request(@backingInt(Command.probe), 2, &.{0});
    script.boot(3);
    try rig.run(&script, 3);
    const unknown = @backingInt(Status.unknown_command);
    try rig.expectReplies(&.{ .{ unknown, 1 }, .{ unknown, 2 }, .{ ok, 3 } });
}

const HookRig = struct {
    var entries: [3]TestEntry = undefined;
    var found: usize = 0;

    fn rescan() []const TestEntry {
        return entries[0..found];
    }

    fn probe(index: u8, out: []u8) ?usize {
        if (index != 0) return null;
        @memcpy(out[0..4], "trac");
        return 4;
    }
};

test "rescan takes the new device list, and probe gives the trace of a host" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    HookRig.entries = rig.entries;
    HookRig.found = 2;
    var script: Script = .{};
    var buf: [max_payload]u8 = undefined;
    const args = writeArgs(&buf, 0, 7, 1, 0x5a);
    script.request(@backingInt(Command.info), 1, &.{});
    script.request(@backingInt(Command.rescan), 2, &.{});
    script.request(cmd_write, 3, args);
    script.request(@backingInt(Command.rescan), 4, &.{1});
    script.request(@backingInt(Command.probe), 5, &.{0});
    script.request(@backingInt(Command.probe), 6, &.{1});
    script.request(@backingInt(Command.probe), 7, &.{});
    script.boot(8);

    rig.link = .{ .input = script.bytes[0..script.len] };
    var engine: Engine(FakeLink, TestEntry) = .{
        .transport = &rig.link,
        .devices = rig.entries[0..0],
        .hooks = .{ .rescan = HookRig.rescan, .probe = HookRig.probe },
    };
    engine.run();
    try rig.parse();

    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ ok, 2 }, .{ ok, 3 }, .{ bad, 4 }, .{ ok, 5 }, .{ bad, 6 }, .{ bad, 7 }, .{ ok, 8 } });
    try testing.expectEqual(0, rig.replies[0].payload[2]);
    try testing.expectEqualSlices(u8, &.{2}, rig.replies[1].payload);
    try testing.expectEqualSlices(u8, args[write_args_len..], &disks[0].blocks[7]);
    try testing.expectEqualSlices(u8, "trac", rig.replies[4].payload);
}

const TraceRig = struct {
    var seen_lba: u64 = 0;
    var seen_first: u8 = 0;

    fn writeTrace(index: u8, lba: u64, data: *const [block_size]u8, out: []u8) ?usize {
        if (index != 0) return null;
        seen_lba = lba;
        seen_first = data[0];
        // The service can use the memory of the request.
        @memset(out[0..32], 0xee);
        return 32;
    }
};

test "write trace takes one block in the layout of a write and gives the records" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var one: [max_payload]u8 = undefined;
    var other: [max_payload]u8 = undefined;
    var two: [max_payload]u8 = undefined;
    const cmd = @backingInt(Command.write_trace);
    script.request(cmd, 1, writeArgs(&one, 0, 2_000_000, 1, 0x33));
    script.request(cmd, 2, writeArgs(&other, 1, 5, 1, 0x44));
    script.request(cmd, 3, writeArgs(&two, 0, 5, 2, 0x55));
    script.request(cmd, 4, &.{0});
    script.boot(5);

    rig.link = .{ .input = script.bytes[0..script.len] };
    var engine: Engine(FakeLink, TestEntry) = .{
        .transport = &rig.link,
        .devices = rig.entries[0..3],
        .hooks = .{ .write_trace = TraceRig.writeTrace },
    };
    engine.run();
    try rig.parse();

    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ bad, 2 }, .{ bad, 3 }, .{ bad, 4 }, .{ ok, 5 } });
    try testing.expectEqual(2_000_000, TraceRig.seen_lba);
    try testing.expectEqual(0x33, TraceRig.seen_first);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xee)), rig.replies[0].payload);
    // The disks of the block layer get no write from a trace.
    try testing.expectEqualSlices(u8, &@as([block_size]u8, @splat(0)), &disks[0].blocks[5]);
}

const ReadTraceRig = struct {
    var seen: [3]u64 = @splat(0);

    fn readTrace(index: u8, lba: u64, count: u8, out: []u8) ?usize {
        if (index != 0) return null;
        seen = .{ index, lba, count };
        @memset(out[0..16], 0xdd);
        return 16;
    }
};

test "read trace takes a host, an lba and a count of 0 to 8" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    var args: [4][write_args_len]u8 = undefined;
    const cmd = @backingInt(Command.read_trace);
    script.request(cmd, 1, traceArgs(&args[0], 0, 4096, 0));
    script.request(cmd, 2, traceArgs(&args[1], 0, 9, 9));
    script.request(cmd, 3, traceArgs(&args[2], 1, 9, 0));
    script.request(cmd, 4, &.{ 0, 0 });
    script.boot(5);

    rig.link = .{ .input = script.bytes[0..script.len] };
    var engine: Engine(FakeLink, TestEntry) = .{
        .transport = &rig.link,
        .devices = rig.entries[0..3],
        .hooks = .{ .read_trace = ReadTraceRig.readTrace },
    };
    engine.run();
    try rig.parse();

    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ bad, 2 }, .{ bad, 3 }, .{ bad, 4 }, .{ ok, 5 } });
    try testing.expectEqualSlices(u64, &.{ 0, 4096, 0 }, &ReadTraceRig.seen);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xdd)), rig.replies[0].payload);
}

fn traceArgs(buf: *[write_args_len]u8, host: u8, lba: u64, count: u8) []const u8 {
    buf[0] = host;
    std.mem.writeInt(u64, buf[1..9], lba, .little);
    buf[9] = count;
    return buf;
}

const RawRig = struct {
    var command: [4]u32 = @splat(0);
    var access: [4]u32 = @splat(0);

    fn sdCommand(index: u8, opcode: u8, resp: u8, arg: u32, out: []u8) ?usize {
        if (index != 0) return null;
        command = .{ index, opcode, resp, arg };
        @memset(out[0..16], 0xcc);
        return 16;
    }

    fn sdRegister(index: u8, offset: u8, write: bool, value: u32) ?u32 {
        if (index != 0 or offset % 8 != 0) return null;
        access = .{ index, offset, @intFromBool(write), value };
        return 0x1234_5678;
    }
};

test "sd command and sd register pass their arguments and give the record or the value" {
    var disks: [3]Disk = @splat(.{});
    var rig = testRig(&disks);
    var script: Script = .{};
    const cmd = @backingInt(Command.sd_command);
    const reg = @backingInt(Command.sd_register);
    script.request(cmd, 1, &.{ 0, 13, 1, 0x00, 0x00, 0xaa, 0xaa });
    script.request(cmd, 2, &.{ 0, 13, 5, 0, 0, 0, 0 });
    script.request(cmd, 3, &.{ 1, 13, 1, 0, 0, 0, 0 });
    script.request(reg, 4, &.{ 0, 0x10, 1, 0x1f, 0, 0, 0 });
    script.request(reg, 5, &.{ 0, 0x11, 0, 0, 0, 0, 0 });
    script.request(reg, 6, &.{ 0, 0x10, 2, 0, 0, 0, 0 });
    script.request(reg, 7, &.{ 0, 0x10 });
    script.boot(8);

    rig.link = .{ .input = script.bytes[0..script.len] };
    var engine: Engine(FakeLink, TestEntry) = .{
        .transport = &rig.link,
        .devices = rig.entries[0..3],
        .hooks = .{ .sd_command = RawRig.sdCommand, .sd_register = RawRig.sdRegister },
    };
    engine.run();
    try rig.parse();

    const bad = @backingInt(Status.bad_argument);
    try rig.expectReplies(&.{ .{ ok, 1 }, .{ bad, 2 }, .{ bad, 3 }, .{ ok, 4 }, .{ bad, 5 }, .{ bad, 6 }, .{ bad, 7 }, .{ ok, 8 } });
    try testing.expectEqualSlices(u32, &.{ 0, 13, 1, 0xaaaa_0000 }, &RawRig.command);
    try testing.expectEqualSlices(u32, &.{ 0, 0x10, 1, 0x1f }, &RawRig.access);
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xcc)), rig.replies[0].payload);
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, rig.replies[3].payload);
}
