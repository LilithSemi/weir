//! Intel-command-set CFI NOR flash driver for the QEMU virt pflash.
//!
//! QEMU's `virt` machine exposes two cfi-flash banks (pflash_cfi01) at
//! 0x2000_0000 and 0x2200_0000, each 32 MiB, bank-width 4. Reads are plain
//! memory accesses. Erase and program go through the Intel command set with
//! status polling. Weir uses one bank as a non-volatile EFI variable store.
//!
//! Attach a backing file with:
//!   -drive if=pflash,unit=1,format=raw,file=vars.img   (maps bank 1)

const std = @import("std");

pub const SIZE: usize = 0x2000000; // 32 MiB

// Intel CFI command-set opcodes (written at bank width).
const CMD_READ_ARRAY: u32 = 0xff;
const CMD_READ_STATUS: u32 = 0x70;
const CMD_ERASE_SETUP: u32 = 0x20;
const CMD_ERASE_CONFIRM: u32 = 0xd0;
const CMD_PROGRAM: u32 = 0x40;
const CMD_CFI_QUERY: u32 = 0x98;

// Status register bits.
const SR_READY: u32 = 0x80;
const SR_ERASE_ERR: u32 = 0x20;
const SR_PROGRAM_ERR: u32 = 0x10;

const default_block_size: usize = 0x40000; // 256 KiB

/// The count of chips side by side in the 32-bit bank, from the reply to the read of
/// the 'Q' of the query. Each chip gives the reply in its own byte lanes.
fn chipCount(reply: u32) ?usize {
    return switch (reply) {
        0x0000_0051 => 1,
        0x0051_0051 => 2,
        0x5151_5151 => 4,
        else => null,
    };
}

/// Each chip reports its own part of an erase block, and the bank erases the block in all chips.
fn bankBlockSize(chips: usize, size_lo: u8, size_hi: u8) usize {
    const per_chip = (@as(usize, size_hi) << 8 | size_lo) * 256;
    if (per_chip == 0) return default_block_size;
    return per_chip * chips;
}

/// One CFI bank that answered the probe.
pub const Bank = struct {
    base: usize,
    block_size: usize,

    /// Probes the bank at `base` for a CFI 'QRY' signature and reads the erase-block size.
    /// A probe of an address with no device can fault, so the caller gives only a base from the device tree.
    pub fn init(base: usize) ?Bank {
        std.debug.assert(base != 0);
        var bank: Bank = .{ .base = base, .block_size = 0 };
        bank.reg(0x55 * 4).* = CMD_CFI_QUERY; // CFI query address is 0x55 (word units)
        const q = bank.reg(0x10 * 4).*;
        const q1: u8 = @truncate(bank.reg(0x11 * 4).*);
        const q2: u8 = @truncate(bank.reg(0x12 * 4).*);
        const chips = chipCount(q);
        if (chips == null or q1 != 'R' or q2 != 'Y') {
            bank.reg(0).* = CMD_READ_ARRAY;
            return null;
        }
        // Erase block size: word 0x2f/0x30 give blocks*256 bytes (little, word units).
        const bz_lo: u8 = @truncate(bank.reg(0x2f * 4).*);
        const bz_hi: u8 = @truncate(bank.reg(0x30 * 4).*);
        bank.block_size = bankBlockSize(chips.?, bz_lo, bz_hi);
        bank.reg(0).* = CMD_READ_ARRAY;
        return bank;
    }

    fn reg(bank: Bank, off: usize) *volatile u32 {
        return @ptrFromInt(bank.base + off);
    }

    fn poll(bank: Bank) bool {
        bank.reg(0).* = CMD_READ_STATUS;
        while (true) {
            const sr = bank.reg(0).*;
            if (sr & SR_READY != 0) {
                bank.reg(0).* = CMD_READ_ARRAY;
                return sr & (SR_ERASE_ERR | SR_PROGRAM_ERR) == 0;
            }
        }
    }

    /// Read `buf.len` bytes from flash offset `off` (plain memory-mapped read).
    pub fn read(bank: Bank, off: usize, buf: []u8) void {
        const src: [*]const u8 = @ptrFromInt(bank.base + off);
        @memcpy(buf, src[0..buf.len]);
    }

    /// Erase the block containing `off`. Returns false on flash error.
    pub fn eraseBlock(bank: Bank, off: usize) bool {
        const start = off & ~(bank.block_size - 1);
        bank.reg(start).* = CMD_ERASE_SETUP;
        bank.reg(start).* = CMD_ERASE_CONFIRM;
        return bank.poll();
    }

    /// Program `data` at `off`. `off` and `data.len` must be 4-byte aligned. The
    /// target must already be erased (NOR can only clear bits). Returns false on
    /// error.
    pub fn program(bank: Bank, off: usize, data: []const u8) bool {
        std.debug.assert(off % 4 == 0 and data.len % 4 == 0);
        var i: usize = 0;
        while (i < data.len) : (i += 4) {
            const word = std.mem.readInt(u32, data[i..][0..4], .little);
            bank.reg(off + i).* = CMD_PROGRAM;
            bank.reg(off + i).* = word;
            if (!bank.poll()) return false;
        }
        return true;
    }
};

test "the query reply gives the count of chips in the bank" {
    try std.testing.expectEqual(@as(?usize, 1), chipCount(0x0000_0051));
    try std.testing.expectEqual(@as(?usize, 2), chipCount(0x0051_0051));
    try std.testing.expectEqual(@as(?usize, 4), chipCount(0x5151_5151));
    try std.testing.expectEqual(@as(?usize, null), chipCount(0xffff_ffff));
    try std.testing.expectEqual(@as(?usize, null), chipCount(0x0000_0052));
}

test "the bank block size is the block size of one chip times the chips" {
    // QEMU virt: two x16 chips, each reports 128 KiB of the 256 KiB sector.
    try std.testing.expectEqual(@as(usize, 256 * 1024), bankBlockSize(2, 0x00, 0x02));
    try std.testing.expectEqual(@as(usize, 128 * 1024), bankBlockSize(1, 0x00, 0x02));
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 4), bankBlockSize(4, 0x00, 0x01));
    try std.testing.expectEqual(default_block_size, bankBlockSize(2, 0, 0));
}
