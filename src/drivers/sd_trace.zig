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

const status_busy: u32 = 1 << 8;
const int_cmd_timeout: u32 = 0x10;
const int_all: u32 = 0xff;

const resp_none = 0;
const resp_short = 1;
const resp_long = 2;

const init_hz = 400_000;
const busy_polls = 4_000_000;
const op_cond_tries = 2000;

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

        /// Runs the sequence for a host with an input clock of `freq` Hz. It
        /// returns the number of bytes written to `out`.
        pub fn run(self: *Self, freq: u32) usize {
            self.bus.write(ctrl, 1);
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
                const ocr = if (app != null) self.command(41, hcs | 0x00ff_8000, resp_short, tries) else null;
                ready = if (ocr) |r| r & 0x8000_0000 != 0 else false;
                if (ocr == null) break;
                if (!ready and tries < op_cond_tries) self.len = mark;
            }
            if (!ready) return self.len;

            if (self.command(2, 0, resp_long, 0) == null) return self.len;
            _ = self.command(3, 0, resp_short, 0);
            return self.len;
        }

        fn command(self: *Self, opcode: u8, arg: u32, resp: u32, count: u16) ?u32 {
            if (!self.idle()) {
                self.record(opcode, .busy_before, count, 0);
                return null;
            }
            self.bus.write(int_status, int_all);
            self.bus.write(cmd_arg, arg);
            self.bus.write(cmd_reg, @as(u32, opcode) | (resp << 6));
            if (!self.idle()) {
                self.record(opcode, .busy_after, count, 0);
                return null;
            }
            const response = self.bus.read(resp0);
            if (self.bus.read(int_status) & int_cmd_timeout != 0) {
                self.record(opcode, .timeout, count, response);
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

    pub fn read(self: *Model, off: usize) u32 {
        return switch (off) {
            status => (if (self.stuck) status_busy else 0) | 1,
            int_status => self.int,
            resp0 => self.resp,
            else => 0,
        };
    }

    pub fn write(self: *Model, off: usize, value: u32) void {
        switch (off) {
            int_status => self.int &= ~value,
            clk_div => self.divider = value,
            cmd_reg => self.send(@intCast(value & 0x3f)),
            else => {},
        }
    }

    fn send(self: *Model, opcode: u8) void {
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
