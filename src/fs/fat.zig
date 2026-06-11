//! Read-only FAT12/16/32 driver: open and read a file by path off an ESP, with
//! LFN matching so paths like \EFI\BOOT\BOOTRISCV64.EFI resolve. Exposes fs.Fs.

const std = @import("std");
const block = @import("../block/block.zig");
const fs = @import("fs.zig");
const console = @import("../console/console.zig");

const Type = enum { fat12, fat16, fat32 };

const State = struct {
    part: block.Partition = undefined,
    bytes_per_sector: u32 = 0,
    sectors_per_cluster: u32 = 0,
    reserved: u32 = 0,
    num_fats: u32 = 0,
    fat_sectors: u32 = 0,
    first_data_sector: u32 = 0,
    first_fat_sector: u32 = 0,
    root_cluster: u32 = 0, // FAT32
    root_dir_sectors: u32 = 0, // FAT12/16
    root_dir_start: u32 = 0, // FAT12/16 first sector
    kind: Type = .fat32,
};

var state: State = .{};
var sector_buf: [512]u8 = undefined;

// One-sector FAT cache: chain-walk touches consecutive entries sharing a sector,
// so caching the last one turns a per-cluster read into a hit. `fat_cache_rel`
// is the FAT-relative sector, 0xffffffff means invalid.
var fat_cache_buf: [512]u8 = undefined;
var fat_cache_rel: u32 = 0xffffffff;

fn readFatSector(s: *const State, rel: u32) ?*[512]u8 {
    if (fat_cache_rel != rel) {
        if (!s.part.readBlocks(s.first_fat_sector + rel, 1, &fat_cache_buf)) return null;
        fat_cache_rel = rel;
    }
    return &fat_cache_buf;
}

fn clusterToSector(s: *const State, cluster: u32) u32 {
    return s.first_data_sector + (cluster - 2) * s.sectors_per_cluster;
}

fn eoc(s: *const State, cluster: u32) bool {
    return switch (s.kind) {
        .fat12 => cluster >= 0xff8,
        .fat16 => cluster >= 0xfff8,
        .fat32 => cluster >= 0x0ffffff8,
    };
}

/// Next cluster in a chain from the FAT.
fn nextCluster(s: *const State, cluster: u32) u32 {
    switch (s.kind) {
        .fat32 => {
            const off = cluster * 4;
            const buf = readFatSector(s, off / 512) orelse return 0x0fffffff;
            return std.mem.readInt(u32, buf[off % 512 ..][0..4], .little) & 0x0fffffff;
        },
        .fat16 => {
            const off = cluster * 2;
            const buf = readFatSector(s, off / 512) orelse return 0xffff;
            return std.mem.readInt(u16, buf[off % 512 ..][0..2], .little);
        },
        .fat12 => {
            const off = cluster + cluster / 2;
            const buf = readFatSector(s, off / 512) orelse return 0xfff;
            // A 12-bit entry can straddle a sector boundary; read two bytes safely.
            const lo = buf[off % 512];
            const hi = if (off % 512 == 511) blk: {
                var nb: [512]u8 = undefined;
                _ = s.part.readBlocks(s.first_fat_sector + off / 512 + 1, 1, &nb);
                break :blk nb[0];
            } else buf[off % 512 + 1];
            const v = @as(u16, lo) | (@as(u16, hi) << 8);
            return if (cluster & 1 == 0) v & 0xfff else v >> 4;
        },
    }
}

/// Mount the partition. Returns an Fs handle or null.
pub fn mount(part: block.Partition) ?fs.Fs {
    var bpb: [512]u8 = undefined;
    if (!part.readBlocks(0, 1, &bpb)) return null;

    var s = State{ .part = part };
    s.bytes_per_sector = std.mem.readInt(u16, bpb[11..13], .little);
    s.sectors_per_cluster = bpb[13];
    s.reserved = std.mem.readInt(u16, bpb[14..16], .little);
    s.num_fats = bpb[16];
    const root_entries = std.mem.readInt(u16, bpb[17..19], .little);
    const total16 = std.mem.readInt(u16, bpb[19..21], .little);
    const fat16_size = std.mem.readInt(u16, bpb[22..24], .little);
    const total32 = std.mem.readInt(u32, bpb[32..36], .little);
    if (s.bytes_per_sector != 512 or s.sectors_per_cluster == 0) return null;

    s.fat_sectors = if (fat16_size != 0) fat16_size else std.mem.readInt(u32, bpb[36..40], .little);
    const total = if (total16 != 0) @as(u32, total16) else total32;
    s.root_dir_sectors = (@as(u32, root_entries) * 32 + 511) / 512;
    s.first_fat_sector = s.reserved;
    s.first_data_sector = s.reserved + s.num_fats * s.fat_sectors + s.root_dir_sectors;
    s.root_dir_start = s.reserved + s.num_fats * s.fat_sectors;
    s.root_cluster = std.mem.readInt(u32, bpb[44..48], .little);

    const data_sectors = total - s.first_data_sector;
    const clusters = data_sectors / s.sectors_per_cluster;
    // A zero 16-bit FAT size means FAT32 (it uses the 32-bit field); reliable
    // even for small volumes that the cluster-count rule would misjudge.
    s.kind = if (fat16_size == 0) .fat32 else if (clusters < 4085) .fat12 else .fat16;

    state = s;
    fat_cache_rel = 0xffffffff; // invalidate for the new volume
    rr_valid = false;
    return .{ .ctx = &state, .read_file = &readFileImpl };
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn ieq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

/// Build "NAME.EXT" (uppercased, trimmed) from an 8.3 entry.
fn shortName(raw: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < 8 and raw[i] != ' ') : (i += 1) {
        out[n] = upper(raw[i]);
        n += 1;
    }
    if (raw[8] != ' ') {
        out[n] = '.';
        n += 1;
        i = 8;
        while (i < 11 and raw[i] != ' ') : (i += 1) {
            out[n] = upper(raw[i]);
            n += 1;
        }
    }
    return n;
}

const Entry = struct { cluster: u32, size: u32, is_dir: bool };

// Directory location: fixed FAT12/16 root region, or a cluster chain.
const Dir = union(enum) { root16, chain: u32 };

/// Scan a directory for `name` (case-insensitive, matches LFN or short name).
fn findInDir(s: *State, dir: Dir, name: []const u8) ?Entry {
    var lfn: [260]u8 = undefined; // reconstructed long name (ASCII subset)
    var lfn_len: usize = 0;
    var have_lfn = false;

    var cluster: u32 = switch (dir) {
        .root16 => 0,
        .chain => |c| c,
    };
    var sector_in_root: u32 = 0;

    while (true) {
        var sector: u32 = undefined;
        var sectors_this: u32 = undefined;
        switch (dir) {
            .root16 => {
                if (sector_in_root >= s.root_dir_sectors) return null;
                sector = s.root_dir_start + sector_in_root;
                sectors_this = 1;
            },
            .chain => {
                if (eoc(s, cluster) or cluster < 2) return null;
                sector = clusterToSector(s, cluster);
                sectors_this = s.sectors_per_cluster;
            },
        }

        var ss: u32 = 0;
        while (ss < sectors_this) : (ss += 1) {
            if (!s.part.readBlocks(sector + ss, 1, &sector_buf)) return null;
            var e: usize = 0;
            while (e < 512) : (e += 32) {
                const ent = sector_buf[e .. e + 32];
                if (ent[0] == 0x00) return null; // end of directory
                if (ent[0] == 0xe5) {
                    have_lfn = false;
                    continue;
                }
                const attr = ent[11];
                if (attr == 0x0f) {
                    // LFN fragment: 13 UTF-16 chars at fixed offsets, reversed order.
                    const seq = ent[0] & 0x1f;
                    const idx_positions = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
                    var tmp: [13]u8 = undefined;
                    var tn: usize = 0;
                    for (idx_positions) |p| {
                        const ch = @as(u16, ent[p]) | (@as(u16, ent[p + 1]) << 8);
                        if (ch == 0 or ch == 0xffff) break;
                        tmp[tn] = if (ch < 0x80) @intCast(ch) else '?';
                        tn += 1;
                    }
                    const base = (seq - 1) * 13;
                    if (base + tn <= lfn.len) {
                        @memcpy(lfn[base .. base + tn], tmp[0..tn]);
                        if (ent[0] & 0x40 != 0) lfn_len = base + tn; // last (first physically) entry sets length
                    }
                    have_lfn = true;
                    continue;
                }
                if (attr & 0x08 != 0) { // volume label
                    have_lfn = false;
                    continue;
                }

                const cl = (@as(u32, std.mem.readInt(u16, ent[20..22], .little)) << 16) |
                    std.mem.readInt(u16, ent[26..28], .little);
                const entry = Entry{
                    .cluster = cl,
                    .size = std.mem.readInt(u32, ent[28..32], .little),
                    .is_dir = attr & 0x10 != 0,
                };

                if (have_lfn and ieq(lfn[0..lfn_len], name)) return entry;
                var sn: [13]u8 = undefined;
                const snl = shortName(ent[0..11], &sn);
                if (ieq(sn[0..snl], name)) return entry;
                have_lfn = false;
            }
        }

        switch (dir) {
            .root16 => sector_in_root += 1,
            .chain => cluster = nextCluster(s, cluster),
        }
    }
}

/// Read a file's cluster chain into `buf`, up to its size. Returns bytes read.
fn readChain(s: *State, start_cluster: u32, size: u32, buf: []u8) ?usize {
    if (size > buf.len) return null;
    const cluster_bytes = s.sectors_per_cluster * 512;
    var cluster = start_cluster;
    var written: usize = 0;
    while (written < size) {
        if (eoc(s, cluster) or cluster < 2) break;
        const sector = clusterToSector(s, cluster);
        var ss: u32 = 0;
        while (ss < s.sectors_per_cluster and written < size) : (ss += 1) {
            const chunk = @min(@as(usize, 512), size - written);
            if (chunk == 512) {
                if (!s.part.readBlocks(sector + ss, 1, buf[written..][0..512])) return null;
            } else {
                if (!s.part.readBlocks(sector + ss, 1, &sector_buf)) return null;
                @memcpy(buf[written..][0..chunk], sector_buf[0..chunk]);
            }
            written += chunk;
        }
        _ = cluster_bytes;
        cluster = nextCluster(s, cluster);
    }
    return written;
}

// --- Primitives for the Simple File System / File protocols -----------------

/// Directory location: FAT12/16 fixed root, or a cluster chain.
pub const Loc = struct { root16: bool, cluster: u32 };

pub const DirEnt = struct {
    name: [256]u16 = undefined, // UTF-16, null-terminated
    name_units: usize = 0, // including the null
    cluster: u32 = 0,
    size: u32 = 0,
    is_dir: bool = false,
};

pub fn rootLoc() Loc {
    return if (state.kind == .fat32)
        .{ .root16 = false, .cluster = state.root_cluster }
    else
        .{ .root16 = true, .cluster = 0 };
}

/// Scan a directory. With `want_name`, find that entry; else return the
/// `want_index`-th real entry. Fills `out` with a UTF-16 name from LFN entries
/// (or the 8.3 short name). Returns false at end.
fn scan(s: *State, loc: Loc, want_index: ?usize, want_name: ?[]const u8, out: *DirEnt) bool {
    var lfn: [256]u16 = undefined;
    var lfn_units: usize = 0;
    var have_lfn = false;
    var seen: usize = 0;

    var cluster = loc.cluster;
    var root_sector: u32 = 0;
    while (true) {
        var sector: u32 = undefined;
        var sectors_this: u32 = undefined;
        if (loc.root16) {
            if (root_sector >= s.root_dir_sectors) return false;
            sector = s.root_dir_start + root_sector;
            sectors_this = 1;
        } else {
            if (eoc(s, cluster) or cluster < 2) return false;
            sector = clusterToSector(s, cluster);
            sectors_this = s.sectors_per_cluster;
        }

        var ss: u32 = 0;
        while (ss < sectors_this) : (ss += 1) {
            if (!s.part.readBlocks(sector + ss, 1, &sector_buf)) return false;
            var e: usize = 0;
            while (e < 512) : (e += 32) {
                const ent = sector_buf[e .. e + 32];
                if (ent[0] == 0x00) return false;
                if (ent[0] == 0xe5) {
                    have_lfn = false;
                    continue;
                }
                const attr = ent[11];
                if (attr == 0x0f) {
                    const seq = ent[0] & 0x1f;
                    const pos = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
                    const base = (seq - 1) * 13;
                    var k: usize = 0;
                    for (pos) |p| {
                        const ch = @as(u16, ent[p]) | (@as(u16, ent[p + 1]) << 8);
                        if (base + k < lfn.len) lfn[base + k] = ch;
                        if (ch == 0) {
                            if (base + k < lfn.len) lfn_units = base + k + 1;
                        }
                        k += 1;
                    }
                    if (ent[0] & 0x40 != 0 and lfn_units == 0) lfn_units = base + 13;
                    have_lfn = true;
                    continue;
                }
                if (attr & 0x08 != 0) {
                    have_lfn = false;
                    continue;
                }
                if (ent[0] == '.') { // skip "." and ".."
                    have_lfn = false;
                    continue;
                }

                // A real entry. Build its UTF-16 name.
                out.cluster = (@as(u32, std.mem.readInt(u16, ent[20..22], .little)) << 16) |
                    std.mem.readInt(u16, ent[26..28], .little);
                out.size = std.mem.readInt(u32, ent[28..32], .little);
                out.is_dir = attr & 0x10 != 0;
                if (have_lfn and lfn_units > 0) {
                    @memcpy(out.name[0..lfn_units], lfn[0..lfn_units]);
                    out.name_units = lfn_units;
                } else {
                    var sn: [13]u8 = undefined;
                    const snl = shortName(ent[0..11], &sn);
                    var i: usize = 0;
                    while (i < snl) : (i += 1) out.name[i] = sn[i];
                    out.name[snl] = 0;
                    out.name_units = snl + 1;
                }
                have_lfn = false;

                if (want_name) |wn| {
                    if (nameMatches(out.name[0..out.name_units], wn)) return true;
                } else if (want_index) |wi| {
                    if (seen == wi) return true;
                    seen += 1;
                }
            }
        }
        if (loc.root16) root_sector += 1 else cluster = nextCluster(s, cluster);
    }
}

fn nameMatches(name_u16: []const u16, want: []const u8) bool {
    var i: usize = 0;
    while (i < want.len) : (i += 1) {
        if (i + 1 >= name_u16.len) return false;
        const c: u16 = if (name_u16[i] < 0x80) name_u16[i] else '?';
        if (upper(@intCast(c & 0x7f)) != upper(want[i])) return false;
    }
    return i + 1 <= name_u16.len and name_u16[i] == 0;
}

/// Resolve a single path component within `loc`.
pub fn lookupComponent(loc: Loc, name: []const u8, out: *DirEnt) bool {
    return scan(&state, loc, null, name, out);
}

/// Return the `index`-th entry of a directory (for enumeration).
pub fn enumerate(loc: Loc, index: usize, out: *DirEnt) bool {
    return scan(&state, loc, index, null, out);
}

/// Read up to `buf.len` bytes of a file starting at `offset`. Returns bytes read.
// Sequential-read resume cache. Large files (kernel, large initrd) are read via
// readRegion with advancing offsets; without this each call re-walks the chain
// from the start, O(n^2) over the file. Remember where the last read ended so a
// continuing read resumes from its cluster.
var rr_valid = false;
var rr_start: u32 = 0;
var rr_offset: u64 = 0;
var rr_cluster: u32 = 0;

pub fn readRegion(start_cluster: u32, size: u32, offset: u64, buf: []u8) usize {
    const s = &state;
    if (offset >= size) return 0;
    const cluster_bytes: u64 = @as(u64, s.sectors_per_cluster) * 512;

    // Resume if this read continues the last one; else walk to the offset.
    var cluster: u32 = undefined;
    if (rr_valid and rr_start == start_cluster and rr_offset == offset and offset != 0) {
        cluster = rr_cluster;
    } else {
        cluster = start_cluster;
        var skip = offset;
        while (skip >= cluster_bytes) : (skip -= cluster_bytes) {
            if (eoc(s, cluster) or cluster < 2) return 0;
            cluster = nextCluster(s, cluster);
        }
    }

    var produced: usize = 0;
    var pos = offset;
    while (produced < buf.len and pos < size) {
        if (eoc(s, cluster) or cluster < 2) break;
        const sector = clusterToSector(s, cluster);
        var in_cluster = pos % cluster_bytes;
        while (in_cluster < cluster_bytes and produced < buf.len and pos < size) {
            const want = @min(cluster_bytes - in_cluster, @min(@as(u64, buf.len - produced), size - pos));
            if (in_cluster % 512 == 0 and want >= 512) {
                // Aligned run: read whole sectors straight into the caller's
                // buffer in one multi-sector request, no bounce.
                const nsec: u32 = @intCast(want / 512);
                const sec_idx: u32 = @intCast(in_cluster / 512);
                const nbytes = nsec * 512;
                if (!s.part.readBlocks(sector + sec_idx, nsec, buf[produced..][0..nbytes])) {
                    rr_valid = false;
                    return produced;
                }
                produced += nbytes;
                pos += nbytes;
                in_cluster += nbytes;
            } else {
                // Unaligned head/tail: bounce one sector.
                const sec_idx: u32 = @intCast(in_cluster / 512);
                if (!s.part.readBlocks(sector + sec_idx, 1, &sector_buf)) {
                    rr_valid = false;
                    return produced;
                }
                const sec_off: usize = @intCast(in_cluster % 512);
                const avail = @min(@as(u64, 512 - sec_off), want);
                @memcpy(buf[produced..][0..@intCast(avail)], sector_buf[sec_off..][0..@intCast(avail)]);
                produced += @intCast(avail);
                pos += avail;
                in_cluster += avail;
            }
        }
        // Advance only when the cluster is fully consumed, so a mid-cluster stop
        // leaves `cluster` pointing at the next byte to read.
        if (in_cluster >= cluster_bytes) cluster = nextCluster(s, cluster);
    }

    rr_valid = true;
    rr_start = start_cluster;
    rr_offset = pos;
    rr_cluster = cluster;
    return produced;
}

fn readFileImpl(ctx: *anyopaque, path: []const u8, buf: []u8) ?usize {
    const s: *State = @ptrCast(@alignCast(ctx));

    var dir: Dir = if (s.kind == .fat32) .{ .chain = s.root_cluster } else .root16;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var entry: ?Entry = null;
    while (it.next()) |comp| {
        const found = findInDir(s, dir, comp) orelse return null;
        if (it.peek() != null) {
            if (!found.is_dir) return null;
            dir = .{ .chain = found.cluster };
        } else {
            if (found.is_dir) return null;
            entry = found;
        }
    }
    const f = entry orelse return null;
    return readChain(s, f.cluster, f.size, buf);
}
