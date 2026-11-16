//! The checks of the EFI variable services that do not touch the flash.

const std = @import("std");
const log = @import("log.zig");
const rt_abi = @import("rt_abi.zig");

pub const Result = rt_abi.Result;

comptime {
    if (log.max_name_units != rt_abi.max_name_units or log.max_data_len != rt_abi.max_data_len)
        @compileError("the request block must carry the largest name and data of the log");
}

/// The Weir vendor GUID, 53ad00ad-b655-414a-a2ff-058c0db1659d, in EFI byte order.
pub const weir_guid: [16]u8 = .{ 0xad, 0x00, 0xad, 0x53, 0x55, 0xb6, 0x4a, 0x41, 0xa2, 0xff, 0x05, 0x8c, 0x0d, 0xb1, 0x65, 0x9d };

pub const non_volatile: u32 = log.nv_attribute;
pub const boot_service_access: u32 = 0x2;
pub const runtime_access: u32 = 0x4;

/// Only the three known bits are valid, and runtime access needs boot service access.
pub fn attributesValid(attributes: u32) bool {
    if (attributes & ~(non_volatile | boot_service_access | runtime_access) != 0) return false;
    return attributes & runtime_access == 0 or attributes & boot_service_access != 0;
}

/// The largest data size that one record holds in an empty bank, up to `log.max_data_len`.
/// A record has the header, a name of 2 units and the data.
pub fn maxVarSize(capacity: usize) usize {
    const overhead = log.record_header_len + 2 * 2;
    return @min(log.max_data_len, capacity -| overhead);
}

/// The UTF-16 units of `name` with the terminator, or null when there are more than `limit`.
/// It reads at most `limit` units, because the caller is outside the firmware.
pub fn nameUnits(name: [*:0]const u16, limit: usize) ?usize {
    var n: usize = 0;
    while (n < limit) : (n += 1) {
        if (name[n] == 0) return n + 1;
    }
    return null;
}

/// The units of the previous name that GetNextVariableName gets, with the terminator.
/// The scan stays in the caller's buffer of `name_size` bytes. Null when no terminator is in it.
pub fn nextNameUnits(name: [*:0]const u16, name_size: usize) ?usize {
    return nameUnits(name, @min(name_size / 2, log.max_name_units));
}

pub const SetKind = enum { remove, write, invalid };

/// A size or attributes of 0 removes the variable, whatever the other attribute bits are.
pub fn setKind(attributes: u32, data_size: usize) SetKind {
    if (data_size == 0 or attributes == 0) return .remove;
    return if (attributesValid(attributes)) .write else .invalid;
}

/// After ExitBootServices a variable is visible only when it has runtime access.
pub fn visible(sealed: bool, attributes: u32) bool {
    return !sealed or attributes & runtime_access != 0;
}

/// The previous name of GetNextVariableName must exist, and a sealed store hides it without runtime access.
pub fn nextPrevValid(sealed: bool, existing: ?u32) bool {
    const attributes = existing orelse return false;
    return visible(sealed, attributes);
}

/// The result that a sealed store gives for a `set`, or null when the `set` may go on.
/// `existing` holds the attributes of the variable that the name and GUID find.
pub fn sealedSet(kind: SetKind, attributes: u32, existing: ?u32) ?Result {
    if (kind == .invalid) return .invalid;
    if (existing) |old| {
        if (old & runtime_access == 0) return .invalid;
    }
    const needed = runtime_access | non_volatile;
    if (kind == .write and attributes & needed != needed) return .invalid;
    return null;
}

/// The partitions of a `FlashLock` request that may be locked. The variable
/// partition stays writable, and bits without a partition are dropped.
pub fn lockMask(requested: u32, vars_index: usize, partition_count: usize) u32 {
    var mask = requested;
    if (vars_index < 32) mask &= ~(@as(u32, 1) << @intCast(vars_index));
    if (partition_count < 32) mask &= (@as(u32, 1) << @intCast(partition_count)) - 1;
    return mask;
}

pub fn fromSetError(err: log.SetError) Result {
    return switch (err) {
        error.OutOfResources => .out_of_resources,
        error.DeviceError => .device_error,
        error.InvalidParameter => .invalid,
    };
}

const testing = std.testing;

test "the Weir GUID is in EFI byte order" {
    try testing.expectEqual(@as(u32, 0x53ad00ad), std.mem.readInt(u32, weir_guid[0..4], .little));
    try testing.expectEqual(@as(u16, 0xb655), std.mem.readInt(u16, weir_guid[4..6], .little));
    try testing.expectEqual(@as(u16, 0x414a), std.mem.readInt(u16, weir_guid[6..8], .little));
    try testing.expectEqualSlices(u8, &.{ 0xa2, 0xff, 0x05, 0x8c, 0x0d, 0xb1, 0x65, 0x9d }, weir_guid[8..]);
}

test "only the non-volatile, boot service and runtime bits are valid attributes" {
    try testing.expect(attributesValid(0));
    try testing.expect(attributesValid(0x7));
    try testing.expect(attributesValid(0x3));
    try testing.expect(attributesValid(0x2));
    try testing.expect(!attributesValid(0x8));
    try testing.expect(!attributesValid(0x27));
    try testing.expect(!attributesValid(0x8000_0001));
}

test "runtime access without boot service access is invalid" {
    try testing.expect(!attributesValid(0x4));
    try testing.expect(!attributesValid(0x5));
    try testing.expect(attributesValid(0x6));
    try testing.expectEqual(SetKind.invalid, setKind(0x5, 4));
    try testing.expectEqual(SetKind.write, setKind(0x6, 4));
}

test "maxVarSize is the smaller of the data limit and the room in an empty bank" {
    try testing.expectEqual(@as(usize, log.max_data_len), maxVarSize(1 << 20));
    try testing.expectEqual(@as(usize, 1000 - 36), maxVarSize(1000));
    try testing.expectEqual(@as(usize, 0), maxVarSize(10));
}

test "nameUnits counts the terminator and stops at the limit" {
    const boot = std.unicode.utf8ToUtf16LeStringLiteral("Boot0001");
    try testing.expectEqual(@as(?usize, 9), nameUnits(boot, 256));
    try testing.expectEqual(@as(?usize, 9), nameUnits(boot, 9));
    try testing.expectEqual(@as(?usize, null), nameUnits(boot, 8));
    try testing.expectEqual(@as(?usize, 1), nameUnits(std.unicode.utf8ToUtf16LeStringLiteral(""), 1));
}

test "nameUnits reads no unit past the limit" {
    // No terminator in the first four units. A read of the fifth unit would see the 0 and give 5.
    const name = [_:0]u16{ 'a', 'b', 'c', 'd' };
    try testing.expectEqual(@as(?usize, null), nameUnits(&name, 4));
    try testing.expectEqual(@as(?usize, 5), nameUnits(&name, 5));
}

test "nextNameUnits finds the terminator inside the buffer" {
    const boot = std.unicode.utf8ToUtf16LeStringLiteral("Boot0001");
    try testing.expectEqual(@as(?usize, 9), nextNameUnits(boot, 18));
    try testing.expectEqual(@as(?usize, 9), nextNameUnits(boot, 1024));
    try testing.expectEqual(@as(?usize, 1), nextNameUnits(std.unicode.utf8ToUtf16LeStringLiteral(""), 2));
}

test "nextNameUnits gives null when the buffer ends before the terminator" {
    // The terminator is unit 9, so a 16 or 17 byte buffer does not hold it.
    const boot = std.unicode.utf8ToUtf16LeStringLiteral("Boot0001");
    try testing.expectEqual(@as(?usize, null), nextNameUnits(boot, 16));
    try testing.expectEqual(@as(?usize, null), nextNameUnits(boot, 17));
}

test "nextNameUnits with a buffer of 0 or 1 bytes reads nothing and gives null" {
    try testing.expectEqual(@as(?usize, null), nextNameUnits(std.unicode.utf8ToUtf16LeStringLiteral(""), 0));
    try testing.expectEqual(@as(?usize, null), nextNameUnits(std.unicode.utf8ToUtf16LeStringLiteral(""), 1));
}

test "nextNameUnits stops at the name limit for a large buffer" {
    const long: [log.max_name_units + 1:0]u16 = @splat('a');
    try testing.expectEqual(@as(?usize, null), nextNameUnits(&long, 4096));
}

test "a size or attributes of 0 removes, whatever the other bits are" {
    try testing.expectEqual(SetKind.remove, setKind(0x7, 0));
    try testing.expectEqual(SetKind.remove, setKind(0x8000_0007, 0));
    try testing.expectEqual(SetKind.remove, setKind(0, 4));
    try testing.expectEqual(SetKind.remove, setKind(0, 0));
}

test "a write with bad attribute bits is invalid" {
    try testing.expectEqual(SetKind.write, setKind(0x7, 4));
    try testing.expectEqual(SetKind.write, setKind(0x6, 1));
    try testing.expectEqual(SetKind.invalid, setKind(0x8000_0007, 4));
    try testing.expectEqual(SetKind.invalid, setKind(0x8, 4));
}

test "lockMask clears the variable partition bit" {
    try testing.expectEqual(@as(u32, 0b0111), lockMask(0b1111, 3, 4));
    try testing.expectEqual(@as(u32, 0b1110), lockMask(0b1111, 0, 4));
    try testing.expectEqual(@as(u32, 0), lockMask(0b1000, 3, 4));
}

test "lockMask clears the bits at and above the partition count" {
    try testing.expectEqual(@as(u32, 0b0111), lockMask(0xffff_ffff, 3, 4));
    try testing.expectEqual(@as(u32, 0), lockMask(0xffff_fff0, 3, 4));
    try testing.expectEqual(@as(u32, 0), lockMask(0xffff_ffff, 0, 1));
    try testing.expectEqual(@as(u32, 0), lockMask(0xffff_ffff, 0, 0));
}

test "lockMask keeps bit 31 when there are 32 partitions" {
    try testing.expectEqual(@as(u32, 0xffff_fffe), lockMask(0xffff_ffff, 0, 32));
    try testing.expectEqual(@as(u32, 0x7fff_ffff), lockMask(0xffff_ffff, 31, 32));
}

test "a sealed store hides variables without runtime access" {
    try testing.expect(visible(false, 0x3));
    try testing.expect(!visible(true, 0x3));
    try testing.expect(visible(true, 0x6));
    try testing.expect(visible(true, 0x7));
}

test "a sealed write needs runtime access and the non-volatile attribute" {
    try testing.expectEqual(@as(?Result, null), sealedSet(.write, 0x7, null));
    try testing.expectEqual(@as(?Result, .invalid), sealedSet(.write, 0x3, null));
    try testing.expectEqual(@as(?Result, .invalid), sealedSet(.write, 0x6, null));
    try testing.expectEqual(@as(?Result, .invalid), sealedSet(.invalid, 0x7, null));
}

test "a sealed set of a variable without runtime access is invalid" {
    try testing.expectEqual(@as(?Result, .invalid), sealedSet(.write, 0x7, 0x3));
    try testing.expectEqual(@as(?Result, .invalid), sealedSet(.remove, 0, 0x3));
    try testing.expectEqual(@as(?Result, null), sealedSet(.write, 0x7, 0x7));
    try testing.expectEqual(@as(?Result, null), sealedSet(.write, 0x7, 0x6));
}

test "a sealed remove of a missing or visible variable goes on" {
    try testing.expectEqual(@as(?Result, null), sealedSet(.remove, 0, null));
    try testing.expectEqual(@as(?Result, null), sealedSet(.remove, 0, 0x7));
}

test "a sealed remove of a volatile variable with runtime access goes on" {
    try testing.expectEqual(@as(?Result, null), sealedSet(.remove, 0, 0x6));
}

test "a previous name that is missing or hidden is invalid" {
    try testing.expect(!nextPrevValid(false, null));
    try testing.expect(nextPrevValid(false, 0x3));
    try testing.expect(!nextPrevValid(true, 0x3));
    try testing.expect(nextPrevValid(true, 0x6));
}

test "set errors map to EFI results" {
    try testing.expectEqual(Result.out_of_resources, fromSetError(error.OutOfResources));
    try testing.expectEqual(Result.invalid, fromSetError(error.InvalidParameter));
    try testing.expectEqual(Result.device_error, fromSetError(error.DeviceError));
}
