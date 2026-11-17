//! A trace of the SD identification sequence on a Harbor SD host. It sends
//! the same commands as the driver and records what the controller reports
//! for each one, so a card that does not answer can be told from a card that
//! answers badly.
//!
//! The card is in the identification state after a trace. Find the storage
//! again before the next block access.

const std = @import("std");

pub const record_len = 16;

/// What the controller did with one command.
pub const Outcome = enum(u8) {
    ok = 0,
    /// The controller was busy before the command and did not become idle.
    busy_before = 1,
    /// The controller did not become idle after the command.
    busy_after = 2,
    /// The card sent no response.
    timeout = 3,
    /// The response had a bad CRC7, end bit or command index.
    bad_response = 4,
};

/// The opcode of the first record. It holds the controller state before the
/// first command and no command result.
pub const state_opcode = 0xff;

const ctrl = 0x00;
const status = 0x08;
const clk_div = 0x10;
const cmd_reg = 0x18;
const cmd_arg = 0x20;
const resp0 = 0x28;
const int_status = 0x60;
const int_enable = 0x68;

const ctrl_sample_fall: u32 = 1 << 8;
const status_busy: u32 = 1 << 8;
const int_cmd_timeout: u32 = 0x10;
const int_resp_errors: u32 = 0xe00;
const int_all: u32 = 0xfff;

const resp_none = 0;
const resp_short = 1;
const resp_long = 2;
const resp_busy = 3;
/// The response type that `runCommand` takes for an R3 response.
pub const resp_r3 = 4;

const init_hz = 400_000;
const busy_polls = 4_000_000;
const op_cond_tries = 2000;

const blk_size = 0x50;
const blk_count = 0x58;
const adma_addr = 0x70;

const flag_data: u32 = 1 << 8;
const flag_read: u32 = 1 << 9;
const flag_dma: u32 = 1 << 10;
// An R3 response has no CRC7 and no command index. These bits stop the checks.
const flag_r3: u32 = (1 << 12) | (1 << 13);

const send_status = 13;
const card_ready: u32 = 1 << 8;
const state_transfer = 4;
const max_status_polls = 20000;

/// The opcode of the last record of a write trace. Its count is 1 when the
/// block that was read back is the block that was written, and its response
/// is the offset of the first byte that differs.
pub const compare_opcode = 0xfe;

/// The opcode of the last record of a read trace. Its count is the number of
/// blocks, and its response is the CRC-32 of the data.
pub const data_opcode = 0xfd;
pub const max_read_blocks = 8;

pub const WriteArgs = struct {
    rca: u32,
    /// The block number, or the byte offset for a standard capacity card.
    card_addr: u32,
    write_addr: u32,
    read_addr: u32,
};

pub const ReadArgs = struct {
    rca: u32,
    card_addr: u32,
    read_addr: u32,
    /// 0 sends no read. The trace then has the card status and a stop only.
    count: u8,
};

/// Register access at a fixed base address.
pub const Mmio = struct {
    base: usize,

    pub fn read(self: Mmio, off: usize) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        return ptr.*;
    }

    pub fn write(self: Mmio, off: usize, value: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        ptr.* = value;
    }
};

pub fn Tracer(comptime Bus: type) type {
    return struct {
        const Self = @This();

        bus: Bus,
        out: []u8,
        len: usize = 0,
        busy_limit: usize = busy_polls,
        status_polls: u16 = max_status_polls,
        stuck: bool = false,

        /// Runs the sequence for a host with an input clock of `freq` Hz. It
        /// returns the number of bytes written to `out`.
        pub fn run(self: *Self, freq: u32) usize {
            // The reset value of the sample edge bit is the choice of the board.
            self.bus.write(ctrl, (self.bus.read(ctrl) & ctrl_sample_fall) | 1);
            self.bus.write(int_enable, 0);
            self.bus.write(int_status, int_all);
            const half = freq / (2 * init_hz);
            self.bus.write(clk_div, if (half > 0) half - 1 else 0);
            self.record(state_opcode, .ok, 0, 0);

            _ = self.command(0, 0, resp_none, 0);
            const if_cond = self.command(8, 0x1aa, resp_short, 0);
            const v2 = if (if_cond) |r| r & 0xff == 0xaa else false;
            const hcs: u32 = if (v2) 0x4000_0000 else 0;

            // Only the last try of the loop gets records, with the try count.
            var tries: u16 = 0;
            var ready = false;
            while (tries < op_cond_tries and !ready) {
                tries += 1;
                const mark = self.len;
                const app = self.command(55, 0, resp_short, tries);
                const ocr = if (app != null) self.commandFlags(41, hcs | 0x00ff_8000, resp_short, flag_r3, tries) else null;
                ready = if (ocr) |r| r & 0x8000_0000 != 0 else false;
                if (ocr == null) break;
                if (!ready and tries < op_cond_tries) self.len = mark;
            }
            if (!ready) return self.len;

            if (self.command(2, 0, resp_long, 0) == null) return self.len;
            _ = self.command(3, 0, resp_short, 0);
            return self.len;
        }

        /// Writes one block from memory at `args.write_addr` and reads it back
        /// to `args.read_addr`. It asks the card for its status before the
        /// write and again and again after it, until the card is in the
        /// transfer state and ready for data. A record follows each change of
        /// the answer. It returns the number of bytes written to `out`.
        pub fn runWrite(self: *Self, args: WriteArgs) usize {
            self.record(state_opcode, .ok, 0, 0);
            _ = self.command(send_status, args.rca << 16, resp_short, 0);

            self.bus.write(adma_addr, args.write_addr);
            self.bus.write(blk_size, 512);
            self.bus.write(blk_count, 1);
            _ = self.commandFlags(24, args.card_addr, resp_short, flag_data | flag_dma, 0);

            if (!self.waitForTransfer(args.rca)) return self.len;

            self.bus.write(adma_addr, args.read_addr);
            self.bus.write(blk_size, 512);
            self.bus.write(blk_count, 1);
            _ = self.commandFlags(17, args.card_addr, resp_short, flag_data | flag_read | flag_dma, 0);
            _ = self.command(send_status, args.rca << 16, resp_short, 0);
            return self.len;
        }

        /// Reads `args.count` blocks to memory at `args.read_addr`, with the
        /// card status before and after. One block uses command 17. More
        /// blocks use command 18, then command 12. A count of 0 sends the
        /// status, a stop and the status again. It returns the number of
        /// bytes written to `out`.
        pub fn runRead(self: *Self, args: ReadArgs) usize {
            self.record(state_opcode, .ok, 0, 0);
            _ = self.command(send_status, args.rca << 16, resp_short, 0);
            if (args.count > 0) {
                self.bus.write(adma_addr, args.read_addr);
                self.bus.write(blk_size, 512);
                self.bus.write(blk_count, args.count);
                const opcode: u8 = if (args.count == 1) 17 else 18;
                _ = self.commandFlags(opcode, args.card_addr, resp_short, flag_data | flag_read | flag_dma, args.count);
            }
            if (args.count != 1) _ = self.command(12, 0, resp_busy, 0);
            _ = self.command(send_status, args.rca << 16, resp_short, 0);
            return self.len;
        }

        // The count of each record is the number of the poll, so the gaps
        // show how long each answer stayed.
        fn waitForTransfer(self: *Self, rca: u32) bool {
            var last: ?u32 = 0xffff_ffff;
            var poll: u16 = 0;
            while (poll < self.status_polls) {
                poll += 1;
                const mark = self.len;
                const answer = self.command(send_status, rca << 16, resp_short, poll);
                const ready = if (answer) |r| r & card_ready != 0 and (r >> 9) & 0xf == state_transfer else false;
                if (ready) return true;
                const same = if (answer) |r| last != null and last.? == r else last == null;
                if (same and poll < self.status_polls and !self.stuck) self.len = mark;
                last = answer;
                // With a controller that stays busy, each poll takes seconds.
                if (self.stuck) return false;
            }
            return false;
        }

        fn command(self: *Self, opcode: u8, arg: u32, resp: u32, count: u16) ?u32 {
            return self.commandFlags(opcode, arg, resp, 0, count);
        }

        fn commandFlags(self: *Self, opcode: u8, arg: u32, resp: u32, flags: u32, count: u16) ?u32 {
            if (!self.idle()) {
                self.stuck = true;
                self.record(opcode, .busy_before, count, 0);
                return null;
            }
            self.bus.write(int_status, int_all);
            self.bus.write(cmd_arg, arg);
            self.bus.write(cmd_reg, @as(u32, opcode) | (resp << 6) | flags);
            if (!self.idle()) {
                self.stuck = true;
                self.record(opcode, .busy_after, count, 0);
                return null;
            }
            const response = self.bus.read(resp0);
            const int = self.bus.read(int_status);
            if (int & int_cmd_timeout != 0) {
                self.record(opcode, .timeout, count, response);
                return null;
            }
            if (int & int_resp_errors != 0) {
                self.record(opcode, .bad_response, count, response);
                return null;
            }
            self.record(opcode, .ok, count, response);
            return response;
        }

        fn idle(self: *Self) bool {
            var polls: usize = 0;
            while (polls < self.busy_limit) : (polls += 1) {
                if (self.bus.read(status) & status_busy == 0) return true;
            }
            return false;
        }

        fn record(self: *Self, opcode: u8, outcome: Outcome, count: u16, response: u32) void {
            if (self.len + record_len > self.out.len) return;
            const at = self.out[self.len..][0..record_len];
            at[0] = opcode;
            at[1] = @backingInt(outcome);
            std.mem.writeInt(u16, at[2..4], count, .little);
            std.mem.writeInt(u32, at[4..8], self.bus.read(int_status), .little);
            std.mem.writeInt(u32, at[8..12], response, .little);
            std.mem.writeInt(u32, at[12..16], self.bus.read(status), .little);
            self.len += record_len;
        }
    };
}

/// Traces the host at `base`. It returns the number of bytes written to `out`.
pub fn run(base: usize, freq: u32, out: []u8) usize {
    var tracer: Tracer(Mmio) = .{ .bus = .{ .base = base }, .out = out };
    return tracer.run(freq);
}

/// Sends one command with no data to the host at `base` and writes its record
/// to `out`. `resp` is the response type of the controller, 0 to 3, or
/// `resp_r3` for a short response with no CRC7 and no index. It returns the
/// number of bytes written.
pub fn runCommand(base: usize, opcode: u8, resp: u8, arg: u32, out: []u8) usize {
    var tracer: Tracer(Mmio) = .{ .bus = .{ .base = base }, .out = out };
    if (resp == resp_r3) {
        _ = tracer.commandFlags(opcode & 0x3f, arg, resp_short, flag_r3, 0);
    } else {
        _ = tracer.command(opcode & 0x3f, arg, resp & 3, 0);
    }
    return tracer.len;
}

/// The size of the register block of the controller.
pub const register_span = 0x98;

/// Writes `value` to the register at `offset` when `write` is set, then
/// reads the register. `offset` is a multiple of 8 below register_span.
pub fn register(base: usize, offset: u8, write: bool, value: u32) u32 {
    const bus: Mmio = .{ .base = base };
    if (write) bus.write(offset, value);
    return bus.read(offset);
}

// The DMA engine reads and writes these, so they do not share a cache line
// with other data.
var write_block: [512]u8 align(64) = @splat(0);
var read_block: [512]u8 align(64) = @splat(0);

/// Writes `data` to one block of the card on the host at `base` and traces
/// each step. `out` can overlap `data`. It returns the number of bytes
/// written to `out`, or null when the buffers are above 4 GiB.
pub fn runWrite(base: usize, rca: u32, card_addr: u32, data: *const [512]u8, out: []u8) ?usize {
    const write_addr = std.math.cast(u32, @intFromPtr(&write_block)) orelse return null;
    const read_addr = std.math.cast(u32, @intFromPtr(&read_block)) orelse return null;
    write_block = data.*;
    @memset(&read_block, 0);
    syncMemory();

    var tracer: Tracer(Mmio) = .{ .bus = .{ .base = base }, .out = out };
    const len = tracer.runWrite(.{ .rca = rca, .card_addr = card_addr, .write_addr = write_addr, .read_addr = read_addr });

    syncMemory();
    const differ = std.mem.indexOfDiff(u8, &write_block, &read_block);
    if (len + record_len > out.len) return len;
    const at = out[len..][0..record_len];
    @memset(at, 0);
    at[0] = compare_opcode;
    std.mem.writeInt(u16, at[2..4], @intFromBool(differ == null), .little);
    std.mem.writeInt(u32, at[8..12], @intCast(differ orelse 0), .little);
    return len + record_len;
}

var read_blocks: [max_read_blocks * 512]u8 align(64) = @splat(0);

/// Reads `count` blocks from the card on the host at `base` and traces each
/// step. `count` is at most max_read_blocks. It returns the number of bytes
/// written to `out`, or null when the buffer is above 4 GiB.
pub fn runRead(base: usize, rca: u32, card_addr: u32, count: u8, out: []u8) ?usize {
    std.debug.assert(count <= max_read_blocks);
    const read_addr = std.math.cast(u32, @intFromPtr(&read_blocks)) orelse return null;
    @memset(&read_blocks, 0);
    syncMemory();

    var tracer: Tracer(Mmio) = .{ .bus = .{ .base = base }, .out = out };
    const len = tracer.runRead(.{ .rca = rca, .card_addr = card_addr, .read_addr = read_addr, .count = count });

    syncMemory();
    if (len + record_len > out.len) return len;
    const at = out[len..][0..record_len];
    @memset(at, 0);
    at[0] = data_opcode;
    std.mem.writeInt(u16, at[2..4], count, .little);
    std.mem.writeInt(u32, at[8..12], std.hash.Crc32.hash(read_blocks[0 .. @as(usize, count) * 512]), .little);
    return len + record_len;
}

// On River a fence.i sends the stores to memory and empties the data cache,
// so the DMA engine and the CPU see the same bytes.
fn syncMemory() void {
    switch (@import("builtin").target.cpu.arch) {
        .riscv64, .riscv32 => asm volatile ("fence.i" ::: .{ .memory = true }),
        else => {},
    }
}

const testing = std.testing;

/// A host with a card that answers after `ready_after` tries, or with no card.
const Model = struct {
    card: bool = true,
    stuck: bool = false,
    ready_after: u16 = 3,
    op_cond_count: u16 = 0,
    int: u32 = 0,
    resp: u32 = 0,
    divider: u32 = 0xffff_ffff,
    control: u32 = ctrl_sample_fall,

    pub fn read(self: *Model, off: usize) u32 {
        return switch (off) {
            ctrl => self.control,
            status => (if (self.stuck) status_busy else 0) | 1,
            int_status => self.int,
            resp0 => self.resp,
            else => 0,
        };
    }

    pub fn write(self: *Model, off: usize, value: u32) void {
        switch (off) {
            int_status => self.int &= ~value,
            ctrl => self.control = value,
            clk_div => self.divider = value,
            cmd_reg => self.send(@intCast(value & 0x3f), value & flag_r3 == flag_r3),
            else => {},
        }
    }

    fn send(self: *Model, opcode: u8, unchecked: bool) void {
        // The host checks the CRC7 and the index, which an R3 response does
        // not have. A bad response does not set command done.
        if (self.card and opcode == 41 and !unchecked) {
            self.int |= 0xa00;
            return;
        }
        self.int |= 1;
        if (opcode == 0) return;
        if (!self.card) {
            self.int |= int_cmd_timeout;
            return;
        }
        self.resp = switch (opcode) {
            8 => 0x1aa,
            41 => blk: {
                self.op_cond_count += 1;
                break :blk if (self.op_cond_count >= self.ready_after) 0xc0ff_8000 else 0x00ff_8000;
            },
            3 => 0x1234_0500,
            else => 0x120,
        };
    }
};

const Record = struct { opcode: u8, outcome: Outcome, count: u16, int: u32, resp: u32 };

fn recordAt(out: []const u8, index: usize) Record {
    const at = out[index * record_len ..][0..record_len];
    return .{
        .opcode = at[0],
        .outcome = @fromBackingInt(at[1]),
        .count = std.mem.readInt(u16, at[2..4], .little),
        .int = std.mem.readInt(u32, at[4..8], .little),
        .resp = std.mem.readInt(u32, at[8..12], .little),
    };
}

test "a card that answers gives one record for each step and the try count" {
    var model: Model = .{};
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    const len = tracer.run(25_000_000);
    try testing.expectEqual(7 * record_len, len);
    try testing.expectEqual(@as(u32, 30), model.divider);
    try testing.expectEqual(ctrl_sample_fall | 1, model.control);

    const opcodes = [_]u8{ state_opcode, 0, 8, 55, 41, 2, 3 };
    for (opcodes, 0..) |opcode, i| {
        const r = recordAt(&out, i);
        try testing.expectEqual(opcode, r.opcode);
        try testing.expectEqual(Outcome.ok, r.outcome);
    }
    try testing.expectEqual(@as(u32, 0x1aa), recordAt(&out, 2).resp);
    try testing.expectEqual(@as(u16, 3), recordAt(&out, 4).count);
    try testing.expectEqual(@as(u32, 0xc0ff_8000), recordAt(&out, 4).resp);
    try testing.expectEqual(@as(u32, 0x1234_0500), recordAt(&out, 6).resp);
}

test "a response with an error bit gives a bad response record" {
    var model: Model = .{};
    var out: [2 * record_len]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    try testing.expect(tracer.command(41, 0, resp_short, 0) == null);
    try testing.expectEqual(Outcome.bad_response, recordAt(&out, 0).outcome);
    try testing.expectEqual(@as(u32, 0xa00), recordAt(&out, 0).int);
    try testing.expect(tracer.commandFlags(41, 0, resp_short, flag_r3, 0) != null);
    try testing.expectEqual(Outcome.ok, recordAt(&out, 1).outcome);
}

test "a slot with no card stops at the first command that needs a response" {
    var model: Model = .{ .card = false };
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    const len = tracer.run(25_000_000);
    try testing.expectEqual(4 * record_len, len);
    try testing.expectEqual(Outcome.ok, recordAt(&out, 1).outcome);
    try testing.expectEqual(Outcome.timeout, recordAt(&out, 2).outcome);
    try testing.expect(recordAt(&out, 2).int & int_cmd_timeout != 0);
    try testing.expectEqual(@as(u8, 55), recordAt(&out, 3).opcode);
    try testing.expectEqual(Outcome.timeout, recordAt(&out, 3).outcome);
    try testing.expectEqual(@as(u16, 1), recordAt(&out, 3).count);
}

test "a controller that stays busy gives busy records and ends" {
    var model: Model = .{ .stuck = true };
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    const len = tracer.run(25_000_000);
    try testing.expectEqual(4 * record_len, len);
    try testing.expectEqual(Outcome.busy_before, recordAt(&out, 1).outcome);
    try testing.expectEqual(Outcome.busy_before, recordAt(&out, 3).outcome);
}

test "a card that never becomes ready ends after the try limit with the last try" {
    var model: Model = .{ .ready_after = 0xffff };
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    const len = tracer.run(25_000_000);
    try testing.expectEqual(5 * record_len, len);
    try testing.expectEqual(@as(u16, op_cond_tries), recordAt(&out, 4).count);
    try testing.expectEqual(@as(u32, 0x00ff_8000), recordAt(&out, 4).resp);
}

test "the records stop when the buffer is full" {
    var model: Model = .{};
    var out: [2 * record_len + 5]u8 = undefined;
    var tracer: Tracer(*Model) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    try testing.expectEqual(2 * record_len, tracer.run(25_000_000));
}

/// A card in the transfer state that programs for `busy_polls` status reads
/// after a write.
const WriteModel = struct {
    busy_polls: u16 = 5,
    silent_after_write: bool = false,
    wrote: bool = false,
    polls: u16 = 0,
    int: u32 = 0,
    resp: u32 = 0,
    commands: [8]u32 = @splat(0),
    command_count: usize = 0,
    adma: [2]u32 = @splat(0),
    adma_count: usize = 0,

    pub fn read(self: *WriteModel, off: usize) u32 {
        return switch (off) {
            status => 1,
            int_status => self.int,
            resp0 => self.resp,
            else => 0,
        };
    }

    pub fn write(self: *WriteModel, off: usize, value: u32) void {
        switch (off) {
            int_status => self.int &= ~value,
            adma_addr => {
                self.adma[self.adma_count] = value;
                self.adma_count += 1;
            },
            cmd_reg => self.send(value),
            else => {},
        }
    }

    fn send(self: *WriteModel, value: u32) void {
        const opcode = value & 0x3f;
        if (opcode != send_status and self.command_count < self.commands.len) {
            self.commands[self.command_count] = value;
            self.command_count += 1;
        }
        self.int |= 1;
        if (self.wrote and self.silent_after_write) {
            self.int |= int_cmd_timeout;
            return;
        }
        switch (opcode) {
            24 => {
                self.wrote = true;
                self.int |= 2;
                self.resp = 0x900;
            },
            17 => {
                self.int |= 2;
                self.resp = 0x900;
            },
            send_status => {
                if (!self.wrote) {
                    self.resp = 0x900;
                    return;
                }
                self.polls += 1;
                // State 7 is programming, with the ready bit clear.
                self.resp = if (self.polls > self.busy_polls) 0x900 else 0xe00;
            },
            else => {},
        }
    }
};

const write_args: WriteArgs = .{ .rca = 0xaaaa, .card_addr = 2_000_000, .write_addr = 0x8010_0000, .read_addr = 0x8010_0400 };

test "a write trace records each change of the card status and reads the block back" {
    var model: WriteModel = .{};
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*WriteModel) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    const len = tracer.runWrite(write_args);

    // State, status, write, the first busy status, the ready status, read, status.
    try testing.expectEqual(7 * record_len, len);
    const opcodes = [_]u8{ state_opcode, 13, 24, 13, 13, 17, 13 };
    for (opcodes, 0..) |opcode, i| {
        try testing.expectEqual(opcode, recordAt(&out, i).opcode);
        try testing.expectEqual(Outcome.ok, recordAt(&out, i).outcome);
    }
    try testing.expectEqual(@as(u32, 0xe00), recordAt(&out, 3).resp);
    try testing.expectEqual(@as(u16, 1), recordAt(&out, 3).count);
    try testing.expectEqual(@as(u32, 0x900), recordAt(&out, 4).resp);
    try testing.expectEqual(@as(u16, 6), recordAt(&out, 4).count);
    try testing.expect(recordAt(&out, 2).int & 2 != 0);

    try testing.expectEqualSlices(u32, &.{ 24 | (1 << 6) | flag_data | flag_dma, 17 | (1 << 6) | flag_data | flag_read | flag_dma }, model.commands[0..model.command_count]);
    try testing.expectEqualSlices(u32, &.{ write_args.write_addr, write_args.read_addr }, &model.adma);
}

test "a card that is silent after the write ends the trace with no read" {
    var model: WriteModel = .{ .silent_after_write = true };
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*WriteModel) = .{ .bus = &model, .out = &out, .busy_limit = 4, .status_polls = 50 };
    const len = tracer.runWrite(write_args);

    // State, status, write, the first status with no answer, the last one.
    try testing.expectEqual(5 * record_len, len);
    try testing.expectEqual(Outcome.timeout, recordAt(&out, 3).outcome);
    try testing.expectEqual(@as(u16, 1), recordAt(&out, 3).count);
    try testing.expectEqual(Outcome.timeout, recordAt(&out, 4).outcome);
    try testing.expectEqual(@as(u16, 50), recordAt(&out, 4).count);
    try testing.expectEqual(1, model.command_count);
}

test "a card that stays in the programming state ends the trace at the poll limit" {
    var model: WriteModel = .{ .busy_polls = 0xffff };
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*WriteModel) = .{ .bus = &model, .out = &out, .busy_limit = 4, .status_polls = 50 };
    const len = tracer.runWrite(write_args);
    try testing.expectEqual(5 * record_len, len);
    try testing.expectEqual(@as(u32, 0xe00), recordAt(&out, 4).resp);
    try testing.expectEqual(@as(u16, 50), recordAt(&out, 4).count);
}

test "a read trace uses command 17 for one block and commands 18 and 12 for more" {
    var one: WriteModel = .{};
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*WriteModel) = .{ .bus = &one, .out = &out, .busy_limit = 4 };
    try testing.expectEqual(4 * record_len, tracer.runRead(.{ .rca = 0xaaaa, .card_addr = 7, .read_addr = 0x8010_0000, .count = 1 }));
    for ([_]u8{ state_opcode, 13, 17, 13 }, 0..) |opcode, i| try testing.expectEqual(opcode, recordAt(&out, i).opcode);
    try testing.expectEqualSlices(u32, &.{17 | (1 << 6) | flag_data | flag_read | flag_dma}, one.commands[0..one.command_count]);

    var many: WriteModel = .{};
    tracer = .{ .bus = &many, .out = &out, .busy_limit = 4 };
    try testing.expectEqual(5 * record_len, tracer.runRead(.{ .rca = 0xaaaa, .card_addr = 7, .read_addr = 0x8010_0000, .count = 8 }));
    for ([_]u8{ state_opcode, 13, 18, 12, 13 }, 0..) |opcode, i| try testing.expectEqual(opcode, recordAt(&out, i).opcode);
    try testing.expectEqual(@as(u16, 8), recordAt(&out, 2).count);
    try testing.expectEqualSlices(u32, &.{ 18 | (1 << 6) | flag_data | flag_read | flag_dma, 12 | (3 << 6) }, many.commands[0..many.command_count]);
}

test "a read trace with a count of 0 sends the status, a stop and the status" {
    var model: WriteModel = .{};
    var out: [16 * record_len]u8 = undefined;
    var tracer: Tracer(*WriteModel) = .{ .bus = &model, .out = &out, .busy_limit = 4 };
    try testing.expectEqual(4 * record_len, tracer.runRead(.{ .rca = 0xaaaa, .card_addr = 7, .read_addr = 0x8010_0000, .count = 0 }));
    for ([_]u8{ state_opcode, 13, 12, 13 }, 0..) |opcode, i| try testing.expectEqual(opcode, recordAt(&out, i).opcode);
    try testing.expectEqualSlices(u32, &.{12 | (3 << 6)}, model.commands[0..model.command_count]);
}
