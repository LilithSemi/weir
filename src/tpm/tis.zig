//! TPM 2.0 TIS (TPM Interface Specification) driver over MMIO. Transport for
//! measured boot: carries TPM2 command and response byte streams. QEMU's
//! `tpm-tis-device` is at 0x0400_0000 on the virt platform bus. On River the
//! address comes from the platform description. Locality 0 only, polled.

const std = @import("std");

// QEMU virt platform-bus TPM TIS base. setBase overrides it from platform
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

fn burstCount() u32 {
    // STS bits 8-23 hold burstCount. They are only valid when STS_VALID is set.
    // A read mid-transition gives stale bits, so report 0 until valid. The caller
    // polls through waitBurst.
    const s = @as(*volatile u32, @ptrFromInt(base + STS)).*;
    if (s & STS_VALID == 0) return 0;
    return (s >> 8) & 0xffff;
}

/// Wait until all of `bits` are set in TPM_STS. Returns false on timeout.
fn waitSts(bits: u32) bool {
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (@as(*volatile u32, @ptrFromInt(base + STS)).* & bits == bits) return true;
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
    @as(*volatile u8, @ptrFromInt(base + ACCESS)).* = ACCESS_REQUEST_USE;
    const active = ACCESS_VALID | ACCESS_ACTIVE_LOCALITY;
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (@as(*volatile u8, @ptrFromInt(base + ACCESS)).* & active == active) break;
    }
    if (i == POLL_LIMIT) return false;
    const idreg = @as(*volatile u32, @ptrFromInt(base + DID_VID)).*;
    return idreg != 0 and idreg != 0xffffffff;
}

/// Release locality 0.
pub fn release() void {
    @as(*volatile u8, @ptrFromInt(base + ACCESS)).* = ACCESS_ACTIVE_LOCALITY;
}

/// Send a full TPM2 command byte stream.
pub fn send(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    // Move to command-ready. STS_VALID is only guaranteed once a command is in
    // flight, so gate on STS_COMMAND_READY here.
    @as(*volatile u32, @ptrFromInt(base + STS)).* = STS_COMMAND_READY;
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
            @as(*volatile u8, @ptrFromInt(base + DATA_FIFO)).* = cmd[i];
            i += 1;
        }
    }
    // Write the final byte. The TPM clears Expect once it has the full command.
    if (!waitSts(STS_VALID)) return false;
    @as(*volatile u8, @ptrFromInt(base + DATA_FIFO)).* = cmd[cmd.len - 1];
    if (!waitSts(STS_VALID)) return false;
    // TPM wanted more bytes than Weir sent.
    if (@as(*volatile u32, @ptrFromInt(base + STS)).* & STS_EXPECT != 0) return false;

    @as(*volatile u32, @ptrFromInt(base + STS)).* = STS_GO; // execute
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
            buf[got] = @as(*volatile u8, @ptrFromInt(base + DATA_FIFO)).*;
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

    @as(*volatile u32, @ptrFromInt(base + STS)).* = STS_COMMAND_READY; // return to idle
    return size;
}
