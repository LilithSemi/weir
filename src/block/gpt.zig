//! Minimal GPT partition-table parsing: locate the EFI System Partition.

const std = @import("std");
const block = @import("block.zig");

// ESP partition type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B, on-disk bytes.
const ESP_TYPE = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };

fn isZero(g: []const u8) bool {
    for (g) |b| if (b != 0) return false;
    return true;
}

/// Find the ESP on `dev`. Falls back to the first defined partition if no entry
/// carries the ESP type GUID. Returns null if there is no usable GPT.
pub fn findEsp(dev: *const block.Device) ?block.Partition {
    var sec: [512]u8 = undefined;
    if (!dev.readBlocks(1, 1, &sec)) return null; // GPT header lives at LBA 1
    if (!std.mem.eql(u8, sec[0..8], "EFI PART")) return null;

    const entry_lba = std.mem.readInt(u64, sec[72..80], .little);
    const num = std.mem.readInt(u32, sec[80..84], .little);
    const esize = std.mem.readInt(u32, sec[84..88], .little);
    if (esize == 0 or esize > 512) return null;
    const per_sector = 512 / esize;

    var fallback: ?block.Partition = null;
    var entries: [512]u8 = undefined;
    var i: u32 = 0;
    while (i < num) : (i += 1) {
        if (i % per_sector == 0) {
            if (!dev.readBlocks(entry_lba + i / per_sector, 1, &entries)) break;
        }
        const e = entries[(i % per_sector) * esize ..];
        if (isZero(e[0..16])) continue; // unused entry
        const start = std.mem.readInt(u64, e[32..40], .little);
        const end = std.mem.readInt(u64, e[40..48], .little);
        var part = block.Partition{ .dev = dev, .base_lba = start, .num_blocks = end - start + 1, .number = i + 1 };
        @memcpy(&part.signature, e[16..32]); // unique partition GUID
        if (std.mem.eql(u8, e[0..16], &ESP_TYPE)) return part;
        if (fallback == null) fallback = part;
    }
    return fallback;
}
