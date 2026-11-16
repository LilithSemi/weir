//! Driver for the write port of the Harbor SPI flash controller.
//!
//! A hardware engine does the write enable, the erase or page program, and the
//! status poll. Weir and Linux share the register block, so a claim register
//! decides who may start an operation.

const std = @import("std");

pub const sector_size = 4096;
pub const page_size = 256;

pub const Regs = extern struct {
    /// Operation in bits 1:0, go in bit 31.
    ctrl: u32,
    /// 24-bit flash offset.
    addr: u32,
    /// 1 to 256, program only.
    len: u32,
    /// Bit 0 busy, bit 1 done, bit 2 err (write 1 to clear), bit 3 locked.
    status: u32,
    /// Bit N locks partition N. A write ORs into the mask.
    lock_mask: u32,
    _reserved: [2]u32,
    /// A read takes the claim if it is free and gives 1, else 0. A write of 1 releases it.
    claim: u32,
    _pad: [0x100 - 0x20]u8,
    /// Page buffer, word addressed.
    page: [page_size / 4]u32,
};

comptime {
    std.debug.assert(@sizeOf(Regs) == 0x200);
    std.debug.assert(@offsetOf(Regs, "claim") == 0x1c);
    std.debug.assert(@offsetOf(Regs, "page") == 0x100);
}

const op_erase: u32 = 1;
const op_program: u32 = 2;
const ctrl_go: u32 = 1 << 31;
const status_busy: u32 = 1 << 0;
const status_done: u32 = 1 << 1;
const status_err: u32 = 1 << 2;

pub const claim_retries = 100000;
/// The engine has its own timeout and ends a healthy wait first.
/// This limit only guards against a dead controller.
pub const busy_retries = 50_000_000;

const flash_limit: usize = 1 << 24;

/// Volatile 32-bit access at a fixed base address.
pub const Mmio = struct {
    base: usize,

    pub fn read32(self: *Mmio, off: usize) u32 {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        return ptr.*;
    }

    pub fn write32(self: *Mmio, off: usize, v: u32) void {
        const ptr: *volatile u32 = @ptrFromInt(self.base + off);
        ptr.* = v;
    }
};

pub fn Driver(comptime Bus: type) type {
    return struct {
        const Self = @This();

        bus: *Bus,
        claim_limit: u32 = claim_retries,
        busy_limit: u32 = busy_retries,
        /// Set when the engine stayed busy past the limit. The claim stays taken and no call writes a register.
        dead: bool = false,

        pub fn eraseSector(self: *Self, off: u32) bool {
            if (off >= flash_limit) return false;
            if (!self.takeClaim()) return false;
            defer self.releaseIfAlive();
            self.start(off);
            return self.finish(op_erase);
        }

        /// Writes `bytes` at `off` one page at a time. A page that fails stops the call.
        pub fn program(self: *Self, off: u32, bytes: []const u8) bool {
            const end = std.math.add(usize, off, bytes.len) catch return false;
            if (end > flash_limit or self.dead) return false;
            var done: usize = 0;
            while (done < bytes.len) {
                const at: u32 = off + @as(u32, @intCast(done));
                const room = page_size - (at & (page_size - 1));
                const chunk = bytes[done..][0..@min(room, bytes.len - done)];
                if (!self.programPage(at, chunk)) return false;
                done += chunk.len;
            }
            return true;
        }

        /// Adds `mask` to the set of locked partitions.
        pub fn lock(self: *Self, mask: u32) bool {
            if (!self.takeClaim()) return false;
            defer self.releaseIfAlive();
            self.bus.write32(@offsetOf(Regs, "lock_mask"), mask);
            return true;
        }

        pub fn lockMask(self: *Self) u32 {
            return self.bus.read32(@offsetOf(Regs, "lock_mask"));
        }

        fn programPage(self: *Self, off: u32, chunk: []const u8) bool {
            std.debug.assert(chunk.len >= 1 and chunk.len <= page_size);
            if (!self.takeClaim()) return false;
            defer self.releaseIfAlive();
            self.start(off);
            self.bus.write32(@offsetOf(Regs, "len"), @intCast(chunk.len));
            var i: usize = 0;
            while (i < chunk.len) : (i += 4) {
                var word: [4]u8 = @splat(0xff);
                const n = @min(4, chunk.len - i);
                @memcpy(word[0..n], chunk[i..][0..n]);
                self.bus.write32(@offsetOf(Regs, "page") + i, std.mem.readInt(u32, &word, .little));
            }
            return self.finish(op_program);
        }

        fn takeClaim(self: *Self) bool {
            if (self.dead) return false;
            var tries: u32 = 0;
            while (tries < self.claim_limit) : (tries += 1) {
                if (self.bus.read32(@offsetOf(Regs, "claim")) == 1) return true;
            }
            return false;
        }

        fn releaseIfAlive(self: *Self) void {
            if (!self.dead) self.releaseClaim();
        }

        fn releaseClaim(self: *Self) void {
            self.bus.write32(@offsetOf(Regs, "claim"), 1);
        }

        fn start(self: *Self, off: u32) void {
            self.bus.write32(@offsetOf(Regs, "status"), status_err);
            self.bus.write32(@offsetOf(Regs, "addr"), off);
        }

        fn finish(self: *Self, op: u32) bool {
            self.bus.write32(@offsetOf(Regs, "ctrl"), op | ctrl_go);
            var tries: u32 = 0;
            while (tries < self.busy_limit) : (tries += 1) {
                const status = self.bus.read32(@offsetOf(Regs, "status"));
                if (status & status_busy != 0) continue;
                return status & status_done != 0 and status & status_err == 0;
            }
            self.dead = true;
            return false;
        }
    };
}

const status_locked: u32 = 1 << 3;

const Model = struct {
    const Write = struct { off: usize, value: u32 };
    const partitions = [_]struct { start: u32, end: u32 }{
        .{ .start = 0, .end = 4096 },
        .{ .start = 4096, .end = 8192 },
        .{ .start = 8192, .end = 16384 },
    };

    flash: [16384]u8 = @splat(0xff),
    ctrl: u32 = 0,
    addr: u32 = 0,
    len: u32 = 0,
    status: u32 = 0,
    lock_mask: u32 = 0,
    page: [64]u32 = @splat(0),
    claimed: bool = false,
    other_owner: bool = false,
    stay_busy: bool = false,
    force_err: bool = false,
    /// Status reads that see busy before an operation takes effect.
    busy_polls: u32 = 3,
    pending: bool = false,
    wait: u32 = 0,
    takes: u32 = 0,
    releases: u32 = 0,
    ops: u32 = 0,
    log: [512]Write = undefined,
    log_len: usize = 0,

    fn read32(self: *Model, off: usize) u32 {
        switch (off) {
            @offsetOf(Regs, "status") => {
                self.settle();
                return self.status;
            },
            @offsetOf(Regs, "lock_mask") => return self.lock_mask,
            @offsetOf(Regs, "claim") => {
                if (self.claimed or self.other_owner) return 0;
                self.claimed = true;
                self.takes += 1;
                return 1;
            },
            else => unreachable,
        }
    }

    fn write32(self: *Model, off: usize, v: u32) void {
        self.log[self.log_len] = .{ .off = off, .value = v };
        self.log_len += 1;
        switch (off) {
            @offsetOf(Regs, "ctrl") => {
                self.ctrl = v;
                if (v & ctrl_go != 0) {
                    self.ops += 1;
                    self.pending = true;
                    self.wait = self.busy_polls;
                    self.status = (self.status & ~status_done) | status_busy;
                }
            },
            @offsetOf(Regs, "addr") => self.addr = v,
            @offsetOf(Regs, "len") => self.len = v,
            @offsetOf(Regs, "status") => {
                if (v & status_err != 0) self.status &= ~(status_err | status_locked);
            },
            @offsetOf(Regs, "lock_mask") => self.lock_mask |= v,
            @offsetOf(Regs, "claim") => {
                std.debug.assert(self.claimed);
                self.claimed = false;
                self.releases += 1;
            },
            else => {
                std.debug.assert(off >= @offsetOf(Regs, "page"));
                self.page[(off - @offsetOf(Regs, "page")) / 4] = v;
            },
        }
    }

    fn overlapsLocked(self: *Model, start: u32, end: u32) bool {
        for (partitions, 0..) |p, n| {
            if (self.lock_mask >> @intCast(n) & 1 != 0 and start < p.end and end > p.start) return true;
        }
        return false;
    }

    fn settle(self: *Model) void {
        if (!self.pending or self.stay_busy) return;
        if (self.wait > 0) {
            self.wait -= 1;
            return;
        }
        self.pending = false;
        const op = self.ctrl & 3;
        const start = if (op == op_erase) self.addr & ~@as(u32, sector_size - 1) else self.addr;
        const span: u32 = if (op == op_erase) sector_size else self.len;
        self.status = (self.status & ~status_busy) | status_done;
        if (self.force_err) {
            self.status |= status_err;
        } else if (self.overlapsLocked(start, start + span)) {
            self.status |= status_err | status_locked;
        } else if (op == op_program and (self.addr & 0xff) + self.len > page_size) {
            self.status |= status_err;
        } else if (op == op_erase) {
            @memset(self.flash[start..][0..sector_size], 0xff);
        } else {
            for (0..self.len) |i| {
                const word: [4]u8 = @bitCast(self.page[i / 4]);
                self.flash[start + i] &= word[i % 4];
            }
        }
    }
};

const TestDriver = Driver(Model);

fn testDriver(model: *Model) TestDriver {
    return .{ .bus = model, .claim_limit = 10, .busy_limit = 10 };
}

test "Regs size and offsets" {
    try std.testing.expectEqual(0x200, @sizeOf(Regs));
    try std.testing.expectEqual(0x00, @offsetOf(Regs, "ctrl"));
    try std.testing.expectEqual(0x0c, @offsetOf(Regs, "status"));
    try std.testing.expectEqual(0x10, @offsetOf(Regs, "lock_mask"));
    try std.testing.expectEqual(0x1c, @offsetOf(Regs, "claim"));
    try std.testing.expectEqual(0x100, @offsetOf(Regs, "page"));
}

test "the Mmio bus compiles with the driver" {
    const D = Driver(Mmio);
    _ = &D.eraseSector;
    _ = &D.program;
    _ = &D.lock;
    _ = &D.lockMask;
}

test "erase clears one sector and nothing else" {
    var model: Model = .{};
    @memset(model.flash[0..], 0x00);
    var d = testDriver(&model);
    try std.testing.expect(d.eraseSector(0x1234));
    for (model.flash, 0..) |b, i| {
        const want: u8 = if (i >= 0x1000 and i < 0x2000) 0xff else 0x00;
        try std.testing.expectEqual(want, b);
    }
    try std.testing.expectEqual(1, model.takes);
    try std.testing.expectEqual(1, model.releases);
}

test "600 byte program splits at pages with one claim per operation" {
    var model: Model = .{};
    var data: [600]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var d = testDriver(&model);
    try std.testing.expect(d.program(0x1f0, &data));
    try std.testing.expectEqualSlices(u8, &data, model.flash[0x1f0..][0..600]);
    try std.testing.expectEqual(0xff, model.flash[0x1ef]);
    try std.testing.expectEqual(0xff, model.flash[0x1f0 + 600]);
    try std.testing.expectEqual(4, model.ops);
    try std.testing.expectEqual(4, model.takes);
    try std.testing.expectEqual(4, model.releases);
}

test "5 byte program pads the last word and keeps neighbours" {
    var model: Model = .{};
    model.flash[0x21] = 0x5a;
    model.flash[0x27] = 0xa5;
    var d = testDriver(&model);
    try std.testing.expect(d.program(0x22, &.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqualSlices(u8, &.{ 0x5a, 1, 2, 3, 4, 5, 0xa5 }, model.flash[0x21..][0..7]);
    try std.testing.expectEqual(0xffffff05, model.page[1]);
    try std.testing.expectEqual(5, model.len);
}

test "forced err fails both operations, releases the claim and the next operation clears err first" {
    var model: Model = .{};
    model.force_err = true;
    var d = testDriver(&model);
    try std.testing.expect(!d.program(0, &.{1}));
    try std.testing.expect(!d.eraseSector(0));
    try std.testing.expectEqual(2, model.takes);
    try std.testing.expectEqual(2, model.releases);
    try std.testing.expect(!model.claimed);

    model.force_err = false;
    model.log_len = 0;
    try std.testing.expect(d.eraseSector(0));
    try std.testing.expectEqual(@offsetOf(Regs, "status"), model.log[0].off);
    try std.testing.expectEqual(status_err, model.log[0].value);
}

test "a forced err after a good operation fails the call" {
    var model: Model = .{};
    var d = testDriver(&model);
    try std.testing.expect(d.eraseSector(0));
    model.force_err = true;
    try std.testing.expect(!d.eraseSector(0x1000));
    try std.testing.expect(!d.program(0, &.{1}));
    try std.testing.expect(!model.claimed);
}

test "a stale done bit does not end the wait for the next operation" {
    var model: Model = .{};
    model.busy_polls = 5;
    var d = testDriver(&model);
    try std.testing.expect(d.program(0, &.{0x0f}));
    try std.testing.expect(model.status & status_done != 0);
    try std.testing.expect(d.program(0, &.{0xf0}));
    try std.testing.expectEqual(0x00, model.flash[0]);
    model.force_err = true;
    try std.testing.expect(!d.eraseSector(0));
    try std.testing.expectEqual(0x00, model.flash[0]);
}

test "a controller that stays busy kills the driver and keeps the claim" {
    var model: Model = .{};
    model.stay_busy = true;
    var d = testDriver(&model);
    try std.testing.expect(!d.eraseSector(0));
    try std.testing.expect(d.dead);
    try std.testing.expect(model.claimed);
    try std.testing.expectEqual(0, model.releases);

    const writes = model.log_len;
    try std.testing.expect(!d.eraseSector(0));
    try std.testing.expect(!d.program(0, &.{1}));
    try std.testing.expect(!d.lock(1));
    try std.testing.expectEqual(writes, model.log_len);
    try std.testing.expectEqual(0, d.lockMask());
}

test "a held claim fails the erase and writes no register" {
    var model: Model = .{};
    model.other_owner = true;
    var d = testDriver(&model);
    try std.testing.expect(!d.eraseSector(0));
    try std.testing.expect(!d.program(0, &.{1}));
    try std.testing.expect(!d.lock(1));
    try std.testing.expectEqual(0, model.log_len);
    try std.testing.expect(!d.dead);
}

test "lock adds to the mask and a locked partition refuses an erase" {
    var model: Model = .{};
    var d = testDriver(&model);
    try std.testing.expect(d.lock(0b101));
    try std.testing.expect(d.lock(0b010));
    try std.testing.expectEqual(0b111, d.lockMask());
    try std.testing.expect(!d.eraseSector(0x1000));
    try std.testing.expect(model.status & status_locked != 0);
    try std.testing.expect(!d.program(0x2000, &.{1}));
    try std.testing.expectEqual(0xff, model.flash[0x2000]);
    try std.testing.expect(!model.claimed);
}

test "a refused erase leaves the flash content unchanged" {
    var model: Model = .{};
    @memset(model.flash[0x1000..0x2000], 0x12);
    var d = testDriver(&model);
    try std.testing.expect(d.lock(0b010));
    try std.testing.expect(!d.eraseSector(0x1800));
    try std.testing.expect(model.status & status_locked != 0);
    for (model.flash[0x1000..0x2000]) |b| try std.testing.expectEqual(0x12, b);
}

test "an unlocked partition still erases while another is locked" {
    var model: Model = .{};
    var d = testDriver(&model);
    try std.testing.expect(d.lock(0b100));
    try std.testing.expect(d.eraseSector(0x1000));
}

test "an erase offset outside 24 bits writes no register" {
    var model: Model = .{};
    var d = testDriver(&model);
    try std.testing.expect(!d.eraseSector(1 << 24));
    try std.testing.expectEqual(0, model.log_len);
    try std.testing.expectEqual(0, model.takes);
}

test "a program range outside 24 bits writes no register" {
    var model: Model = .{};
    var d = testDriver(&model);
    try std.testing.expect(!d.program((1 << 24) - 1, &.{ 1, 2 }));
    try std.testing.expect(!d.program(std.math.maxInt(u32), &.{ 1, 2 }));
    try std.testing.expectEqual(0, model.log_len);
    try std.testing.expectEqual(0, model.takes);
}

test "the engine rejects a program that crosses a page" {
    var model: Model = .{};
    _ = model.read32(@offsetOf(Regs, "claim"));
    model.write32(@offsetOf(Regs, "addr"), 0xf0);
    model.write32(@offsetOf(Regs, "len"), 32);
    model.write32(@offsetOf(Regs, "ctrl"), op_program | ctrl_go);
    var status: u32 = status_busy;
    while (status & status_busy != 0) status = model.read32(@offsetOf(Regs, "status"));
    try std.testing.expect(status & status_err != 0);
    try std.testing.expectEqual(0xff, model.flash[0xf0]);
}
