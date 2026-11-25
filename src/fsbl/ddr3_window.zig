//! The training window of the Harbor DDR3 controller. A build with a window
//! can wait for firmware before it trains, and DRAM accesses then wait with
//! no error until the controller releases the bus. The FSBL starts the
//! hardware sequence and waits for its result.

const std = @import("std");

pub const Cmd = enum(u4) {
    nop,
    dly,
    mpr_read,
    pat_write,
    pat_read,
    wrlvl,
    run_hw,
    release,
    pat_mask,
    _,
};

pub const State = enum(u4) {
    idle,
    base,
    wrlvl,
    wr_init,
    gate,
    mpr_center,
    wlane,
    pat_init,
    deskew,
    center,
    wcenter,
    dm_check,
    done,
    failed,
    firmware,
    _,
};

pub const Fail = enum(u4) {
    none,
    wrlvl_no_edge,
    gate_no_window,
    deskew_no_eye,
    read_no_eye,
    write_no_eye,
    dly_timeout,
    read_timeout,
    wrlvl_timeout,
    dm_no_eye,
    watchdog,
    _,

    pub fn name(self: Fail) []const u8 {
        return std.enums.tagName(Fail, self) orelse "unknown";
    }
};

pub const Status = packed struct(u32) {
    busy: bool,
    released: bool,
    done: bool,
    failed: bool,
    reject: bool,
    phyupd_held: bool,
    reserved0: u2,
    last_fail: Fail,
    state: State,
    attempts: u4,
    fail_code: Fail,
    fail_lane: u3,
    fail_rank: u1,
    reserved1: u4,
};

pub const LaneResult = packed struct(u32) {
    fail_code: Fail,
    pass: bool,
    done: bool,
    /// Whole tCK added to the lane write, two's complement.
    write_latency: i2,
    reserved: u24,
};

pub const LaneTaps = packed struct(u32) {
    write_dqs: u8,
    gate: u8,
    read_dqs: u8,
    write_dq: u8,
};

const Reg = enum(usize) {
    cmd = 0x00,
    status = 0x04,
    result_sel = 0x14,
    result = 0x18,
    taps = 0x1c,
};

/// Status reads before the FSBL stops a wait. The controller has its own
/// cycle bound on the training run, so this limit only catches a window that
/// does not answer.
pub const poll_max: u32 = 1 << 28;

pub const Error = error{ Timeout, Rejected, Failed };

pub fn Window(comptime Bus: type) type {
    return struct {
        bus: Bus,
        base: usize,
        polls: u32 = poll_max,

        const Self = @This();

        pub fn status(self: Self) Status {
            return @bitCast(self.read(.status));
        }

        /// Starts the hardware sequence when the controller waits for firmware,
        /// then waits until the bus is released. A build that trains with no
        /// firmware start only gets the wait.
        pub fn train(self: Self) Error!Status {
            var s = try self.waitFor(startable);
            if (s.state == .firmware and !s.released) {
                self.write(.cmd, @backingInt(Cmd.run_hw));
                if (self.status().reject) return error.Rejected;
                s = try self.waitFor(finished);
            }
            if (s.failed) return error.Failed;
            return s;
        }

        pub fn lane(self: Self, rank: u1, index: u3) struct { result: LaneResult, taps: LaneTaps } {
            self.write(.result_sel, @as(u32, rank) << 8 | index);
            return .{ .result = @bitCast(self.read(.result)), .taps = @bitCast(self.read(.taps)) };
        }

        fn startable(s: Status) bool {
            return s.state == .firmware or finished(s);
        }

        fn finished(s: Status) bool {
            return s.released and (s.done or s.failed);
        }

        fn waitFor(self: Self, comptime ready: fn (Status) bool) Error!Status {
            for (0..self.polls) |_| {
                const s = self.status();
                if (ready(s)) return s;
            }
            return error.Timeout;
        }

        fn read(self: Self, reg: Reg) u32 {
            return self.bus.read32(self.base + @backingInt(reg));
        }

        fn write(self: Self, reg: Reg, value: u32) void {
            self.bus.write32(self.base + @backingInt(reg), value);
        }
    };
}

pub const Mmio = struct {
    pub fn read32(_: Mmio, addr: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(addr)).*;
    }

    pub fn write32(_: Mmio, addr: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(addr)).* = value;
    }
};

const Fake = struct {
    const Mode = enum { firmware_start, auto, fail, reject, dead };

    mode: Mode,
    reads: u32 = 0,
    started: bool = false,
    sel: u32 = 0,

    fn statusWord(self: *Fake) u32 {
        self.reads += 1;
        var s: Status = @bitCast(@as(u32, 0));
        switch (self.mode) {
            .dead => return 0,
            .reject => {
                s.state = .firmware;
                s.reject = self.started;
            },
            .firmware_start, .fail => {
                // The run ends a few reads after the start.
                s.state = if (!self.started) .firmware else .gate;
                if (self.started and self.reads > 5) {
                    s.released = true;
                    s.attempts = 1;
                    if (self.mode == .fail) {
                        s.failed = true;
                        s.state = .failed;
                        s.fail_code = .gate_no_window;
                        s.fail_lane = 1;
                    } else {
                        s.done = true;
                        s.state = .done;
                    }
                }
            },
            .auto => {
                s.state = if (self.reads > 3) .done else .wrlvl;
                s.released = self.reads > 3;
                s.done = self.reads > 3;
            },
        }
        return @bitCast(s);
    }

    pub fn read32(self: *Fake, addr: usize) u32 {
        return switch (@as(Reg, @fromBackingInt(@intCast(addr)))) {
            .status => self.statusWord(),
            .result => 0x10,
            .taps => 0x0a0b0c0d,
            else => 0,
        };
    }

    pub fn write32(self: *Fake, addr: usize, value: u32) void {
        switch (@as(Reg, @fromBackingInt(@intCast(addr)))) {
            .cmd => {
                std.debug.assert(value == @backingInt(Cmd.run_hw));
                std.debug.assert(!self.started);
                self.started = true;
            },
            .result_sel => self.sel = value,
            else => unreachable,
        }
    }
};

fn fakeWindow(fake: *Fake) Window(*Fake) {
    return .{ .bus = fake, .base = 0, .polls = 1000 };
}

test "the status word has the field layout of the window" {
    const s: Status = @bitCast(@as(u32, 0x03a1_e00e));
    try std.testing.expect(s.released and s.done and s.failed and !s.busy);
    try std.testing.expectEqual(State.firmware, s.state);
    try std.testing.expectEqual(@as(u4, 1), s.attempts);
    try std.testing.expectEqual(Fail.watchdog, s.fail_code);
    try std.testing.expectEqual(@as(u3, 3), s.fail_lane);
}

test "a firmware start build trains after the run command" {
    var fake: Fake = .{ .mode = .firmware_start };
    const s = try fakeWindow(&fake).train();
    try std.testing.expect(fake.started);
    try std.testing.expect(s.done and s.released);
}

test "a build that trains by itself gets no command" {
    var fake: Fake = .{ .mode = .auto };
    const s = try fakeWindow(&fake).train();
    try std.testing.expect(!fake.started);
    try std.testing.expect(s.done);
}

test "a failed run gives the fail code" {
    var fake: Fake = .{ .mode = .fail };
    const w = fakeWindow(&fake);
    try std.testing.expectError(error.Failed, w.train());
    const s = w.status();
    try std.testing.expectEqual(Fail.gate_no_window, s.fail_code);
    try std.testing.expectEqualStrings("gate_no_window", s.fail_code.name());
}

test "a rejected command stops the training" {
    var fake: Fake = .{ .mode = .reject };
    try std.testing.expectError(error.Rejected, fakeWindow(&fake).train());
}

test "a window that does not answer times out" {
    var fake: Fake = .{ .mode = .dead };
    try std.testing.expectError(error.Timeout, fakeWindow(&fake).train());
    try std.testing.expectEqual(@as(u32, 1000), fake.reads);
}

test "a lane read selects the lane and rank" {
    var fake: Fake = .{ .mode = .auto };
    const r = fakeWindow(&fake).lane(1, 2);
    try std.testing.expectEqual(@as(u32, 0x102), fake.sel);
    try std.testing.expect(r.result.pass);
    try std.testing.expectEqual(@as(u8, 0x0d), r.taps.write_dqs);
    try std.testing.expectEqual(@as(u8, 0x0a), r.taps.write_dq);
}
