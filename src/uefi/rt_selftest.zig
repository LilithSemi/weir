//! A test of the EFI variable services from the view of an OS. It runs as an
//! EFI application in S-mode, calls ExitBootServices, then turns on an Sv39
//! page table that maps only the runtime region and this test, at virtual
//! equals physical, and calls the services through the runtime services table.
//! It prints through the SBI debug console and stops the machine at the end.

const std = @import("std");
const build_options = @import("build_options");
const efi = @import("../var/efi.zig");

const uefi = std.os.uefi;
const tables = uefi.tables;
const Status = uefi.Status;
const RuntimeServices = tables.RuntimeServices;
const VariableAttributes = RuntimeServices.VariableAttributes;

const Step = enum {
    set_variables,
    persistence,
    exit_boot_services,
    page_table,
    get_runtime,
    get_small_buffer,
    get_boot_only,
    set_runtime,
    get_updated,
    set_no_runtime,
    walk_names,
    query_info,
    get_time,
};

const runtime_attributes = efi.non_volatile | efi.boot_service_access | efi.runtime_access;
const boot_attributes = efi.non_volatile | efi.boot_service_access;

/// The value in gp and tp while the services run. It is not canonical in Sv39, so a use faults.
const poison: usize = 0xdead_0000_0bad_0000;

/// Everything the test touches while paging is on. Its section is no-load, so `start` fills it.
const Data = extern struct {
    stack: [16 * 1024]u8 align(16),
    fault_stack: [2 * 1024]u8 align(16),
    guid: [16]u8 align(8),
    walk_guid: [16]u8 align(8),
    counter_name: [counter_name_literal.len:0]u16,
    boot_only_name: [boot_only_name_literal.len:0]u16,
    no_runtime_name: [no_runtime_name_literal.len:0]u16,
    walk_name: [256]u16,
    time: uefi.Time,
    digits: [20]u8,
    step: u32,
    previous: u32,
    value: u32,
    attributes: u32,
};

const counter_name_literal = std.unicode.utf8ToUtf16LeStringLiteral("RtSelfTestBoots");
const boot_only_name_literal = std.unicode.utf8ToUtf16LeStringLiteral("RtSelfTestBootOnly");
const no_runtime_name_literal = std.unicode.utf8ToUtf16LeStringLiteral("RtSelfTestNoRuntime");

var data: Data linksection(".selftest_data") = undefined; // zippy:ignore unsafe_undefined

extern const __selftest_text_start: u8;
extern const __selftest_text_end: u8;
extern const __selftest_data_start: u8;
extern const __selftest_data_end: u8;

pub fn imageBase() usize {
    return @intFromPtr(&__selftest_text_start);
}

pub fn imageSize() usize {
    return @intFromPtr(&__selftest_data_end) - @intFromPtr(&__selftest_text_start);
}

comptime {
    if (build_options.rt_selftest) @export(&faultReport, .{ .name = "weirRtSelfTestFault" });
}

// Output and stop through SBI calls only. Every helper is inline or in
// `.selftest_text`, and the text goes out one character at a time from
// immediates, so nothing reads `.rodata`.

inline fn putChar(c: usize) void {
    asm volatile ("ecall"
        :
        : [c] "{x10}" (c),
          [fid] "{x16}" (2),
          [eid] "{x17}" (0x4442434E),
        : .{ .x10 = true, .x11 = true, .memory = true });
}

inline fn say(comptime text: []const u8) void {
    @setEvalBranchQuota(10_000);
    inline for (text) |c| putChar(c);
}

fn sayHex(value: usize) linksection(".selftest_text") void {
    @setRuntimeSafety(false);
    var i: usize = 16;
    var started = false;
    while (i > 0) {
        i -= 1;
        const nibble = (value >> @intCast(i * 4)) & 0xf;
        if (nibble != 0 or started or i == 0) {
            started = true;
            putChar(if (nibble < 10) '0' + nibble else 'a' - 10 + nibble);
        }
    }
}

fn sayDecimal(value: u32) linksection(".selftest_text") void {
    @setRuntimeSafety(false);
    const digits: [*]volatile u8 = &data.digits;
    var n = value;
    var len: usize = 0;
    while (true) {
        digits[len] = @intCast('0' + n % 10);
        len += 1;
        n /= 10;
        if (n == 0) break;
    }
    while (len > 0) {
        len -= 1;
        putChar(digits[len]);
    }
}

fn sayStep(step: u32) linksection(".selftest_text") void {
    @setRuntimeSafety(false);
    inline for (std.enums.values(Step)) |s| {
        if (step == hidden(@backingInt(s))) say(@tagName(s));
    }
}

/// Hides a constant from the optimiser, so a chain of compares does not become
/// a jump table in `.rodata`.
inline fn hidden(value: u32) u32 {
    return asm ("mv %[out], %[in]"
        : [out] "=r" (-> u32),
        : [in] "r" (value),
    );
}

inline fn stop() noreturn {
    asm volatile ("ecall"
        :
        : [kind] "{x10}" (0),
          [reason] "{x11}" (0),
          [fid] "{x16}" (0),
          [eid] "{x17}" (0x53525354),
        : .{ .x10 = true, .x11 = true, .memory = true });
    while (true) asm volatile ("wfi");
}

fn fail(step: Step, status: Status) linksection(".selftest_text") noreturn {
    @setRuntimeSafety(false);
    say("[rt] self-test: fail at ");
    sayStep(@backingInt(step));
    say(", status ");
    sayHex(@backingInt(status));
    say("\n");
    stop();
}

inline fn begin(comptime step: Step) void {
    @as(*volatile u32, &data.step).* = @backingInt(step);
}

inline fn unitsEqual(a: [*]const volatile u16, b: [*]const volatile u16, len: usize) bool {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

inline fn guidEqual(a: *const volatile [16]u8, b: *const volatile [16]u8) bool {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

inline fn guidPtr(g: *align(8) [16]u8) *uefi.Guid {
    return @ptrCast(g);
}

inline fn attributesOf(value: u32) VariableAttributes {
    return @bitCast(value);
}

/// The EFI entry point. Weir starts it in S-mode with paging off.
pub fn start(image: uefi.Handle, system: *tables.SystemTable) callconv(.c) noreturn {
    data.guid = efi.weir_guid;
    data.counter_name = counter_name_literal.*;
    data.boot_only_name = boot_only_name_literal.*;
    data.no_runtime_name = no_runtime_name_literal.*;

    const rs = system.runtime_services;
    begin(.set_variables);
    var size: usize = 4;
    var status = rs._getVariable(&data.counter_name, guidPtr(&data.guid), null, &size, @ptrCast(&data.value));
    if (status == .not_found) {
        data.previous = 0;
    } else if (status == .success and size == 4) {
        data.previous = data.value;
    } else {
        fail(.set_variables, status);
    }
    // The boot only variable of an earlier run exists when that run also wrote the counter, before it.
    var probe: usize = 4;
    const earlier = rs._getVariable(&data.boot_only_name, guidPtr(&data.guid), null, &probe, @ptrCast(&data.value));
    if (earlier != .not_found and earlier != .success) fail(.set_variables, earlier);
    if (earlier == .success and status == .not_found) fail(.persistence, status);
    data.value = data.previous;
    status = rs._setVariable(&data.counter_name, guidPtr(&data.guid), attributesOf(runtime_attributes), 4, @ptrCast(&data.value));
    if (status != .success) fail(.set_variables, status);
    status = rs._setVariable(&data.boot_only_name, guidPtr(&data.guid), attributesOf(boot_attributes), 4, @ptrCast(&data.value));
    if (status != .success) fail(.set_variables, status);

    begin(.exit_boot_services);
    const bs = system.boot_services orelse fail(.exit_boot_services, .invalid_parameter);
    var map_size: usize = map_buffer.len;
    var map_key: tables.MemoryMapKey = undefined;
    var desc_size: usize = 0;
    var desc_version: u32 = 0;
    status = bs._getMemoryMap(&map_size, &map_buffer, &map_key, &desc_size, &desc_version);
    if (status != .success or desc_size < @sizeOf(tables.MemoryDescriptor)) fail(.exit_boot_services, status);
    status = bs._exitBootServices(image, map_key);
    if (status != .success) fail(.exit_boot_services, status);

    begin(.page_table);
    const root = newTable() orelse fail(.page_table, .out_of_resources);
    var offset: usize = 0;
    while (offset + desc_size <= map_size) : (offset += desc_size) {
        const desc: *align(8) const tables.MemoryDescriptor = @ptrCast(@alignCast(&map_buffer[offset]));
        if (@as(u64, @bitCast(desc.attribute)) & (1 << 63) == 0) continue;
        const flags: u64 = if (desc.type == .runtime_services_code) pte_r | pte_x else pte_r | pte_w;
        const end = desc.physical_start + desc.number_of_pages * page_size;
        mapRange(root, desc.physical_start, end, flags);
    }
    mapRange(root, @intFromPtr(&__selftest_text_start), @intFromPtr(&__selftest_text_end), pte_r | pte_x);
    mapRange(root, @intFromPtr(&__selftest_data_start), @intFromPtr(&__selftest_data_end), pte_r | pte_w);

    const satp = 8 << 60 | @intFromPtr(root) >> 12;
    enter(satp, rs, @intFromPtr(&data.stack) + data.stack.len, @intFromPtr(&data.fault_stack) + data.fault_stack.len);
}

const page_size = 4096;
const pte_v: u64 = 1 << 0;
const pte_r: u64 = 1 << 1;
const pte_w: u64 = 1 << 2;
const pte_x: u64 = 1 << 3;
const pte_a: u64 = 1 << 6;
const pte_d: u64 = 1 << 7;

var map_buffer: [4096]u8 align(8) = undefined;
var pool: [8][512]u64 align(page_size) = undefined;
var pool_used: usize = 0;

fn newTable() ?*[512]u64 {
    if (pool_used == pool.len) return null;
    const table = &pool[pool_used];
    pool_used += 1;
    @memset(table, 0);
    return table;
}

/// Maps the pages from `start` to `end` with 4 KiB leaves. A page that is
/// mapped already or a full table pool stops the test.
fn mapRange(root: *[512]u64, start_addr: u64, end: u64, flags: u64) void {
    if (start_addr % page_size != 0 or end % page_size != 0) fail(.page_table, .invalid_parameter);
    say("[rt] self-test: map ");
    sayHex(start_addr);
    say("-");
    sayHex(end);
    if (flags & pte_x != 0) say(" rx\n") else say(" rw\n");
    var addr = start_addr;
    while (addr < end) : (addr += page_size) {
        var table = root;
        var level: u6 = 2;
        while (level > 0) : (level -= 1) {
            const entry = &table[(addr >> (12 + 9 * level)) & 0x1ff];
            if (entry.* & pte_v == 0) {
                const next = newTable() orelse fail(.page_table, .out_of_resources);
                entry.* = (@intFromPtr(next) >> 12) << 10 | pte_v;
            }
            table = @ptrFromInt((entry.* >> 10) << 12);
        }
        const leaf = &table[(addr >> 12) & 0x1ff];
        if (leaf.* & pte_v != 0) fail(.page_table, .invalid_parameter);
        leaf.* = (addr >> 12) << 10 | flags | pte_a | pte_d | pte_v;
    }
}

/// Sets the trap vector, the stack, gp and tp, turns on paging and jumps to `run`.
/// It must stay out of line, because only `.selftest_text` is mapped after the satp write.
noinline fn enter(satp: usize, rs: *RuntimeServices, stack_top: usize, fault_stack_top: usize) linksection(".selftest_text") noreturn {
    @setRuntimeSafety(false);
    asm volatile (
        \\ csrw stvec, t1
        \\ csrw sscratch, t5
        \\ mv sp, t2
        \\ mv gp, t4
        \\ mv tp, t4
        \\ csrw satp, t0
        \\ sfence.vma zero, zero
        \\ jr t3
        :
        : [rs] "{x10}" (rs),
          [satp] "{x5}" (satp),
          [vector] "{x6}" (@intFromPtr(&faultVector)),
          [stack] "{x7}" (stack_top),
          [run] "{x28}" (@intFromPtr(&run)),
          [poison] "{x29}" (poison),
          [fault_stack] "{x30}" (fault_stack_top),
        : .{ .memory = true });
    unreachable;
}

fn faultVector() align(4) linksection(".selftest_text") callconv(.naked) noreturn {
    asm volatile (
        \\ csrrw sp, sscratch, sp
        \\ tail weirRtSelfTestFault
    );
}

/// A fault in the report itself stops the machine.
fn secondFaultVector() align(4) linksection(".selftest_text") callconv(.naked) noreturn {
    asm volatile (
        \\ li a0, 0
        \\ li a1, 0
        \\ li a6, 0
        \\ li a7, 0x53525354
        \\ ecall
        \\ 1: wfi
        \\ j 1b
    );
}

fn faultReport() linksection(".selftest_text") callconv(.c) noreturn {
    @setRuntimeSafety(false);
    asm volatile ("csrw stvec, %[vector]"
        :
        : [vector] "r" (@intFromPtr(&secondFaultVector)),
    );
    const scause = asm volatile ("csrr %[v], scause"
        : [v] "=r" (-> usize),
    );
    const sepc = asm volatile ("csrr %[v], sepc"
        : [v] "=r" (-> usize),
    );
    const stval = asm volatile ("csrr %[v], stval"
        : [v] "=r" (-> usize),
    );
    say("[rt] self-test: fault scause=");
    sayHex(scause);
    say(" sepc=");
    sayHex(sepc);
    say(" stval=");
    sayHex(stval);
    say("\n[rt] self-test: fault in ");
    sayStep(@as(*volatile u32, &data.step).*);
    say("\n");
    stop();
}

/// The checks after ExitBootServices, with paging on and gp and tp unusable.
fn run(rs: *RuntimeServices) linksection(".selftest_text") callconv(.c) noreturn {
    @setRuntimeSafety(false);
    const guid = guidPtr(&data.guid);

    begin(.get_runtime);
    var size: usize = 4;
    data.attributes = 0;
    data.value = std.math.maxInt(u32);
    var status = rs._getVariable(&data.counter_name, guid, @ptrCast(&data.attributes), &size, @ptrCast(&data.value));
    if (status != .success) fail(.get_runtime, status);
    if (size != 4 or data.value != data.previous or data.attributes != runtime_attributes) fail(.get_runtime, status);

    begin(.get_small_buffer);
    size = 1;
    status = rs._getVariable(&data.counter_name, guid, null, &size, @ptrCast(&data.value));
    if (status != .buffer_too_small) fail(.get_small_buffer, status);
    if (size != 4) fail(.get_small_buffer, status);

    begin(.get_boot_only);
    size = 4;
    status = rs._getVariable(&data.boot_only_name, guid, null, &size, @ptrCast(&data.value));
    if (status != .not_found) fail(.get_boot_only, status);

    begin(.set_runtime);
    const boots = data.previous + 1;
    data.value = boots;
    status = rs._setVariable(&data.counter_name, guid, attributesOf(runtime_attributes), 4, @ptrCast(&data.value));
    if (status != .success) fail(.set_runtime, status);

    begin(.get_updated);
    data.value = 0;
    size = 4;
    status = rs._getVariable(&data.counter_name, guid, null, &size, @ptrCast(&data.value));
    if (status != .success) fail(.get_updated, status);
    if (size != 4 or data.value != boots) fail(.get_updated, status);

    begin(.set_no_runtime);
    status = rs._setVariable(&data.no_runtime_name, guid, attributesOf(boot_attributes), 4, @ptrCast(&data.value));
    if (status != .invalid_parameter) fail(.set_no_runtime, status);

    begin(.walk_names);
    data.walk_name[0] = 0;
    var found = false;
    var count: usize = 0;
    while (true) : (count += 1) {
        if (count == data.walk_name.len) fail(.walk_names, .success);
        size = @sizeOf(@TypeOf(data.walk_name));
        status = rs._getNextVariableName(&size, @ptrCast(&data.walk_name), guidPtr(&data.walk_guid));
        if (status == .not_found) break;
        if (status != .success) fail(.walk_names, status);
        if (!guidEqual(&data.walk_guid, &data.guid)) continue;
        if (size == (data.counter_name.len + 1) * 2 and
            unitsEqual(&data.walk_name, &data.counter_name, data.counter_name.len + 1)) found = true;
        if (size == (data.boot_only_name.len + 1) * 2 and
            unitsEqual(&data.walk_name, &data.boot_only_name, data.boot_only_name.len + 1)) fail(.walk_names, status);
    }
    if (!found) fail(.walk_names, status);

    begin(.query_info);
    var max_storage: u64 = 0;
    var remaining: u64 = 0;
    var max_var: u64 = 0;
    status = rs._queryVariableInfo(attributesOf(runtime_attributes), &max_storage, &remaining, &max_var);
    if (status != .success) fail(.query_info, status);
    if (max_storage == 0 or remaining > max_storage) fail(.query_info, status);

    begin(.get_time);
    status = rs._getTime(&data.time, null);
    if (status != .unsupported) fail(.get_time, status);

    say("[rt] self-test: pass, boot ");
    sayDecimal(boots);
    say("\n");
    stop();
}
