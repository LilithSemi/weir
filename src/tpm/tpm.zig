//! Measured boot front end. Brings up the TPM and measures boot components:
//! each is SHA-256 hashed and extended into a PCR, forming an unforgeable record
//! of what ran. Also keeps an event log handed to the OS via EFI_TCG2_PROTOCOL.

const std = @import("std");
const tis = @import("tis.zig");
const tpm2 = @import("tpm2.zig");
const console = @import("../console/console.zig");
const platform = @import("../platform.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

// Standard PCR assignments we use.
pub const PCR_FIRMWARE = 0; // firmware / FSBL stage measurements
pub const PCR_BOOT_LOADER = 4; // the boot loader / boot attempt
pub const PCR_BOOT_CONFIG = 5; // boot configuration / command line
pub const PCR_DEBUG = 16; // resettable debug PCR (self-test)

// TCG event types we emit.
pub const EV_POST_CODE: u32 = 0x00000001;
pub const EV_NO_ACTION: u32 = 0x00000003;
pub const EV_IPL: u32 = 0x0000000d;
pub const EV_EFI_BOOT_SERVICES_APPLICATION: u32 = 0x80000003;

var available = false;

// TCG2 crypto-agile event log (EFI_TCG2_EVENT_LOG_FORMAT_TCG_2): a legacy-format
// Spec ID Event declaring the SHA-256 bank, then TCG_PCR_EVENT2 entries. Defaults
// to a static buffer but is repointed at the ACPI TPM2 table's log area
// (setLogArea) so the OS finds it via that table.
var evlog_static: [16384]u8 = undefined;
var log_buf: []u8 = &evlog_static;
var evlog_len: usize = 0;
var last_entry: usize = 0;
// Set if an event ever failed to fit: the PCR was still extended, so the log no
// longer fully accounts for the PCRs. Reported to the OS via TCG2 GetEventLog's
// `truncated` flag so attestation does not rely on an incomplete log.
var log_truncated = false;

/// Point the event log at a platform-designated area (the TPM2 table's LASA), so
/// the OS reads Weir's measurements through the standard ACPI mechanism. Must be
/// called before init().
pub fn setLogArea(addr: usize, len: usize) void {
    if (len < 512 or addr == 0) return; // implausible: keep the static buffer
    log_buf = @as([*]u8, @ptrFromInt(addr))[0..len];
}

fn logU32(v: u32) void {
    std.mem.writeInt(u32, log_buf[evlog_len..][0..4], v, .little);
    evlog_len += 4;
}
fn logBytes(b: []const u8) void {
    @memcpy(log_buf[evlog_len..][0..b.len], b);
    evlog_len += b.len;
}

/// Write the Spec ID Event (TCG_PCR_EVENT legacy header) that opens the log.
fn initLog() void {
    evlog_len = 0;
    log_truncated = false;
    logU32(0); // pcrIndex
    logU32(EV_NO_ACTION); // eventType
    logBytes(&[_]u8{0} ** 20); // SHA1 digest field (zero)
    // eventSize + TCG_EfiSpecIdEvent
    const spec_size: u32 = 16 + 4 + 4 + 4 + (2 + 2) + 1; // sig+class+ver+count+1 alg+vendorlen
    logU32(spec_size);
    logBytes("Spec ID Event03\x00"); // signature[16]
    logU32(0); // platformClass
    log_buf[evlog_len] = 0; // specVersionMinor
    log_buf[evlog_len + 1] = 2; // specVersionMajor
    log_buf[evlog_len + 2] = 0; // specErrata
    log_buf[evlog_len + 3] = 2; // uintnSize: 64-bit
    evlog_len += 4;
    logU32(1); // numberOfAlgorithms
    std.mem.writeInt(u16, log_buf[evlog_len..][0..2], tpm2.ALG_SHA256, .little);
    std.mem.writeInt(u16, log_buf[evlog_len + 2 ..][0..2], tpm2.SHA256_LEN, .little);
    evlog_len += 4;
    log_buf[evlog_len] = 0; // vendorInfoSize
    evlog_len += 1;
}

/// Append a TCG_PCR_EVENT2 for an already-computed digest.
fn appendEvent(pcr: u32, event_type: u32, digest: *const [tpm2.SHA256_LEN]u8, event: []const u8) void {
    // Bound check header(<=64) + digest + event. On overflow mark the log
    // truncated rather than drop silently: the PCR is extended, so the OS must
    // know the log is incomplete.
    if (evlog_len + 64 + tpm2.SHA256_LEN + event.len > log_buf.len) {
        log_truncated = true;
        return;
    }
    last_entry = evlog_len;
    logU32(pcr);
    logU32(event_type);
    logU32(1); // TPML_DIGEST_VALUES count
    std.mem.writeInt(u16, log_buf[evlog_len..][0..2], tpm2.ALG_SHA256, .little);
    evlog_len += 2;
    logBytes(digest);
    logU32(@intCast(event.len));
    logBytes(event);
}

pub fn eventLogStart() usize {
    return @intFromPtr(log_buf.ptr);
}
pub fn eventLogLastEntry() usize {
    return @intFromPtr(log_buf.ptr) + last_entry;
}
pub fn eventLogLen() usize {
    return evlog_len;
}

/// True if any event did not fit the log buffer (PCRs extended beyond what the
/// log records). The OS reads this through the TCG2 GetEventLog `truncated` flag.
pub fn logTruncated() bool {
    return log_truncated;
}

fn printHex(d: []const u8) void {
    for (d) |b| console.printf("{x:0>2}", .{b});
}

/// Bring up the TPM. Measured boot is best-effort: with no TPM (e.g. a board
/// without Albion's secure element yet) it simply stays disabled.
pub fn init() void {
    // Only touch the TPM if the platform advertises one: probing an unmapped bus
    // faults.
    if (!platform.tpmPresent()) {
        console.writeStr("[tpm] no TPM in platform description; measured boot disabled\n");
        return;
    }
    tis.setBase(platform.tpmBase());
    if (!tis.present()) {
        console.writeStr("[tpm] TPM advertised but not responding; measured boot disabled\n");
        return;
    }
    if (!tpm2.startup()) {
        console.writeStr("[tpm] startup failed; measured boot disabled\n");
        return;
    }
    available = true;
    initLog();
    console.writeStr("[tpm] TPM 2.0 ready; measured boot active\n");
}

pub fn isAvailable() bool {
    return available;
}

/// Extend a precomputed digest into `pcr` and append a log entry. Shared by the
/// firmware's own measurements and the EFI_TCG2 HashLogExtendEvent path.
pub fn logExtend(pcr: u32, event_type: u32, digest: *const [tpm2.SHA256_LEN]u8, event: []const u8) bool {
    if (!available) return false;
    if (!tpm2.pcrExtend(pcr, digest)) return false;
    appendEvent(pcr, event_type, digest, event);
    return true;
}

/// Record a measurement an earlier stage (the FSBL) already extended into a PCR,
/// adding only the log entry so the event log accounts for the PCR's value.
pub fn recordPrior(pcr: u32, event_type: u32, digest: *const [tpm2.SHA256_LEN]u8, desc: []const u8) void {
    if (!available) return;
    appendEvent(pcr, event_type, digest, desc);
    console.printf("[tpm] {s} measured by earlier stage -> PCR{d} sha256:", .{ desc, pcr });
    printHex(digest[0..8]);
    console.writeStr("...\n");
}

/// Extend a digest into a PCR without adding a log entry (TCG2 EXTEND_ONLY).
pub fn extendOnly(pcr: u32, digest: *const [tpm2.SHA256_LEN]u8) bool {
    if (!available) return false;
    return tpm2.pcrExtend(pcr, digest);
}

/// Measure `data` into `pcr`: hash it, extend the PCR, log the event.
pub fn measure(pcr: u32, data: []const u8, desc: []const u8) void {
    measureTyped(pcr, EV_EFI_BOOT_SERVICES_APPLICATION, data, desc);
}

pub fn measureTyped(pcr: u32, event_type: u32, data: []const u8, desc: []const u8) void {
    if (!available) return;
    var digest: [tpm2.SHA256_LEN]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    if (!logExtend(pcr, event_type, &digest, desc)) {
        console.printf("[tpm] PCR{d} extend failed for {s}\n", .{ pcr, desc });
        return;
    }
    console.printf("[tpm] measured {s} ({d} bytes) -> PCR{d} sha256:", .{ desc, data.len, pcr });
    printHex(digest[0..8]);
    console.writeStr("...\n");
}

/// Hash `data` with SHA-256 into `out` (for the protocol's hash helpers).
pub fn hash(data: []const u8, out: *[tpm2.SHA256_LEN]u8) void {
    Sha256.hash(data, out, .{});
}

extern var __rodata_end: u8;

/// Measure Weir's own image (code + rodata) into PCR 0. Ideally the FSBL/mask ROM
/// measures Weir before running it; self-measurement anchors the chain until that
/// lands.
pub fn measureSelf(ram_base: usize) void {
    if (!available) return;
    const end = @intFromPtr(&__rodata_end);
    if (end <= ram_base) return;
    const img = @as([*]const u8, @ptrFromInt(ram_base))[0 .. end - ram_base];
    measureTyped(PCR_FIRMWARE, EV_POST_CODE, img, "weir firmware");
}

/// Extend a known value and read it back, proving hash+extend+read end to end.
pub fn selfTest() void {
    if (!available) return;
    measure(PCR_DEBUG, "Weir measured-boot self-test", "self-test");
    var pcr: [tpm2.SHA256_LEN]u8 = undefined;
    if (tpm2.pcrRead(PCR_DEBUG, &pcr)) {
        console.writeStr("[tpm] PCR16 readback sha256:");
        printHex(pcr[0..8]);
        console.writeStr("...\n");
    } else {
        console.writeStr("[tpm] PCR read failed\n");
    }
}
