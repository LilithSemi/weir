//! Minimal TPM 2.0 command layer over the TIS transport: Startup, PCR_Extend,
//! and PCR_Read, which is all measured boot needs.

const std = @import("std");
const tis = @import("tis.zig");

// Command tags.
const ST_NO_SESSIONS: u16 = 0x8001;
const ST_SESSIONS: u16 = 0x8002;

// Command codes.
const CC_STARTUP: u32 = 0x00000144;
const CC_PCR_EXTEND: u32 = 0x00000182;
const CC_PCR_READ: u32 = 0x0000017e;

// Startup types.
const SU_CLEAR: u16 = 0x0000;

// Algorithm ids.
pub const ALG_SHA256: u16 = 0x000b;
pub const SHA256_LEN = 32;

// Password (null) authorization session handle.
const RS_PW: u32 = 0x40000009;

// Response codes we special-case.
const RC_SUCCESS: u32 = 0x0000;
const RC_INITIALIZE: u32 = 0x0100; // already started

var cmd_buf: [256]u8 = undefined;
var rsp_buf: [256]u8 = undefined;

/// Point the transport at the TPM's MMIO base.
pub fn setBase(addr: usize) void {
    tis.setBase(addr);
}

/// Is a TPM responding at the configured base?
pub fn present() bool {
    return tis.present();
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,
    fn u8w(self: *Writer, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }
    fn u16w(self: *Writer, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .big);
        self.pos += 2;
    }
    fn u32w(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }
    fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
};

/// Run a command already built in cmd_buf[0..len] (with a placeholder size),
/// patch the size, send it, and return the response's TPM_RC.
fn run(len: usize) ?u32 {
    std.mem.writeInt(u32, cmd_buf[2..6], @intCast(len), .big); // commandSize
    if (!tis.send(cmd_buf[0..len])) return null;
    const rlen = tis.receive(&rsp_buf) orelse return null;
    if (rlen < 10) return null;
    return std.mem.readInt(u32, rsp_buf[6..10], .big); // responseCode
}

/// Pass a raw, caller-built TPM2 command through and copy the response out.
/// Returns the response length, or null. Used by EFI_TCG2 SubmitCommand.
pub fn submit(input: []const u8, output: []u8) ?usize {
    if (!tis.send(input)) return null;
    const rlen = tis.receive(&rsp_buf) orelse return null;
    if (rlen > output.len) return null;
    @memcpy(output[0..rlen], rsp_buf[0..rlen]);
    return rlen;
}

/// TPM2_Startup(CLEAR). Treats "already initialized" as success.
pub fn startup() bool {
    var w = Writer{ .buf = &cmd_buf };
    w.u16w(ST_NO_SESSIONS);
    w.u32w(0); // size patched in run()
    w.u32w(CC_STARTUP);
    w.u16w(SU_CLEAR);
    const rc = run(w.pos) orelse return false;
    return rc == RC_SUCCESS or rc == RC_INITIALIZE;
}

/// TPM2_PCR_Extend(pcr, SHA-256 digest). Extends one SHA-256 bank.
pub fn pcrExtend(pcr: u32, digest: *const [SHA256_LEN]u8) bool {
    var w = Writer{ .buf = &cmd_buf };
    w.u16w(ST_SESSIONS);
    w.u32w(0); // size
    w.u32w(CC_PCR_EXTEND);
    w.u32w(pcr); // pcrHandle
    // Authorization area: a single password session with empty auth.
    w.u32w(9); // authorizationSize
    w.u32w(RS_PW); // sessionHandle
    w.u16w(0); // nonce size
    w.u8w(0); // sessionAttributes
    w.u16w(0); // hmac/password size
    // TPML_DIGEST_VALUES: one SHA-256 digest.
    w.u32w(1); // count
    w.u16w(ALG_SHA256);
    w.bytes(digest);
    const rc = run(w.pos) orelse return false;
    return rc == RC_SUCCESS;
}

/// TPM2_PCR_Read of one SHA-256 PCR, into `out`. For verifying the chain.
pub fn pcrRead(pcr: u32, out: *[SHA256_LEN]u8) bool {
    var w = Writer{ .buf = &cmd_buf };
    w.u16w(ST_NO_SESSIONS);
    w.u32w(0); // size
    w.u32w(CC_PCR_READ);
    // TPML_PCR_SELECTION: one selection, SHA-256, 3 octets, set bit `pcr`.
    w.u32w(1); // count
    w.u16w(ALG_SHA256);
    w.u8w(3); // sizeofSelect
    var sel = [3]u8{ 0, 0, 0 };
    sel[pcr / 8] = @as(u8, 1) << @intCast(pcr % 8);
    w.bytes(&sel);
    const rc = run(w.pos) orelse return false;
    if (rc != RC_SUCCESS) return false;

    // Walk the response to the digest: header(10) + pcrUpdateCounter(4) +
    // TPML_PCR_SELECTION{ count(4), sel{ alg(2) size(1) bits[size] }... } +
    // TPML_DIGEST{ count(4), size(2) data... }.
    var p: usize = 10 + 4; // after header + update counter
    const sel_count = std.mem.readInt(u32, rsp_buf[p..][0..4], .big);
    p += 4;
    var i: u32 = 0;
    while (i < sel_count) : (i += 1) {
        p += 2; // alg
        const sz = rsp_buf[p];
        p += 1 + sz;
    }
    const dig_count = std.mem.readInt(u32, rsp_buf[p..][0..4], .big);
    p += 4;
    if (dig_count < 1) return false;
    const dsz = std.mem.readInt(u16, rsp_buf[p..][0..2], .big);
    p += 2;
    if (dsz != SHA256_LEN) return false;
    @memcpy(out, rsp_buf[p..][0..SHA256_LEN]);
    return true;
}
