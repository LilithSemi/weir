//! EFI_TCG2_PROTOCOL: lets a boot loader / OS measure what it loads into the TPM,
//! append to the event log Weir started, and read it back for attestation.
//! Backed by our TPM driver and event log (tpm.zig).

const std = @import("std");
const uefi = std.os.uefi;
const tpm = @import("tpm.zig");
const tpm2 = @import("tpm2.zig");
const handledb = @import("../uefi/handledb.zig");

const Status = uefi.Status;
const ok = @intFromEnum(Status.success);

// EFI_TCG2_PROTOCOL_GUID 607f766c-7455-42be-930b-e4d76db2720f.
pub const TCG2_GUID = uefi.Guid{
    .time_low = 0x607f766c,
    .time_mid = 0x7455,
    .time_high_and_version = 0x42be,
    .clock_seq_high_and_reserved = 0x93,
    .clock_seq_low = 0x0b,
    .node = .{ 0xe4, 0xd7, 0x6d, 0xb2, 0x72, 0x0f },
};

const HASH_ALG_SHA256: u32 = 0x00000002;
const EVENT_LOG_FORMAT_TCG_2: u32 = 0x00000002;

const Protocol = extern struct {
    getCapability: *const anyopaque,
    getEventLog: *const anyopaque,
    hashLogExtendEvent: *const anyopaque,
    submitCommand: *const anyopaque,
    getActivePcrBanks: *const anyopaque,
    setActivePcrBanks: *const anyopaque,
    getResultOfSetActivePcrBanks: *const anyopaque,
};

const BootServiceCapability = extern struct {
    size: u8,
    structure_version: [2]u8,
    protocol_version: [2]u8,
    hash_algorithm_bitmap: u32,
    supported_event_logs: u32,
    tpm_present_flag: u8,
    max_command_size: u16,
    max_response_size: u16,
    manufacturer_id: u32,
    number_of_pcr_banks: u32,
    active_pcr_banks: u32,
};

var proto: Protocol = undefined;

fn getCapability(_: *Protocol, cap: *BootServiceCapability) callconv(.c) usize {
    cap.size = @sizeOf(BootServiceCapability);
    cap.structure_version = .{ 1, 1 };
    cap.protocol_version = .{ 1, 1 };
    cap.hash_algorithm_bitmap = HASH_ALG_SHA256;
    cap.supported_event_logs = EVENT_LOG_FORMAT_TCG_2;
    cap.tpm_present_flag = if (tpm.isAvailable()) 1 else 0;
    cap.max_command_size = 4096;
    cap.max_response_size = 4096;
    cap.manufacturer_id = 0;
    cap.number_of_pcr_banks = 1;
    cap.active_pcr_banks = HASH_ALG_SHA256;
    return ok;
}

fn getEventLog(_: *Protocol, format: u32, log_loc: *u64, last_entry: *u64, truncated: *bool) callconv(.c) usize {
    if (format != EVENT_LOG_FORMAT_TCG_2) return @intFromEnum(Status.invalid_parameter);
    log_loc.* = tpm.eventLogStart();
    last_entry.* = tpm.eventLogLastEntry();
    truncated.* = tpm.logTruncated();
    return ok;
}

// EFI_TCG2_EVENT is packed: Size(u32) Header{HeaderSize(u32) HeaderVersion(u16)
// PCRIndex(u32) EventType(u32)} Event[]. PCRIndex at 10, EventType at 14, data
// at 18.
const HLEE_EXTEND_ONLY: u64 = 0x0000000000000001;

fn hashLogExtendEvent(_: *Protocol, flags: u64, data: u64, data_len: u64, event: [*]u8) callconv(.c) usize {
    if (!tpm.isAvailable()) return @intFromEnum(Status.device_error);
    const size = std.mem.readInt(u32, event[0..4], .little);
    if (size < 18) return @intFromEnum(Status.invalid_parameter);
    const pcr = std.mem.readInt(u32, event[10..14], .little);
    const event_type = std.mem.readInt(u32, event[14..18], .little);
    const event_data = event[18..size];

    var digest: [tpm2.SHA256_LEN]u8 = undefined;
    tpm.hash(@as([*]const u8, @ptrFromInt(@as(usize, @intCast(data))))[0..@intCast(data_len)], &digest);

    const want_log = flags & HLEE_EXTEND_ONLY == 0;
    if (want_log) {
        if (!tpm.logExtend(pcr, event_type, &digest, event_data)) return @intFromEnum(Status.device_error);
    } else {
        if (!tpm.extendOnly(pcr, &digest)) return @intFromEnum(Status.device_error);
    }
    return ok;
}

fn submitCommand(_: *Protocol, in_size: u32, in_block: [*]u8, out_size: u32, out_block: [*]u8) callconv(.c) usize {
    if (tpm2.submit(in_block[0..in_size], out_block[0..out_size]) == null) return @intFromEnum(Status.device_error);
    return ok;
}

fn getActivePcrBanks(_: *Protocol, banks: *u32) callconv(.c) usize {
    banks.* = HASH_ALG_SHA256;
    return ok;
}

fn setActivePcrBanks(_: *Protocol, banks: u32) callconv(.c) usize {
    _ = banks;
    return ok;
}

fn getResultOfSetActivePcrBanks(_: *Protocol, op1: *u32, op2: *u32) callconv(.c) usize {
    op1.* = 0;
    op2.* = 0;
    return ok;
}

/// Install EFI_TCG2_PROTOCOL on a fresh handle so a boot loader can locate it.
pub fn install() void {
    proto = .{
        .getCapability = @ptrFromInt(@intFromPtr(&getCapability)),
        .getEventLog = @ptrFromInt(@intFromPtr(&getEventLog)),
        .hashLogExtendEvent = @ptrFromInt(@intFromPtr(&hashLogExtendEvent)),
        .submitCommand = @ptrFromInt(@intFromPtr(&submitCommand)),
        .getActivePcrBanks = @ptrFromInt(@intFromPtr(&getActivePcrBanks)),
        .setActivePcrBanks = @ptrFromInt(@intFromPtr(&setActivePcrBanks)),
        .getResultOfSetActivePcrBanks = @ptrFromInt(@intFromPtr(&getResultOfSetActivePcrBanks)),
    };
    _ = handledb.install(null, &TCG2_GUID, @ptrCast(&proto));
}
