//! The request block of the SBI variable call. M-mode and S-mode share this layout.

const std = @import("std");

pub const eid: usize = 0x0A575249;
pub const fid_call: usize = 0;

pub const max_name_units = 256;
pub const max_data_len = 32 * 1024;

pub const Op = enum(u32) { get = 1, set = 2, next = 3, query = 4, seal = 5 };

/// The values are part of the ABI.
pub const Result = enum(u32) {
    success = 0,
    not_found = 1,
    buffer_too_small = 2,
    invalid = 3,
    out_of_resources = 4,
    device_error = 5,
};

pub const Request = extern struct {
    op: u32,
    status: u32,
    attributes: u32,
    _pad: u32,
    data_size: u64,
    name_size: u64,
    max_storage: u64,
    remaining: u64,
    max_var: u64,
    guid: [16]u8,
    name: [max_name_units]u16,
    data: [max_data_len]u8,
};

comptime {
    std.debug.assert(@offsetOf(Request, "status") == 4);
    std.debug.assert(@offsetOf(Request, "attributes") == 8);
    std.debug.assert(@offsetOf(Request, "data_size") == 16);
    std.debug.assert(@offsetOf(Request, "name_size") == 24);
    std.debug.assert(@offsetOf(Request, "max_storage") == 32);
    std.debug.assert(@offsetOf(Request, "remaining") == 40);
    std.debug.assert(@offsetOf(Request, "max_var") == 48);
    std.debug.assert(@offsetOf(Request, "guid") == 56);
    std.debug.assert(@offsetOf(Request, "name") == 72);
    std.debug.assert(@offsetOf(Request, "data") == 584);
    std.debug.assert(@sizeOf(Request) == 584 + max_data_len);
    std.debug.assert(@alignOf(Request) == 8);
    // The name is read as u16 units.
    std.debug.assert(@offsetOf(Request, "name") % @alignOf(u16) == 0);
    // The u64 fields are at multiples of 8.
    for (.{ "data_size", "name_size", "max_storage", "remaining", "max_var" }) |field| {
        std.debug.assert(@offsetOf(Request, field) % @alignOf(u64) == 0);
    }
}

/// The units of `name` with the terminator, when it ends inside `name_size` bytes and inside the array.
pub fn nameUnits(name: *const [max_name_units]u16, name_size: u64) ?usize {
    const limit: usize = @intCast(@min(name_size / 2, max_name_units));
    for (name[0..limit], 0..) |unit, i| {
        if (unit == 0) return i + 1;
    }
    return null;
}

/// Checks the name like `nameUnits`, then writes the terminator again at the
/// checked position. A write from another hart after the check cannot remove it.
pub fn terminateName(name: *[max_name_units]u16, name_size: u64) ?usize {
    const units = nameUnits(name, name_size) orelse return null;
    name[units - 1] = 0;
    return units;
}

/// The size of data that the block carries, or null when `data_size` is too large.
pub fn dataLen(data_size: u64) ?usize {
    if (data_size > max_data_len) return null;
    return @intCast(data_size);
}

/// Reads a field one time. Another hart can write the block while M-mode runs.
fn once(comptime T: type, field: *const T) T {
    const view: *const volatile T = field;
    return view.*;
}

fn namePtr(req: *Request) [*:0]u16 {
    return @ptrCast(&req.name);
}

/// Runs the request in `req` on the store `S` and writes the result into the block.
/// The caller holds the lock and has checked that `req` is the block.
pub fn execute(comptime S: type, req: *Request) void {
    const result: Result = if (std.enums.fromInt(Op, once(u32, &req.op))) |op| switch (op) {
        .get => get(S, req),
        .set => set(S, req),
        .next => next(S, req),
        .query => query(S, req),
        .seal => seal(S),
    } else .invalid;
    req.status = @backingInt(result);
}

fn get(comptime S: type, req: *Request) Result {
    const name_size = once(u64, &req.name_size);
    const data_size = once(u64, &req.data_size);
    _ = terminateName(&req.name, name_size) orelse return .invalid;
    var size: usize = @intCast(@min(data_size, max_data_len));
    var attributes: u32 = 0;
    const result = S.get(namePtr(req), &req.guid, &attributes, &size, &req.data);
    switch (result) {
        .success, .buffer_too_small => {
            if (size > max_data_len) return .device_error;
            req.attributes = attributes;
            req.data_size = size;
        },
        else => {},
    }
    return result;
}

fn set(comptime S: type, req: *Request) Result {
    const name_size = once(u64, &req.name_size);
    const data_size = once(u64, &req.data_size);
    const attributes = once(u32, &req.attributes);
    _ = terminateName(&req.name, name_size) orelse return .invalid;
    const len = dataLen(data_size) orelse return .invalid;
    return S.set(namePtr(req), &req.guid, attributes, len, &req.data);
}

fn next(comptime S: type, req: *Request) Result {
    var size: usize = @intCast(@min(once(u64, &req.name_size), max_name_units * 2));
    const result = S.next(&size, namePtr(req), &req.guid);
    switch (result) {
        .success, .buffer_too_small => req.name_size = size,
        else => {},
    }
    return result;
}

fn query(comptime S: type, req: *Request) Result {
    S.queryInfo(&req.max_storage, &req.remaining, &req.max_var);
    return .success;
}

fn seal(comptime S: type) Result {
    S.seal();
    return .success;
}

const testing = std.testing;

const Fake = struct {
    var calls: u32 = 0;
    var sealed = false;
    var buffer_len: usize = 0;
    var set_len: usize = 0;
    var result: Result = .success;
    var needed: usize = 0;
    var attributes: u32 = 0;
    var name_bytes: usize = 0;

    fn reset() void {
        calls = 0;
        sealed = false;
        buffer_len = 0;
        set_len = 0;
        result = .success;
        needed = 0;
        attributes = 0;
        name_bytes = 0;
    }

    pub fn get(name: [*:0]const u16, guid: *const [16]u8, attrs: ?*u32, data_size: *usize, data: ?[*]u8) Result {
        _ = name;
        _ = guid;
        calls += 1;
        buffer_len = data_size.*;
        if (attrs) |a| a.* = attributes;
        switch (result) {
            .success => {
                data.?[0] = 0xab;
                data_size.* = needed;
            },
            .buffer_too_small => data_size.* = needed,
            else => {},
        }
        return result;
    }

    pub fn set(name: [*:0]const u16, guid: *const [16]u8, attrs: u32, data_size: usize, data: ?[*]const u8) Result {
        _ = name;
        _ = guid;
        _ = data;
        calls += 1;
        attributes = attrs;
        set_len = data_size;
        return result;
    }

    pub fn next(name_size: *usize, name: [*:0]u16, guid: *[16]u8) Result {
        _ = guid;
        calls += 1;
        name_bytes = name_size.*;
        if (result == .success) {
            name[0] = 'Q';
            name[1] = 0;
            name_size.* = 4;
        }
        return result;
    }

    pub fn queryInfo(max_storage: *u64, remaining: *u64, max_var: *u64) void {
        calls += 1;
        max_storage.* = 100;
        remaining.* = 60;
        max_var.* = 32;
    }

    pub fn seal() void {
        calls += 1;
        sealed = true;
    }
};

fn newRequest(op: u32) !*Request {
    const req = try testing.allocator.create(Request);
    req.* = std.mem.zeroes(Request);
    req.op = op;
    Fake.reset();
    return req;
}

fn setName(req: *Request, comptime text: []const u8) void {
    for (text, 0..) |c, i| req.name[i] = c;
    req.name[text.len] = 0;
    req.name_size = (text.len + 1) * 2;
}

test "the result values are part of the ABI" {
    try testing.expectEqual(@as(u32, 0), @backingInt(Result.success));
    try testing.expectEqual(@as(u32, 1), @backingInt(Result.not_found));
    try testing.expectEqual(@as(u32, 2), @backingInt(Result.buffer_too_small));
    try testing.expectEqual(@as(u32, 3), @backingInt(Result.invalid));
    try testing.expectEqual(@as(u32, 4), @backingInt(Result.out_of_resources));
    try testing.expectEqual(@as(u32, 5), @backingInt(Result.device_error));
}

test "nameUnits finds the terminator inside name_size" {
    var name: [max_name_units]u16 = @splat(0);
    name[0] = 'A';
    name[1] = 'b';
    try testing.expectEqual(@as(?usize, 3), nameUnits(&name, 6));
    try testing.expectEqual(@as(?usize, 3), nameUnits(&name, 512));
    try testing.expectEqual(@as(?usize, 3), nameUnits(&name, 7));
}

test "nameUnits gives null when name_size ends before the terminator" {
    var name: [max_name_units]u16 = @splat(0);
    name[0] = 'A';
    name[1] = 'b';
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, 4));
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, 0));
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, 1));
}

test "nameUnits gives null when the array has no terminator" {
    const name: [max_name_units]u16 = @splat('x');
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, std.math.maxInt(u64)));
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, 512));
}

test "dataLen accepts up to the array size" {
    try testing.expectEqual(@as(?usize, 0), dataLen(0));
    try testing.expectEqual(@as(?usize, max_data_len), dataLen(max_data_len));
    try testing.expectEqual(@as(?usize, null), dataLen(max_data_len + 1));
    try testing.expectEqual(@as(?usize, null), dataLen(std.math.maxInt(u64)));
}

test "an unknown op gives invalid and calls no store function" {
    const req = try newRequest(0);
    defer testing.allocator.destroy(req);
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.invalid), req.status);
    req.op = 6;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.invalid), req.status);
    try testing.expectEqual(@as(u32, 0), Fake.calls);
}

test "get with an unterminated name gives invalid" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.name_size = 6;
    req.data_size = 8;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.invalid), req.status);
    try testing.expectEqual(@as(u32, 0), Fake.calls);
}

test "get copies the size and attributes out" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.data_size = 16;
    Fake.needed = 4;
    Fake.attributes = 0x7;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.success), req.status);
    try testing.expectEqual(@as(u64, 4), req.data_size);
    try testing.expectEqual(@as(u32, 0x7), req.attributes);
    try testing.expectEqual(@as(u8, 0xab), req.data[0]);
}

test "get passes the smaller of data_size and the array as the buffer" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.data_size = 100_000;
    Fake.needed = 4;
    execute(Fake, req);
    try testing.expectEqual(@as(usize, max_data_len), Fake.buffer_len);
    req.data_size = 10;
    execute(Fake, req);
    try testing.expectEqual(@as(usize, 10), Fake.buffer_len);
}

test "get gives the needed size when the buffer is too small" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.data_size = 2;
    Fake.result = .buffer_too_small;
    Fake.needed = 300;
    Fake.attributes = 0x3;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.buffer_too_small), req.status);
    try testing.expectEqual(@as(u64, 300), req.data_size);
    try testing.expectEqual(@as(u32, 0x3), req.attributes);
}

test "get of a variable larger than the array gives device_error" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.data_size = 100_000;
    Fake.result = .buffer_too_small;
    Fake.needed = max_data_len + 1;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.device_error), req.status);
}

test "get of a missing variable gives the store result" {
    const req = try newRequest(@backingInt(Op.get));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.data_size = 8;
    Fake.result = .not_found;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.not_found), req.status);
    try testing.expectEqual(@as(u64, 8), req.data_size);
}

test "set passes the attributes and size and gives the store result" {
    const req = try newRequest(@backingInt(Op.set));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.attributes = 0x7;
    req.data_size = 5;
    Fake.result = .out_of_resources;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.out_of_resources), req.status);
    try testing.expectEqual(@as(u32, 0x7), Fake.attributes);
    try testing.expectEqual(@as(usize, 5), Fake.set_len);
}

test "set with data_size past the array gives invalid" {
    const req = try newRequest(@backingInt(Op.set));
    defer testing.allocator.destroy(req);
    setName(req, "Boot");
    req.attributes = 0x7;
    req.data_size = max_data_len + 1;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.invalid), req.status);
    try testing.expectEqual(@as(u32, 0), Fake.calls);
}

test "set with an unterminated name gives invalid" {
    const req = try newRequest(@backingInt(Op.set));
    defer testing.allocator.destroy(req);
    req.name = @splat('x');
    req.name_size = 512;
    req.attributes = 0x7;
    req.data_size = 1;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.invalid), req.status);
    try testing.expectEqual(@as(u32, 0), Fake.calls);
}

test "next gives the name and its size" {
    const req = try newRequest(@backingInt(Op.next));
    defer testing.allocator.destroy(req);
    req.name_size = 2;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.success), req.status);
    try testing.expectEqual(@as(u64, 4), req.name_size);
    try testing.expectEqual(@as(u16, 'Q'), req.name[0]);
}

test "next clamps name_size to the name array" {
    const req = try newRequest(@backingInt(Op.next));
    defer testing.allocator.destroy(req);
    req.name_size = 1 << 40;
    execute(Fake, req);
    try testing.expectEqual(@as(usize, max_name_units * 2), Fake.name_bytes);
}

test "next at the end leaves name_size and gives the store result" {
    const req = try newRequest(@backingInt(Op.next));
    defer testing.allocator.destroy(req);
    req.name_size = 2;
    Fake.result = .not_found;
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.not_found), req.status);
    try testing.expectEqual(@as(u64, 2), req.name_size);
}

test "query fills the three sizes" {
    const req = try newRequest(@backingInt(Op.query));
    defer testing.allocator.destroy(req);
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.success), req.status);
    try testing.expectEqual(@as(u64, 100), req.max_storage);
    try testing.expectEqual(@as(u64, 60), req.remaining);
    try testing.expectEqual(@as(u64, 32), req.max_var);
}

test "seal calls the store seal and succeeds" {
    const req = try newRequest(@backingInt(Op.seal));
    defer testing.allocator.destroy(req);
    execute(Fake, req);
    try testing.expectEqual(@backingInt(Result.success), req.status);
    try testing.expect(Fake.sealed);
}

test "terminateName gives the units and keeps the terminator at the checked position" {
    var name: [max_name_units]u16 = @splat('x');
    name[0] = 'A';
    name[1] = 'b';
    name[2] = 0;
    try testing.expectEqual(@as(?usize, 3), terminateName(&name, 512));
    try testing.expectEqual(@as(u16, 0), name[2]);
    try testing.expectEqual(@as(u16, 'x'), name[3]);
}

test "terminateName changes nothing when the name has no terminator in name_size" {
    var name: [max_name_units]u16 = @splat('x');
    name[3] = 0;
    try testing.expectEqual(@as(?usize, null), terminateName(&name, 6));
    const expected: [max_name_units]u16 = blk: {
        var e: [max_name_units]u16 = @splat('x');
        e[3] = 0;
        break :blk e;
    };
    try testing.expectEqualSlices(u16, &expected, &name);
}
