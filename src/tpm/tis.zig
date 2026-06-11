//! TPM 2.0 TIS (TPM Interface Specification) driver over MMIO. Transport for
//! measured boot: carries TPM2 command/response byte streams. QEMU's
//! `tpm-tis-device` is at 0x0400_0000 on the virt platform bus; on River the
//! address comes from the platform description. Locality 0 only, polled.

const std = @import("std");

// QEMU virt platform-bus TPM TIS base; overridden via setBase from platform
// discovery on real hardware.
var base: usize = 0x04000000;

// TIS register offsets within locality 0.
const ACCESS = 0x0000; // u8
const STS = 0x0018; // u32
const DATA_FIFO = 0x0024; // u8
const DID_VID = 0x0f00; // u32

// TPM_ACCESS bits.
const ACCESS_VALID: u8 = 0x80;
const ACCESS_ACTIVE_LOCALITY: u8 = 0x20;
const ACCESS_REQUEST_USE: u8 = 0x02;

// TPM_STS bits.
const STS_VALID: u32 = 0x80;
const STS_COMMAND_READY: u32 = 0x40;
const STS_GO: u32 = 0x20;
const STS_DATA_AVAIL: u32 = 0x10;
const STS_EXPECT: u32 = 0x08;

const POLL_LIMIT = 2_000_000; // bounded so a missing TPM never hangs the boot

fn r8(off: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(base + off)).*;
}
fn w8(off: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(base + off)).* = v;
}
fn r32(off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}
fn w32(off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}

fn burstCount() u32 {
    // burstCount (STS bits 8-23) is only valid when STS_VALID is set; reading it
    // mid-transition gives stale bits, so report 0 until valid (caller polls via
    // waitBurst).
    const s = r32(STS);
    if (s & STS_VALID == 0) return 0;
    return (s >> 8) & 0xffff;
}

/// Wait until all of `bits` are set in TPM_STS. Returns false on timeout.
fn waitSts(bits: u32) bool {
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (r32(STS) & bits == bits) return true;
    }
    return false;
}

/// Set the TPM's base MMIO address (e.g. from platform discovery).
pub fn setBase(addr: usize) void {
    base = addr;
}

/// Probe for a TPM: request locality 0 and check the interface reports a valid
/// vendor id. Returns false if nothing answers.
pub fn present() bool {
    // Request locality 0.
    w8(ACCESS, ACCESS_REQUEST_USE);
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        const a = r8(ACCESS);
        if (a & (ACCESS_VALID | ACCESS_ACTIVE_LOCALITY) == (ACCESS_VALID | ACCESS_ACTIVE_LOCALITY)) break;
    }
    if (i == POLL_LIMIT) return false;
    const idreg = r32(DID_VID);
    return idreg != 0 and idreg != 0xffffffff;
}

/// Release locality 0.
pub fn release() void {
    w8(ACCESS, ACCESS_ACTIVE_LOCALITY);
}

/// Send a full TPM2 command byte stream.
pub fn send(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    // Move to command-ready; stsValid is only guaranteed once a command is in
    // flight, so we gate on commandReady here.
    w32(STS, STS_COMMAND_READY);
    if (!waitSts(STS_COMMAND_READY)) return false;

    // Write all but the last byte, honouring burst count.
    var i: usize = 0;
    while (i + 1 < cmd.len) {
        var burst = burstCount();
        if (burst == 0) {
            if (!waitBurst()) return false;
            burst = burstCount();
        }
        while (burst > 0 and i + 1 < cmd.len) : (burst -= 1) {
            w8(DATA_FIFO, cmd[i]);
            i += 1;
        }
    }
    // Write the final byte; the TPM clears Expect once it has the full command.
    if (!waitSts(STS_VALID)) return false;
    w8(DATA_FIFO, cmd[cmd.len - 1]);
    if (!waitSts(STS_VALID)) return false;
    if (r32(STS) & STS_EXPECT != 0) return false; // TPM wanted more than we sent

    w32(STS, STS_GO); // execute
    return true;
}

fn waitBurst() bool {
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (burstCount() != 0) return true;
    }
    return false;
}

fn readFifo(buf: []u8) usize {
    var got: usize = 0;
    while (got < buf.len) {
        var burst = burstCount();
        if (burst == 0) {
            if (!waitBurst()) break;
            burst = burstCount();
        }
        while (burst > 0 and got < buf.len) : (burst -= 1) {
            buf[got] = r8(DATA_FIFO);
            got += 1;
        }
    }
    return got;
}

/// Receive a TPM2 response into `buf`. Returns the response length, or null.
pub fn receive(buf: []u8) ?usize {
    if (!waitSts(STS_VALID | STS_DATA_AVAIL)) return null;
    if (buf.len < 6) return null;

    // Read the 6-byte header (tag:2, responseSize:4) to learn the full length.
    if (readFifo(buf[0..6]) != 6) return null;
    const size = std.mem.readInt(u32, buf[2..6], .big);
    if (size < 10 or size > buf.len) return null;
    if (readFifo(buf[6..size]) != size - 6) return null;

    w32(STS, STS_COMMAND_READY); // return to idle
    return size;
}
