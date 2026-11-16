//! The EFI variable services. They copy the arguments into the request block
//! and make the SBI variable call. An OS calls them after ExitBootServices from
//! its own page tables, with only the runtime region mapped. So they use only
//! `.rt_text`, `.rt_data` and the buffers of the caller. tools/rtcheck.zig
//! checks this at build time.

const std = @import("std");
const uefi = std.os.uefi;
const rt_abi = @import("../var/rt_abi.zig");

const Status = uefi.Status;
const Result = rt_abi.Result;

/// `.rt_data` is no-load, so an initial value here would be lost. `prepare` fills the table.
pub var table: uefi.tables.RuntimeServices linksection(".rt_data") = undefined; // zippy:ignore unsafe_undefined
/// No initial value: `.rt_data` is no-load, and each call fills the fields that M-mode reads.
/// Callers must serialise their calls. M-mode refuses a second caller but cannot protect the block.
pub var block: rt_abi.Request align(8) linksection(".rt_data") = undefined; // zippy:ignore unsafe_undefined

extern const __rt_text_start: u8;
extern const __rt_text_end: u8;
extern const __rt_data_start: u8;
extern const __rt_data_end: u8;

pub const Bounds = struct {
    text_start: usize,
    text_end: usize,
    data_start: usize,
    data_end: usize,
};

pub fn bounds() Bounds {
    return .{
        .text_start = symbolAddress(&__rt_text_start),
        .text_end = symbolAddress(&__rt_text_end),
        .data_start = symbolAddress(&__rt_data_start),
        .data_end = symbolAddress(&__rt_data_end),
    };
}

/// The optimiser takes two different symbols to have different addresses, and
/// so can fold `text_end == data_start` to false. The asm hides the address from it.
inline fn symbolAddress(symbol: *const u8) usize {
    return asm ("mv %[address], %[symbol]"
        : [address] "=r" (-> usize),
        : [symbol] "r" (symbol),
    );
}

fn errorBit() usize {
    return 1 << 63;
}

/// The EFI status code of each `Result`, 4 bits for each value.
fn statusCodes() u64 {
    var codes: u64 = 0;
    for (std.enums.values(Result)) |r| {
        const status: Status = switch (r) {
            .success => .success,
            .not_found => .not_found,
            .buffer_too_small => .buffer_too_small,
            .invalid => .invalid_parameter,
            .out_of_resources => .out_of_resources,
            .device_error => .device_error,
        };
        const code = @backingInt(status) & ~errorBit();
        if (code > 0xf) @compileError("an EFI status code does not fit in 4 bits");
        codes |= @as(u64, code) << (4 * @backingInt(r));
    }
    return codes;
}

// Runtime safety stays off in this file, because a safety check calls the
// panic handler in `.text`. The code also has no optionals, switches or
// tables, because they can put data in `.rodata`. The volatile copies stop
// the compiler from making memcpy calls out of the loops.

inline fn statusOf(result: u32) usize {
    @setRuntimeSafety(false);
    if (result >= std.enums.values(Result).len) return @backingInt(Status.device_error);
    const code = (comptime statusCodes()) >> @intCast(4 * result) & 0xf;
    return if (code == 0) 0 else (comptime errorBit()) | code;
}

inline fn isResult(result: u32, comptime expected: Result) bool {
    return result == @backingInt(expected);
}

inline fn copyBytes(dest: [*]volatile u8, src: [*]const volatile u8, len: usize) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < len) : (i += 1) dest[i] = src[i];
}

inline fn copyUnits(dest: [*]volatile u16, src: [*]const volatile u16, len: usize) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < len) : (i += 1) dest[i] = src[i];
}

/// Copies `name` and its terminator into the block, reading at most `limit`
/// units. Gives the units copied, or 0 when no terminator is in the limit.
inline fn putName(name: [*]const volatile u16, limit: usize) usize {
    @setRuntimeSafety(false);
    const dest: [*]volatile u16 = &block.name;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const unit = name[i];
        dest[i] = unit;
        if (unit == 0) return i + 1;
    }
    return 0;
}

/// Runs the request in the block. Gives 0 when it ran, else the EFI status for
/// the SBI error. `no_store` is the status when there is no store.
inline fn call(op: rt_abi.Op, comptime no_store: Status) usize {
    @setRuntimeSafety(false);
    block.op = @backingInt(op);
    var value: usize = undefined;
    const err = asm volatile ("ecall"
        : [err] "={x10}" (-> usize),
          [value] "={x11}" (value),
        : [addr] "{x10}" (@intFromPtr(&block)),
          [fid] "{x16}" (rt_abi.fid_call),
          [eid] "{x17}" (rt_abi.eid),
        : .{ .memory = true });
    if (err == 0) return 0;
    const not_supported: usize = @bitCast(@as(isize, -2));
    if (err == not_supported) return @backingInt(no_store);
    return @backingInt(Status.device_error);
}

pub fn getVariable(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attributes: ?*u32,
    data_size: *usize,
    data: ?[*]u8,
) linksection(".rt_text") callconv(.c) usize {
    @setRuntimeSafety(false);
    const units = putName(name, rt_abi.max_name_units);
    if (units == 0) return @backingInt(Status.not_found);
    copyBytes(&block.guid, guid, 16);
    const size = data_size.*;
    block.name_size = units * 2;
    block.data_size = if (data == null) 0 else @min(size, rt_abi.max_data_len);
    const sbi_status = call(.get, .not_found);
    if (sbi_status != 0) return sbi_status;

    const result = block.status;
    if (isResult(result, .success) or isResult(result, .buffer_too_small)) {
        const len: usize = @intCast(@min(block.data_size, rt_abi.max_data_len));
        if (attributes) |a| a.* = block.attributes;
        if (isResult(result, .success)) {
            if (data) |d| copyBytes(d, &block.data, @min(len, size));
        }
        data_size.* = len;
    }
    return statusOf(result);
}

pub fn setVariable(
    name: [*:0]const u16,
    guid: *const [16]u8,
    attributes: u32,
    data_size: usize,
    data: ?[*]const u8,
) linksection(".rt_text") callconv(.c) usize {
    @setRuntimeSafety(false);
    const units = putName(name, rt_abi.max_name_units);
    if (units == 0) return @backingInt(Status.out_of_resources);
    copyBytes(&block.guid, guid, 16);
    block.name_size = units * 2;
    block.attributes = attributes;
    // A size or attributes of 0 removes the variable and carries no data.
    // M-mode refuses a size past the block.
    const write = attributes != 0 and data_size != 0;
    block.data_size = if (write) data_size else 0;
    if (write and data_size <= rt_abi.max_data_len) {
        const src = data orelse return @backingInt(Status.invalid_parameter);
        copyBytes(&block.data, src, data_size);
    }
    const sbi_status = call(.set, .unsupported);
    if (sbi_status != 0) return sbi_status;
    return statusOf(block.status);
}

pub fn getNextVariableName(
    name_size: *usize,
    name: [*:0]u16,
    guid: *[16]u8,
) linksection(".rt_text") callconv(.c) usize {
    @setRuntimeSafety(false);
    const size = name_size.*;
    if (putName(name, @min(size / 2, rt_abi.max_name_units)) == 0) return @backingInt(Status.invalid_parameter);
    copyBytes(&block.guid, guid, 16);
    block.name_size = size;
    const sbi_status = call(.next, .not_found);
    if (sbi_status != 0) return sbi_status;

    const result = block.status;
    if (isResult(result, .success) or isResult(result, .buffer_too_small)) {
        const bytes: usize = @intCast(@min(block.name_size, rt_abi.max_name_units * 2));
        if (isResult(result, .success)) {
            copyUnits(name, &block.name, @min(bytes, size) / 2);
            copyBytes(guid, &block.guid, 16);
        }
        name_size.* = bytes;
    }
    return statusOf(result);
}

pub fn queryVariableInfo(
    attributes: u32,
    max_storage: *u64,
    remaining: *u64,
    max_var: *u64,
) linksection(".rt_text") callconv(.c) usize {
    @setRuntimeSafety(false);
    _ = attributes;
    const sbi_status = call(.query, .unsupported);
    if (sbi_status != 0) return sbi_status;
    max_storage.* = block.max_storage;
    remaining.* = block.remaining;
    max_var.* = block.max_var;
    return statusOf(block.status);
}

pub fn unsupported() linksection(".rt_text") callconv(.c) usize {
    return @backingInt(Status.unsupported);
}

// The exports keep the stubs in every image that holds the request block, so
// the runtime region never has data with no code.
comptime {
    @export(&getVariable, .{ .name = "weir_rt_get_variable" });
    @export(&setVariable, .{ .name = "weir_rt_set_variable" });
    @export(&getNextVariableName, .{ .name = "weir_rt_get_next_variable_name" });
    @export(&queryVariableInfo, .{ .name = "weir_rt_query_variable_info" });
    @export(&unsupported, .{ .name = "weir_rt_unsupported" });
}

/// Applies the store rules for the time after ExitBootServices. With no store
/// there are no rules to apply.
pub fn seal() void {
    _ = call(.seal, .unsupported);
}

/// True for the table entries that stay after ExitBootServices.
pub fn keepsAtRuntime(comptime field: []const u8) bool {
    const kept = [_][]const u8{ "_getVariable", "_setVariable", "_getNextVariableName", "_queryVariableInfo" };
    var found = false;
    for (kept) |k| {
        if (!@hasField(uefi.tables.RuntimeServices, k)) @compileError("RuntimeServices has no field " ++ k);
        if (std.mem.eql(u8, k, field)) found = true;
    }
    return found;
}
