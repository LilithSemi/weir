//! Intel-command-set CFI NOR flash driver for the QEMU virt pflash.
//!
//! QEMU's `virt` machine exposes two cfi-flash banks (pflash_cfi01) at
//! 0x2000_0000 and 0x2200_0000, each 32 MiB, bank-width 4. Reads are plain
//! memory accesses; erase and program go through the Intel command set with
//! status polling. Weir uses one bank as a non-volatile EFI variable store.
//!
//! Attach a backing file with:
//!   -drive if=pflash,unit=1,format=raw,file=vars.img   (maps bank 1)

const std = @import("std");
const console = @import("../console/console.zig");

/// Second flash bank (0x2200_0000). With `-bios`, Weir runs from RAM and the
/// flash banks are free, so we use this one for the variable store.
pub const BASE: usize = 0x22000000;
pub const SIZE: usize = 0x2000000; // 32 MiB

// Intel CFI command-set opcodes (written at bank width).
const CMD_READ_ARRAY: u32 = 0xff;
const CMD_READ_STATUS: u32 = 0x70;
const CMD_CLEAR_STATUS: u32 = 0x50;
const CMD_ERASE_SETUP: u32 = 0x20;
const CMD_ERASE_CONFIRM: u32 = 0xd0;
const CMD_PROGRAM: u32 = 0x40;
const CMD_CFI_QUERY: u32 = 0x98;

// Status register bits.
const SR_READY: u32 = 0x80;
const SR_ERASE_ERR: u32 = 0x20;
const SR_PROGRAM_ERR: u32 = 0x10;

var block_size: usize = 0x40000; // 256 KiB, refined from the CFI query
var present = false;

fn reg(off: usize) *volatile u32 {
    return @ptrFromInt(BASE + off);
}

fn poll() bool {
    reg(0).* = CMD_READ_STATUS;
    while (true) {
        const sr = reg(0).*;
        if (sr & SR_READY != 0) {
            reg(0).* = CMD_READ_ARRAY;
            return sr & (SR_ERASE_ERR | SR_PROGRAM_ERR) == 0;
        }
    }
}

/// Probe the bank for a CFI 'QRY' signature and read the erase-block size.
pub fn init() bool {
    reg(0x55 * 4).* = CMD_CFI_QUERY; // CFI query address is 0x55 (word units)
    const q0: u8 = @truncate(reg(0x10 * 4).*);
    const q1: u8 = @truncate(reg(0x11 * 4).*);
    const q2: u8 = @truncate(reg(0x12 * 4).*);
    if (!(q0 == 'Q' and q1 == 'R' and q2 == 'Y')) {
        reg(0).* = CMD_READ_ARRAY;
        return false;
    }
    // Erase block size: word 0x2f/0x30 give blocks*256 bytes (little, word units).
    const bz_lo: usize = @as(u8, @truncate(reg(0x2f * 4).*));
    const bz_hi: usize = @as(u8, @truncate(reg(0x30 * 4).*));
    const blocks_x256 = bz_lo | (bz_hi << 8);
    if (blocks_x256 != 0) block_size = blocks_x256 * 256;
    reg(0).* = CMD_READ_ARRAY;
    present = true;
    console.printf("[flash] cfi NOR @ {x}, {d} MiB, {d} KiB blocks\n", .{ BASE, SIZE >> 20, block_size >> 10 });
    return true;
}

pub fn isPresent() bool {
    return present;
}

pub fn blockSize() usize {
    return block_size;
}

/// Read `buf.len` bytes from flash offset `off` (plain memory-mapped read).
pub fn read(off: usize, buf: []u8) void {
    const src: [*]const u8 = @ptrFromInt(BASE + off);
    @memcpy(buf, src[0..buf.len]);
}

/// Erase the block containing `off`. Returns false on flash error.
pub fn eraseBlock(off: usize) bool {
    const base = off & ~(block_size - 1);
    reg(base).* = CMD_ERASE_SETUP;
    reg(base).* = CMD_ERASE_CONFIRM;
    return poll();
}

/// Program `data` at `off`. `off` and `data.len` must be 4-byte aligned. The
/// target must already be erased (NOR can only clear bits). Returns false on
/// error.
pub fn program(off: usize, data: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        const word = std.mem.readInt(u32, data[i..][0..4], .little);
        reg(off + i).* = CMD_PROGRAM;
        reg(off + i).* = word;
        if (!poll()) return false;
    }
    return true;
}
