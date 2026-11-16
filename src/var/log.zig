//! The EFI variable log: two banks on flash, each an append log of records.
//!
//! Only the active bank is read. The loader copies it to RAM and the read side
//! scans that copy. Integers are little-endian. Erased flash reads 0xFF and a
//! program operation can only clear bits.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // The layouts below are written to flash as raw bytes.
    if (builtin.cpu.arch.endian() != .little) @compileError("the variable log needs a little-endian target");
}

pub const bank_magic: u32 = 0x32535657;
pub const valid_mark: u32 = 0x444c4156;

pub const max_name_units = 256;
pub const max_data_len = 32 * 1024;

pub const BankHeader = extern struct {
    magic: u32,
    sequence: u32,
    /// CRC32 of `magic` and `sequence`.
    crc: u32,
    /// Stays erased until the bank is complete.
    valid: u32,
};

pub const RecordHeader = extern struct {
    /// CRC32 of the header bytes after this field, the name and the data.
    crc: u32,
    attributes: u32,
    guid: [16]u8,
    /// Bytes of the UTF-16 name, with the terminator.
    name_len: u16,
    reserved: u16,
    /// 0 marks a delete.
    data_len: u32,
};

pub const Geometry = struct {
    /// From the start of the store area.
    bank_offsets: [2]usize,
    /// Bytes used in each bank.
    bank_len: usize,
    erase_size: usize,
};

pub const LoadResult = enum { fresh, loaded, recovered };

pub const Entry = struct {
    attributes: u32,
    data: []const u8,
};

pub const Key = struct {
    name: []const u16,
    guid: *const [16]u8,
};

pub const bank_header_len = @sizeOf(BankHeader);
pub const record_header_len = @sizeOf(RecordHeader);
const record_align = 4;

fn checkLayout(comptime T: type, comptime size: usize) void {
    if (@sizeOf(T) != size) @compileError(@typeName(T) ++ " has the wrong size");
    if (@alignOf(T) != 4) @compileError(@typeName(T) ++ " has the wrong alignment");
}

comptime {
    checkLayout(BankHeader, 16);
    checkLayout(RecordHeader, 32);
}

pub fn bankCrc(sequence: u32) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(&std.mem.toBytes(bank_magic));
    crc.update(&std.mem.toBytes(sequence));
    return crc.final();
}

pub fn recordCrc(header: RecordHeader, name: []const u8, data: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(std.mem.asBytes(&header)[@sizeOf(u32)..]);
    crc.update(name);
    crc.update(data);
    return crc.final();
}

/// The bytes a record takes in the log, with the padding.
pub fn recordLen(name_len: usize, data_len: usize) usize {
    return std.mem.alignForward(usize, record_header_len + name_len + data_len, record_align);
}

const Record = struct {
    offset: usize,
    len: usize,
    attributes: u32,
    guid: *const [16]u8,
    name: []const u16,
    data: []const u8,

    fn sameKey(a: Record, b: Record) bool {
        return std.mem.eql(u16, a.name, b.name) and std.mem.eql(u8, a.guid, b.guid);
    }
};

const Parsed = union(enum) {
    /// An erased header, or the end of the bank.
    end,
    /// A record that fails a check.
    bad,
    record: Record,
};

fn allErased(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0xff);
}

fn parse(bank: []align(4) const u8, off: usize) Parsed {
    if (off >= bank.len) return .end;
    if (bank.len - off < record_header_len) {
        return if (allErased(bank[off..])) .end else .bad;
    }
    const raw = bank[off..][0..record_header_len];
    if (allErased(raw)) return .end;
    const header = std.mem.bytesToValue(RecordHeader, raw);
    if (header.name_len == 0 or header.name_len % 2 != 0) return .bad;
    if (header.name_len > max_name_units * 2) return .bad;
    if (header.data_len > max_data_len) return .bad;
    if (header.reserved != 0) return .bad;
    if (recordLen(header.name_len, header.data_len) > bank.len - off) return .bad;
    const rec = view(bank, off);
    if (rec.name[rec.name.len - 1] != 0) return .bad;
    const name_bytes = bank[off + record_header_len ..][0..header.name_len];
    if (recordCrc(header, name_bytes, rec.data) != header.crc) return .bad;
    return .{ .record = rec };
}

/// Reads the record at `off`. Only `parse` has checked it, so call this below `end`.
fn view(bank: []align(4) const u8, off: usize) Record {
    const raw = bank[off..][0..record_header_len];
    const header = std.mem.bytesToValue(RecordHeader, raw);
    const name_bytes = bank[off + record_header_len ..][0..header.name_len];
    return .{
        .offset = off,
        .len = recordLen(header.name_len, header.data_len),
        .attributes = header.attributes,
        .guid = raw[8..][0..16],
        .name = @alignCast(std.mem.bytesAsSlice(u16, name_bytes)),
        .data = bank[off + record_header_len + header.name_len ..][0..header.data_len],
    };
}

pub fn Store(comptime Flash: type, comptime geo: Geometry) type {
    comptime {
        if (geo.bank_len % record_align != 0) @compileError("bank_len must be a multiple of 4");
        if (geo.bank_len < bank_header_len + record_header_len) @compileError("bank_len is too small");
        const a = geo.bank_offsets[0];
        const b = geo.bank_offsets[1];
        if (a < b and a + geo.bank_len > b or b < a and b + geo.bank_len > a or a == b) {
            @compileError("the banks overlap");
        }
    }

    return struct {
        const Self = @This();

        flash: *Flash,
        mirror: [geo.bank_len]u8 align(4),
        active: u1,
        sequence: u32,
        /// Offset in `mirror` of the first byte after the last good record.
        end: usize,
        /// The log has a torn or bad tail that a compaction must remove.
        needs_compaction: bool,

        pub fn init(flash: *Flash) Self {
            return .{
                .flash = flash,
                .mirror = @splat(0xff),
                .active = 0,
                .sequence = 0,
                .end = bank_header_len,
                .needs_compaction = false,
            };
        }

        fn bankSequence(self: *Self, bank: u1) ?u32 {
            var raw: [bank_header_len]u8 = undefined;
            self.flash.read(geo.bank_offsets[bank], &raw);
            const header = std.mem.bytesToValue(BankHeader, &raw);
            if (header.magic != bank_magic) return null;
            if (header.crc != bankCrc(header.sequence)) return null;
            if (header.valid != valid_mark) return null;
            return header.sequence;
        }

        pub fn load(self: *Self) LoadResult {
            self.mirror = @splat(0xff);
            self.active = 0;
            self.sequence = 0;
            self.end = bank_header_len;
            self.needs_compaction = false;

            const seq0 = self.bankSequence(0);
            const seq1 = self.bankSequence(1);
            if (seq0 == null and seq1 == null) return .fresh;
            if (seq0 != null and (seq1 == null or seq0.? >= seq1.?)) {
                self.active = 0;
                self.sequence = seq0.?;
            } else {
                self.active = 1;
                self.sequence = seq1.?;
            }

            self.flash.read(geo.bank_offsets[self.active], &self.mirror);
            var off: usize = bank_header_len;
            while (true) {
                switch (parse(&self.mirror, off)) {
                    .end => break,
                    .bad => {
                        self.needs_compaction = true;
                        break;
                    },
                    .record => |rec| off += rec.len,
                }
            }
            self.end = off;
            if (!allErased(self.mirror[off..])) self.needs_compaction = true;
            return .loaded;
        }

        fn recordAt(self: *const Self, off: usize) ?Record {
            if (off >= self.end) return null;
            return view(&self.mirror, off);
        }

        /// A variable is live when its last record has data.
        fn isLive(self: *const Self, rec: Record) bool {
            if (rec.data.len == 0) return false;
            var off = rec.offset + rec.len;
            while (self.recordAt(off)) |later| : (off += later.len) {
                if (rec.sameKey(later)) return false;
            }
            return true;
        }

        /// The name includes its terminator.
        pub fn get(self: *const Self, name: []const u16, guid: *const [16]u8) ?Entry {
            var found: ?Entry = null;
            var off: usize = bank_header_len;
            while (self.recordAt(off)) |rec| : (off += rec.len) {
                if (!std.mem.eql(u16, rec.name, name) or !std.mem.eql(u8, rec.guid, guid)) continue;
                found = if (rec.data.len == 0) null else .{ .attributes = rec.attributes, .data = rec.data };
            }
            return found;
        }

        /// Live variables in log order. The order follows the last record of each.
        pub fn next(self: *const Self, prev: ?Key) ?Key {
            var seen = prev == null;
            var off: usize = bank_header_len;
            while (self.recordAt(off)) |rec| : (off += rec.len) {
                if (!self.isLive(rec)) continue;
                if (!seen) {
                    const p = prev.?;
                    seen = std.mem.eql(u16, rec.name, p.name) and std.mem.eql(u8, rec.guid, p.guid);
                    continue;
                }
                return .{ .name = rec.name, .guid = rec.guid };
            }
            return null;
        }
    };
}

/// A flash model for tests. It can cut one operation short to model a power loss.
pub fn RamFlash(comptime size: usize) type {
    return struct {
        const Self = @This();

        data: [size]u8,
        erase_size: usize,
        /// Count of erase and program calls so far.
        ops: usize = 0,
        /// The operation with this index applies at most `cut_bytes` bytes. It and every later one return false.
        cut_at: ?usize = null,
        cut_bytes: usize = 0,
        dead: bool = false,

        pub fn init(erase_size: usize) Self {
            return .{ .data = @splat(0xff), .erase_size = erase_size };
        }

        pub fn read(self: *const Self, off: usize, buf: []u8) void {
            @memcpy(buf, self.data[off..][0..buf.len]);
        }

        pub fn erase(self: *Self, off: usize) bool {
            const start = off / self.erase_size * self.erase_size;
            var n = self.erase_size;
            if (!self.begin(&n)) return false;
            @memset(self.data[start..][0..n], 0xff);
            return !self.dead;
        }

        pub fn program(self: *Self, off: usize, bytes: []const u8) bool {
            var n = bytes.len;
            if (!self.begin(&n)) return false;
            for (bytes[0..n], self.data[off..][0..n]) |b, *d| d.* &= b;
            return !self.dead;
        }

        /// Counts one operation. It lowers `n` when this operation is the cut one.
        fn begin(self: *Self, n: *usize) bool {
            if (self.dead) return false;
            const index = self.ops;
            self.ops += 1;
            if (self.cut_at == index) {
                self.dead = true;
                n.* = @min(n.*, self.cut_bytes);
            }
            return true;
        }
    };
}

const testing = std.testing;

const test_geo: Geometry = .{ .bank_offsets = .{ 0, 4096 }, .bank_len = 4096, .erase_size = 1024 };
const TestFlash = RamFlash(8192);
const TestStore = Store(TestFlash, test_geo);

const guid_a: [16]u8 = @splat(0xa);
const guid_b: [16]u8 = @splat(0xb);

fn wide(comptime s: []const u8) []const u16 {
    const w = std.unicode.utf8ToUtf16LeStringLiteral(s);
    return w.ptr[0 .. w.len + 1];
}

fn writeBankHeader(flash: *TestFlash, bank: u1, sequence: u32, valid: u32) void {
    const header: BankHeader = .{
        .magic = bank_magic,
        .sequence = sequence,
        .crc = bankCrc(sequence),
        .valid = valid,
    };
    @memcpy(flash.data[test_geo.bank_offsets[bank]..][0..bank_header_len], std.mem.asBytes(&header));
}

/// Builds one record at `off` in `bank`. It returns the offset after the record.
fn appendRecord(
    flash: *TestFlash,
    bank: u1,
    off: usize,
    name: []const u16,
    guid: *const [16]u8,
    attributes: u32,
    data: []const u8,
) usize {
    const name_bytes = std.mem.sliceAsBytes(name);
    var header: RecordHeader = .{
        .crc = 0,
        .attributes = attributes,
        .guid = guid.*,
        .name_len = @intCast(name_bytes.len),
        .reserved = 0,
        .data_len = @intCast(data.len),
    };
    header.crc = recordCrc(header, name_bytes, data);
    const base = test_geo.bank_offsets[bank] + off;
    @memcpy(flash.data[base..][0..record_header_len], std.mem.asBytes(&header));
    @memcpy(flash.data[base + record_header_len ..][0..name_bytes.len], name_bytes);
    @memcpy(flash.data[base + record_header_len + name_bytes.len ..][0..data.len], data);
    return off + recordLen(name_bytes.len, data.len);
}

test "header sizes are 16 and 32 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(BankHeader));
    try testing.expectEqual(@as(usize, 32), @sizeOf(RecordHeader));
    try testing.expectEqual(@as(usize, 8), @offsetOf(RecordHeader, "guid"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(RecordHeader, "data_len"));
}

test "an erased flash loads as fresh and holds no variables" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.fresh, store.load());
    try testing.expect(!store.needs_compaction);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("Boot0001"), &guid_a));
    try testing.expectEqual(@as(?Key, null), store.next(null));
}

test "a bank with three records loads and each value is readable" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 7, valid_mark);
    var off: usize = bank_header_len;
    off = appendRecord(&flash, 0, off, wide("Boot0001"), &guid_a, 0x7, "abc");
    off = appendRecord(&flash, 0, off, wide("Timeout"), &guid_a, 0x3, &.{ 1, 2, 3, 4, 5 });
    off = appendRecord(&flash, 0, off, wide("Boot0001"), &guid_b, 0x1, "z");

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(!store.needs_compaction);
    try testing.expectEqual(@as(u32, 7), store.sequence);
    try testing.expectEqual(off, store.end);

    const a = store.get(wide("Boot0001"), &guid_a).?;
    try testing.expectEqual(@as(u32, 0x7), a.attributes);
    try testing.expectEqualStrings("abc", a.data);
    const t = store.get(wide("Timeout"), &guid_a).?;
    try testing.expectEqual(@as(u32, 0x3), t.attributes);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, t.data);
    const b = store.get(wide("Boot0001"), &guid_b).?;
    try testing.expectEqual(@as(u32, 0x1), b.attributes);
    try testing.expectEqualStrings("z", b.data);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("Boot0002"), &guid_a));
}

test "a later record replaces an earlier one and a delete removes it" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    var off: usize = bank_header_len;
    off = appendRecord(&flash, 0, off, wide("A"), &guid_a, 1, "one");
    off = appendRecord(&flash, 0, off, wide("B"), &guid_a, 2, "two");
    off = appendRecord(&flash, 0, off, wide("C"), &guid_a, 3, "three");
    off = appendRecord(&flash, 0, off, wide("A"), &guid_a, 4, "uno");
    off = appendRecord(&flash, 0, off, wide("B"), &guid_a, 0, "");

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(!store.needs_compaction);

    const a = store.get(wide("A"), &guid_a).?;
    try testing.expectEqual(@as(u32, 4), a.attributes);
    try testing.expectEqualStrings("uno", a.data);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("B"), &guid_a));

    const first = store.next(null).?;
    try testing.expectEqualSlices(u16, wide("C"), first.name);
    try testing.expectEqualSlices(u8, &guid_a, first.guid);
    const second = store.next(first).?;
    try testing.expectEqualSlices(u16, wide("A"), second.name);
    try testing.expectEqual(@as(?Key, null), store.next(second));
}

test "next gives null when the previous key is not live" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    _ = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "x");

    var store = TestStore.init(&flash);
    _ = store.load();
    const missing: Key = .{ .name = wide("Nope"), .guid = &guid_a };
    try testing.expectEqual(@as(?Key, null), store.next(missing));
    const wrong_guid: Key = .{ .name = wide("A"), .guid = &guid_b };
    try testing.expectEqual(@as(?Key, null), store.next(wrong_guid));
}

test "the bank with the higher sequence is active" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 5, valid_mark);
    _ = appendRecord(&flash, 0, bank_header_len, wide("V"), &guid_a, 1, "old");
    writeBankHeader(&flash, 1, 6, valid_mark);
    _ = appendRecord(&flash, 1, bank_header_len, wide("V"), &guid_a, 1, "new");

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expectEqual(@as(u1, 1), store.active);
    try testing.expectEqual(@as(u32, 6), store.sequence);
    try testing.expectEqualStrings("new", store.get(wide("V"), &guid_a).?.data);
}

test "a bank without the valid mark is ignored" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 5, valid_mark);
    _ = appendRecord(&flash, 0, bank_header_len, wide("V"), &guid_a, 1, "old");
    writeBankHeader(&flash, 1, 6, 0xffff_ffff);
    _ = appendRecord(&flash, 1, bank_header_len, wide("V"), &guid_a, 1, "new");

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expectEqual(@as(u1, 0), store.active);
    try testing.expectEqualStrings("old", store.get(wide("V"), &guid_a).?.data);
}

test "a bank with a bad header CRC is ignored" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 5, valid_mark);
    _ = appendRecord(&flash, 0, bank_header_len, wide("V"), &guid_a, 1, "old");
    writeBankHeader(&flash, 1, 6, valid_mark);
    _ = appendRecord(&flash, 1, bank_header_len, wide("V"), &guid_a, 1, "new");
    flash.data[test_geo.bank_offsets[1] + 4] ^= 0x01;

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expectEqual(@as(u1, 0), store.active);
    try testing.expectEqualStrings("old", store.get(wide("V"), &guid_a).?.data);
}

test "a bank without the valid mark alone loads as fresh" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 1, 2, 0xffff_ffff);
    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.fresh, store.load());
}

test "a record with a bad CRC stops the replay and keeps the earlier records" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    var off: usize = bank_header_len;
    off = appendRecord(&flash, 0, off, wide("A"), &guid_a, 1, "keep");
    const bad_at = off;
    off = appendRecord(&flash, 0, off, wide("B"), &guid_a, 1, "lost");
    _ = appendRecord(&flash, 0, off, wide("C"), &guid_a, 1, "lost too");
    flash.data[bad_at + record_header_len + 4] ^= 0x10;

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(bad_at, store.end);
    try testing.expectEqualStrings("keep", store.get(wide("A"), &guid_a).?.data);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("B"), &guid_a));
    try testing.expectEqual(@as(?Entry, null), store.get(wide("C"), &guid_a));
}

test "a record longer than the limits stops the replay" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    var header: RecordHeader = .{
        .crc = 0,
        .attributes = 1,
        .guid = guid_a,
        .name_len = 4,
        .reserved = 0,
        .data_len = max_data_len + 1,
    };
    header.crc = recordCrc(header, "", "");
    @memcpy(flash.data[off..][0..record_header_len], std.mem.asBytes(&header));

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
    try testing.expectEqualStrings("ok", store.get(wide("A"), &guid_a).?.data);
}

test "a name longer than the limit stops the replay" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    var header: RecordHeader = .{
        .crc = 0,
        .attributes = 1,
        .guid = guid_a,
        .name_len = max_name_units * 2 + 2,
        .reserved = 0,
        .data_len = 0,
    };
    header.crc = recordCrc(header, "", "");
    @memcpy(flash.data[off..][0..record_header_len], std.mem.asBytes(&header));

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
}

test "a record that runs past the end of the bank stops the replay" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const fill: [3980]u8 = @splat(7);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, &fill);
    try testing.expectEqual(test_geo.bank_len - 64, off);
    const header: RecordHeader = .{
        .crc = 0,
        .attributes = 1,
        .guid = guid_a,
        .name_len = 4,
        .reserved = 0,
        .data_len = 100,
    };
    @memcpy(flash.data[off..][0..record_header_len], std.mem.asBytes(&header));

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
    try testing.expectEqual(@as(usize, 3980), store.get(wide("A"), &guid_a).?.data.len);
}

test "a name without a terminator stops the replay" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    const unterminated = wide("AB")[0..2];
    _ = appendRecord(&flash, 0, off, unterminated, &guid_a, 1, "bad");

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
    try testing.expectEqual(@as(?Entry, null), store.get(unterminated, &guid_a));
}

test "a record with a nonzero reserved field stops the replay" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    var header: RecordHeader = .{
        .crc = 0,
        .attributes = 1,
        .guid = guid_a,
        .name_len = 4,
        .reserved = 1,
        .data_len = 0,
    };
    header.crc = recordCrc(header, std.mem.sliceAsBytes(wide("B")), "");
    @memcpy(flash.data[off..][0..record_header_len], std.mem.asBytes(&header));
    @memcpy(flash.data[off + record_header_len ..][0..4], std.mem.sliceAsBytes(wide("B")));

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
}

test "a cut that covers every byte still makes the operation fail" {
    var flash = TestFlash.init(1024);
    flash.cut_at = 0;
    flash.cut_bytes = 8;
    try testing.expect(!flash.program(0, &.{ 0, 0, 0, 0 }));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, flash.data[0..4]);
    try testing.expect(!flash.erase(0));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, flash.data[0..4]);
}

test "garbage after the last record sets needs_compaction" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    flash.data[off + 200] = 0x00;

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, store.load());
    try testing.expect(store.needs_compaction);
    try testing.expectEqual(off, store.end);
    try testing.expectEqualStrings("ok", store.get(wide("A"), &guid_a).?.data);
}

test "a clean log does not set needs_compaction" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    _ = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    var store = TestStore.init(&flash);
    _ = store.load();
    try testing.expect(!store.needs_compaction);
}

test "program only clears bits and erase restores one unit" {
    var flash = TestFlash.init(1024);
    try testing.expect(flash.program(10, &.{0xf0}));
    try testing.expect(flash.program(10, &.{0x3c}));
    try testing.expectEqual(@as(u8, 0x30), flash.data[10]);
    try testing.expect(flash.program(1030, &.{0x00}));
    try testing.expect(flash.erase(1100));
    try testing.expectEqual(@as(u8, 0x30), flash.data[10]);
    try testing.expectEqual(@as(u8, 0xff), flash.data[1030]);
}

test "a cut operation applies part of its bytes and everything after it fails" {
    var flash = TestFlash.init(1024);
    flash.cut_at = 1;
    flash.cut_bytes = 2;
    try testing.expect(flash.program(0, &.{ 0, 0, 0, 0 }));
    try testing.expect(!flash.program(8, &.{ 0, 0, 0, 0 }));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, flash.data[8..12]);
    try testing.expect(!flash.program(16, &.{0}));
    try testing.expectEqual(@as(u8, 0xff), flash.data[16]);
    try testing.expectEqual(@as(usize, 2), flash.ops);
}

test "a cut erase clears only the first bytes of the unit" {
    var flash = TestFlash.init(1024);
    @memset(flash.data[0..1024], 0);
    flash.cut_at = 0;
    flash.cut_bytes = 100;
    try testing.expect(!flash.erase(500));
    try testing.expectEqual(@as(u8, 0xff), flash.data[99]);
    try testing.expectEqual(@as(u8, 0), flash.data[100]);
}
