//! FSBL measured-boot: measure the main Weir image into PCR 0 before running it.
//!
//! As the earliest mutable stage, the FSBL is the root of trust: it hashes the
//! loaded firmware, extends PCR 0, and records the digest in the handoff so main
//! Weir logs that exact event. Best-effort, gated on a TPM being present.

const std = @import("std");
const tpm2 = @import("tpm2");
const handoff = @import("boot_handoff");
const cfg = @import("config.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Measure `len` bytes of the main image at dram_base into PCR 0 and publish the
/// digest to main Weir via the handoff record.
pub fn measureMain(con: *std.Io.Writer, len: usize) void {
    if (!cfg.tpm_present) return;
    tpm2.setBase(cfg.tpm_base);
    if (!tpm2.present()) {
        con.writeAll("[fsbl] tpm advertised but not responding\n") catch {};
        return;
    }
    if (!tpm2.startup()) {
        con.writeAll("[fsbl] tpm startup failed\n") catch {};
        return;
    }

    var digest: [32]u8 = undefined;
    const img = @as([*]const u8, @ptrFromInt(cfg.dram_base))[0..len];
    Sha256.hash(img, &digest, .{});
    if (!tpm2.pcrExtend(0, &digest)) {
        con.writeAll("[fsbl] PCR0 extend failed\n") catch {};
        return;
    }

    // Write magic last so a reader never sees it before the rest of the record.
    const rec = handoff.record(cfg.dram_base);
    var i: usize = 0;
    while (i < 32) : (i += 1) rec.pcr0_digest[i] = digest[i];
    rec.pcr0_valid = 1;
    rec.magic = handoff.MAGIC;
    con.writeAll("[fsbl] measured main Weir into PCR0 (root of trust)\n") catch {};
}
