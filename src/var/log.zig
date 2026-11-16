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
    /// Bytes of RAM for variables without the non-volatile attribute.
    volatile_len: usize = 16 * 1024,
};

pub const LoadResult = enum { fresh, loaded, recovered };

pub const SetError = error{ OutOfResources, DeviceError, InvalidParameter };

/// EFI_VARIABLE_NON_VOLATILE. Only variables with this attribute go to flash.
pub const nv_attribute: u32 = 0x1;

pub const Usage = struct {
    capacity: usize,
    live: usize,
};

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
        return a.hasKey(.{ .name = b.name, .guid = b.guid });
    }

    fn hasKey(rec: Record, key: ?Key) bool {
        const k = key orelse return false;
        return std.mem.eql(u16, rec.name, k.name) and std.mem.eql(u8, rec.guid, k.guid);
    }
};

/// A variable to write. Empty data writes a delete.
const Item = struct {
    name: []const u16,
    guid: *const [16]u8,
    attributes: u32,
    data: []const u8,

    fn key(item: Item) Key {
        return .{ .name = item.name, .guid = item.guid };
    }

    fn len(item: Item) usize {
        return recordLen(item.name.len * 2, item.data.len);
    }
};

/// Writes `item` as a record at the start of `dest`, with erased padding. It returns the record length.
fn writeRecord(dest: []u8, item: Item) usize {
    const name_bytes = std.mem.sliceAsBytes(item.name);
    var header: RecordHeader = .{
        .crc = 0,
        .attributes = item.attributes,
        .guid = item.guid.*,
        .name_len = @intCast(name_bytes.len),
        .reserved = 0,
        .data_len = @intCast(item.data.len),
    };
    header.crc = recordCrc(header, name_bytes, item.data);
    const len = item.len();
    const used = record_header_len + name_bytes.len + item.data.len;
    std.debug.assert(len <= dest.len);
    @memcpy(dest[0..record_header_len], std.mem.asBytes(&header));
    @memcpy(dest[record_header_len..][0..name_bytes.len], name_bytes);
    @memcpy(dest[record_header_len + name_bytes.len ..][0..item.data.len], item.data);
    @memset(dest[used..len], 0xff);
    return len;
}

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

/// The records from `start` to `end` of `bytes`. All of them were checked by `parse` or built here.
const Log = struct {
    bytes: []align(4) const u8,
    start: usize,
    end: usize,

    fn at(log: Log, off: usize) ?Record {
        if (off >= log.end) return null;
        return view(log.bytes, off);
    }

    /// A variable is live when its last record has data.
    fn isLive(log: Log, rec: Record) bool {
        if (rec.data.len == 0) return false;
        var off = rec.offset + rec.len;
        while (log.at(off)) |later| : (off += later.len) {
            if (rec.sameKey(later)) return false;
        }
        return true;
    }

    fn get(log: Log, key: Key) ?Entry {
        var found: ?Entry = null;
        var off = log.start;
        while (log.at(off)) |rec| : (off += rec.len) {
            if (!rec.hasKey(key)) continue;
            found = if (rec.data.len == 0) null else .{ .attributes = rec.attributes, .data = rec.data };
        }
        return found;
    }

    fn next(log: Log, prev: ?Key) ?Key {
        var seen = prev == null;
        var off = log.start;
        while (log.at(off)) |rec| : (off += rec.len) {
            if (!log.isLive(rec)) continue;
            if (!seen) {
                seen = rec.hasKey(prev);
                continue;
            }
            return .{ .name = rec.name, .guid = rec.guid };
        }
        return null;
    }

    /// Bytes of the live records, without the records of `skip`.
    fn liveBytes(log: Log, skip: ?Key) usize {
        var total: usize = 0;
        var off = log.start;
        while (log.at(off)) |rec| : (off += rec.len) {
            if (log.isLive(rec) and !rec.hasKey(skip)) total += rec.len;
        }
        return total;
    }

    /// Copies the live records, without the records of `skip`, to the start of `dest`.
    /// It returns the bytes copied.
    fn pack(log: Log, dest: []u8, skip: ?Key) usize {
        var total: usize = 0;
        var off = log.start;
        while (log.at(off)) |rec| : (off += rec.len) {
            if (!log.isLive(rec) or rec.hasKey(skip)) continue;
            @memcpy(dest[total..][0..rec.len], log.bytes[off..][0..rec.len]);
            total += rec.len;
        }
        return total;
    }
};

fn checkName(name: []const u16) SetError!void {
    if (name.len == 0 or name.len > max_name_units) return error.InvalidParameter;
    if (name[name.len - 1] != 0) return error.InvalidParameter;
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
        // A compaction erases whole units, so a unit must not hold bytes of both banks.
        if (geo.erase_size == 0) @compileError("erase_size must not be 0");
        if (a % geo.erase_size != 0 or b % geo.erase_size != 0) {
            @compileError("the bank offsets must be aligned to erase_size");
        }
        if (geo.volatile_len % record_align != 0) @compileError("volatile_len must be a multiple of 4");
        if (geo.volatile_len > geo.bank_len) @compileError("the volatile area must fit in the scratch image");
    }

    return struct {
        const Self = @This();

        flash: *Flash,
        mirror: [geo.bank_len]u8 align(4),
        /// The image of a bank that a compaction builds before it writes it.
        scratch: [geo.bank_len]u8 align(4),
        /// The records of the volatile variables. They start at offset 0.
        ram: [geo.volatile_len]u8 align(4),
        ram_end: usize,
        active: u1,
        /// 0 when no bank is on flash.
        sequence: u32,
        /// Offset in `mirror` of the first byte after the last good record.
        end: usize,
        /// The log has a torn or bad tail that a compaction must remove.
        needs_compaction: bool,

        pub fn init(flash: *Flash) Self {
            return .{
                .flash = flash,
                .mirror = @splat(0xff),
                .scratch = @splat(0xff),
                .ram = @splat(0xff),
                .ram_end = 0,
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
            // The writer starts at 1, so 0 can mark a store without a bank.
            if (header.sequence == 0) return null;
            return header.sequence;
        }

        pub fn load(self: *Self) LoadResult {
            self.ram_end = 0;
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
            if (!self.needs_compaction) return .loaded;
            // On a flash error `needs_compaction` stays set and the next write tries again.
            self.compact(null, null) catch {};
            return .recovered;
        }

        fn nvLog(self: *const Self) Log {
            return .{ .bytes = &self.mirror, .start = bank_header_len, .end = self.end };
        }

        fn ramLog(self: *const Self) Log {
            return .{ .bytes = &self.ram, .start = 0, .end = self.ram_end };
        }

        /// The name includes its terminator.
        pub fn get(self: *const Self, name: []const u16, guid: *const [16]u8) ?Entry {
            const key: Key = .{ .name = name, .guid = guid };
            return self.nvLog().get(key) orelse self.ramLog().get(key);
        }

        /// Live variables on flash in log order, then the volatile ones in log order.
        /// The order follows the last record of each.
        pub fn next(self: *const Self, prev: ?Key) ?Key {
            const nv = self.nvLog();
            const ram = self.ramLog();
            const p = prev orelse return nv.next(null) orelse ram.next(null);
            if (nv.get(p) != null) return nv.next(p) orelse ram.next(null);
            return ram.next(p);
        }

        /// Writes a variable. The attributes select flash or the volatile area.
        pub fn set(self: *Self, name: []const u16, guid: *const [16]u8, attributes: u32, data: []const u8) SetError!void {
            try checkName(name);
            if (data.len == 0 or data.len > max_data_len) return error.InvalidParameter;
            const item: Item = .{ .name = name, .guid = guid, .attributes = attributes, .data = data };
            const non_volatile = attributes & nv_attribute != 0;
            const here: Log, const other: Log = if (non_volatile)
                .{ self.nvLog(), self.ramLog() }
            else
                .{ self.ramLog(), self.nvLog() };
            if (other.get(item.key()) != null) return error.InvalidParameter;
            if (here.get(item.key())) |live| {
                if (live.attributes == attributes and std.mem.eql(u8, live.data, data)) return;
            }
            if (non_volatile) return self.writeFlash(item);
            return self.writeRam(item);
        }

        /// Deletes a variable. It returns false when the variable does not exist.
        pub fn remove(self: *Self, name: []const u16, guid: *const [16]u8) SetError!bool {
            try checkName(name);
            const item: Item = .{ .name = name, .guid = guid, .attributes = 0, .data = &.{} };
            if (self.nvLog().get(item.key()) != null) {
                try self.writeFlash(item);
                return true;
            }
            if (self.ramLog().get(item.key()) != null) {
                try self.writeRam(item);
                return true;
            }
            return false;
        }

        /// The space for records in a flash bank, and the bytes the live ones use.
        pub fn usage(self: *const Self) Usage {
            return .{ .capacity = geo.bank_len - bank_header_len, .live = self.nvLog().liveBytes(null) };
        }

        fn writeFlash(self: *Self, item: Item) SetError!void {
            const len = item.len();
            if (self.sequence != 0 and !self.needs_compaction and len <= geo.bank_len - self.end) {
                return self.append(item);
            }
            // The compaction drops the old records of the variable and puts the new one in the image.
            const extra: ?Item = if (item.data.len == 0) null else item;
            const extra_len = if (extra == null) 0 else len;
            if (self.nvLog().liveBytes(item.key()) + extra_len > geo.bank_len - bank_header_len) {
                return error.OutOfResources;
            }
            return self.compact(item.key(), extra);
        }

        fn append(self: *Self, item: Item) SetError!void {
            const len = writeRecord(&self.scratch, item);
            if (!self.flash.program(geo.bank_offsets[self.active] + self.end, self.scratch[0..len])) {
                self.needs_compaction = true;
                return error.DeviceError;
            }
            @memcpy(self.mirror[self.end..][0..len], self.scratch[0..len]);
            self.end += len;
        }

        /// Writes the live records, without the records of `skip`, then `extra` to the other bank.
        /// The new bank is used only after its valid mark is on flash.
        fn compact(self: *Self, skip: ?Key, extra: ?Item) SetError!void {
            const sequence = std.math.add(u32, self.sequence, 1) catch return error.DeviceError;
            const target: u1 = if (self.sequence == 0) 0 else ~self.active;
            const header: BankHeader = .{
                .magic = bank_magic,
                .sequence = sequence,
                .crc = bankCrc(sequence),
                .valid = 0xffff_ffff,
            };
            self.scratch = @splat(0xff);
            @memcpy(self.scratch[0..bank_header_len], std.mem.asBytes(&header));
            var end = bank_header_len + self.nvLog().pack(self.scratch[bank_header_len..], skip);
            if (extra) |item| end += writeRecord(self.scratch[end..], item);

            if (!self.writeBank(target, end)) {
                self.needs_compaction = true;
                return error.DeviceError;
            }
            self.mirror = self.scratch;
            self.active = target;
            self.sequence = sequence;
            self.end = end;
            self.needs_compaction = false;
        }

        /// Erases `bank` and programs `scratch` up to `end` into it, the valid mark last.
        fn writeBank(self: *Self, bank: u1, end: usize) bool {
            const base = geo.bank_offsets[bank];
            var off: usize = 0;
            while (off < geo.bank_len) : (off += geo.erase_size) {
                if (!self.flash.erase(base + off)) return false;
            }
            if (!self.flash.program(base, self.scratch[0..bank_header_len])) return false;
            off = bank_header_len;
            while (off < end) {
                const len = view(&self.scratch, off).len;
                if (!self.flash.program(base + off, self.scratch[off..][0..len])) return false;
                off += len;
            }
            return self.flash.program(base + @offsetOf(BankHeader, "valid"), std.mem.asBytes(&valid_mark));
        }

        fn writeRam(self: *Self, item: Item) SetError!void {
            const len = item.len();
            if (len <= geo.volatile_len - self.ram_end) {
                self.ram_end += writeRecord(self.ram[self.ram_end..], item);
                return;
            }
            const extra_len = if (item.data.len == 0) 0 else len;
            const ram = self.ramLog();
            if (ram.liveBytes(item.key()) + extra_len > geo.volatile_len) return error.OutOfResources;
            // Build in `scratch`, because `item.data` can point into `ram`.
            var end = ram.pack(&self.scratch, item.key());
            if (item.data.len != 0) end += writeRecord(self.scratch[end..], item);
            @memcpy(self.ram[0..end], self.scratch[0..end]);
            self.ram_end = end;
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
        /// The full length of the cut operation.
        cut_len: usize = 0,
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
                self.cut_len = n.*;
                n.* = @min(n.*, self.cut_bytes);
            }
            return true;
        }
    };
}

const testing = std.testing;

const test_geo: Geometry = .{
    .bank_offsets = .{ 0, 4096 },
    .bank_len = 4096,
    .erase_size = 1024,
    .volatile_len = 512,
};
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
    const item: Item = .{ .name = name, .guid = guid, .attributes = attributes, .data = data };
    return off + writeRecord(flash.data[test_geo.bank_offsets[bank] + off ..], item);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
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

test "garbage after the last record makes load compact to the other bank" {
    var flash = TestFlash.init(1024);
    writeBankHeader(&flash, 0, 1, valid_mark);
    const off = appendRecord(&flash, 0, bank_header_len, wide("A"), &guid_a, 1, "ok");
    flash.data[off + 200] = 0x00;

    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.recovered, store.load());
    try testing.expect(!store.needs_compaction);
    try testing.expectEqual(off, store.end);
    try testing.expectEqual(@as(u1, 1), store.active);
    try testing.expectEqual(@as(u32, 2), store.sequence);
    try testing.expectEqualStrings("ok", store.get(wide("A"), &guid_a).?.data);

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try testing.expectEqual(@as(u1, 1), again.active);
    try testing.expectEqualStrings("ok", again.get(wide("A"), &guid_a).?.data);
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

fn expectData(store: *const TestStore, name: []const u16, guid: *const [16]u8, data: []const u8) !void {
    const entry = store.get(name, guid) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings(data, entry.data);
}

fn clearCut(flash: *TestFlash) void {
    flash.cut_at = null;
    flash.dead = false;
}

test "set, get, replace and remove on a fresh flash survive a reload" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.fresh, store.load());
    try store.set(wide("A"), &guid_a, nv_attribute, "one");
    try testing.expectEqual(@as(u1, 0), store.active);
    try testing.expectEqual(@as(u32, 1), store.sequence);
    try store.set(wide("B"), &guid_a, nv_attribute | 0x6, "two");
    try store.set(wide("A"), &guid_a, nv_attribute, "uno");
    try testing.expect(try store.remove(wide("B"), &guid_a));
    try store.set(wide("C"), &guid_b, nv_attribute, "three");
    try testing.expectEqual(@as(u32, 1), store.sequence);

    try expectData(&store, wide("A"), &guid_a, "uno");
    try testing.expectEqual(@as(?Entry, null), store.get(wide("B"), &guid_a));
    try expectData(&store, wide("C"), &guid_b, "three");

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try testing.expectEqual(store.end, again.end);
    try expectData(&again, wide("A"), &guid_a, "uno");
    try testing.expectEqual(nv_attribute, again.get(wide("A"), &guid_a).?.attributes);
    try testing.expectEqual(@as(?Entry, null), again.get(wide("B"), &guid_a));
    try expectData(&again, wide("C"), &guid_b, "three");
    const first = again.next(null).?;
    try testing.expectEqualSlices(u16, wide("A"), first.name);
    const second = again.next(first).?;
    try testing.expectEqualSlices(u16, wide("C"), second.name);
    try testing.expectEqual(@as(?Key, null), again.next(second));
}

test "replacing one variable until the bank is full compacts and keeps every variable" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("B"), &guid_a, nv_attribute, "bravo");
    try store.set(wide("C"), &guid_b, nv_attribute, "charlie");

    var n: u8 = 0;
    while (store.sequence == 1) : (n += 1) {
        try testing.expect(n < 100);
        const value: [100]u8 = @splat(n);
        try store.set(wide("F"), &guid_a, nv_attribute, &value);
    }
    try testing.expectEqual(@as(u32, 2), store.sequence);
    try testing.expectEqual(@as(u1, 1), store.active);
    const last: [100]u8 = @splat(n - 1);
    try expectData(&store, wide("F"), &guid_a, &last);
    try expectData(&store, wide("B"), &guid_a, "bravo");
    try expectData(&store, wide("C"), &guid_b, "charlie");
    const live = recordLen(4, 5) + recordLen(4, 7) + recordLen(4, 100);
    try testing.expectEqual(bank_header_len + live, store.end);

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try testing.expectEqual(@as(u32, 2), again.sequence);
    try expectData(&again, wide("F"), &guid_a, &last);
    try expectData(&again, wide("B"), &guid_a, "bravo");
    try expectData(&again, wide("C"), &guid_b, "charlie");
}

test "set gives OutOfResources when live data fills the bank and changes nothing" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    const big: [3000]u8 = @splat(1);
    try store.set(wide("A"), &guid_a, nv_attribute, &big);
    const before = store.usage();
    const ops = flash.ops;

    const other: [1100]u8 = @splat(2);
    try testing.expectError(error.OutOfResources, store.set(wide("B"), &guid_a, nv_attribute, &other));
    try testing.expectEqual(ops, flash.ops);
    try testing.expectEqual(before, store.usage());
    try testing.expectEqual(@as(u32, 1), store.sequence);
    try expectData(&store, wide("A"), &guid_a, &big);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("B"), &guid_a));

    // The new value fits once the old one is dropped.
    const bigger: [3500]u8 = @splat(3);
    try store.set(wide("A"), &guid_a, nv_attribute, &bigger);
    try testing.expectEqual(@as(u32, 2), store.sequence);
    try expectData(&store, wide("A"), &guid_a, &bigger);
}

test "usage gives the bank capacity and the bytes of live records" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try testing.expectEqual(Usage{ .capacity = 4080, .live = 0 }, store.usage());
    try store.set(wide("A"), &guid_a, nv_attribute, "abc");
    try store.set(wide("A"), &guid_a, nv_attribute, "abcdefgh");
    try store.set(wide("V"), &guid_a, 0x6, "ram");
    try testing.expectEqual(Usage{ .capacity = 4080, .live = recordLen(4, 8) }, store.usage());
}

test "volatile variables are in get and next, use no flash and are gone after a reload" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("A"), &guid_a, nv_attribute, "disk");
    const ops = flash.ops;

    try store.set(wide("V"), &guid_a, 0x6, "ram");
    try store.set(wide("W"), &guid_a, 0x2, "ram two");
    try store.set(wide("V"), &guid_a, 0x6, "ram three");
    try testing.expect(try store.remove(wide("W"), &guid_a));
    try testing.expectEqual(ops, flash.ops);

    const v = store.get(wide("V"), &guid_a).?;
    try testing.expectEqual(@as(u32, 0x6), v.attributes);
    try testing.expectEqualStrings("ram three", v.data);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("W"), &guid_a));
    const first = store.next(null).?;
    try testing.expectEqualSlices(u16, wide("A"), first.name);
    const second = store.next(first).?;
    try testing.expectEqualSlices(u16, wide("V"), second.name);
    try testing.expectEqual(@as(?Key, null), store.next(second));

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try testing.expectEqual(@as(?Entry, null), again.get(wide("V"), &guid_a));
    try expectData(&again, wide("A"), &guid_a, "disk");
}

test "next starts in the volatile area when no variable is on flash" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("V"), &guid_a, 0x6, "ram");
    const first = store.next(null).?;
    try testing.expectEqualSlices(u16, wide("V"), first.name);
    try testing.expectEqual(@as(?Key, null), store.next(first));
    try testing.expectEqual(@as(usize, 0), flash.ops);
}

test "the volatile area compacts when it is full and keeps the live variables" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("K"), &guid_a, 0x6, "kept");
    var n: u8 = 0;
    while (n < 40) : (n += 1) {
        const value: [64]u8 = @splat(n);
        try store.set(wide("V"), &guid_a, 0x6, &value);
    }
    const last: [64]u8 = @splat(39);
    try expectData(&store, wide("V"), &guid_a, &last);
    try expectData(&store, wide("K"), &guid_a, "kept");
    try testing.expectEqual(@as(usize, 0), flash.ops);

    const big: [400]u8 = @splat(1);
    try testing.expectError(error.OutOfResources, store.set(wide("W"), &guid_a, 0x6, &big));
    try expectData(&store, wide("V"), &guid_a, &last);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("W"), &guid_a));
}

test "set with the same attributes and data writes nothing" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("A"), &guid_a, nv_attribute, "same");
    const ops = flash.ops;
    const end = store.end;
    try store.set(wide("A"), &guid_a, nv_attribute, "same");
    try testing.expectEqual(ops, flash.ops);
    try testing.expectEqual(end, store.end);
    try store.set(wide("A"), &guid_a, nv_attribute | 0x2, "same");
    try testing.expectEqual(ops + 1, flash.ops);
    try testing.expectEqual(nv_attribute | 0x2, store.get(wide("A"), &guid_a).?.attributes);
}

test "set gives InvalidParameter when the attributes move a variable between the areas" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("A"), &guid_a, nv_attribute, "disk");
    try store.set(wide("V"), &guid_a, 0x6, "ram");
    const ops = flash.ops;
    try testing.expectError(error.InvalidParameter, store.set(wide("A"), &guid_a, 0x6, "ram"));
    try testing.expectError(error.InvalidParameter, store.set(wide("V"), &guid_a, nv_attribute, "disk"));
    try testing.expectEqual(ops, flash.ops);
    try expectData(&store, wide("A"), &guid_a, "disk");
    try expectData(&store, wide("V"), &guid_a, "ram");

    // After a remove the name is free for the other area.
    try testing.expect(try store.remove(wide("V"), &guid_a));
    try store.set(wide("V"), &guid_a, nv_attribute, "disk now");
    try expectData(&store, wide("V"), &guid_a, "disk now");
}

test "set and remove reject a bad name and set rejects bad data lengths" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    const unterminated = wide("AB")[0..2];
    try testing.expectError(error.InvalidParameter, store.set(unterminated, &guid_a, nv_attribute, "x"));
    try testing.expectError(error.InvalidParameter, store.set(&.{}, &guid_a, nv_attribute, "x"));
    const long_name: [max_name_units + 1]u16 = @splat(0);
    try testing.expectError(error.InvalidParameter, store.set(&long_name, &guid_a, nv_attribute, "x"));
    try testing.expectError(error.InvalidParameter, store.set(wide("A"), &guid_a, nv_attribute, ""));
    const too_long: [max_data_len + 1]u8 = @splat(0);
    try testing.expectError(error.InvalidParameter, store.set(wide("A"), &guid_a, nv_attribute, &too_long));
    try testing.expectError(error.InvalidParameter, store.remove(unterminated, &guid_a));
    try testing.expectEqual(@as(usize, 0), flash.ops);
}

test "remove gives false for a missing variable and writes nothing" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try testing.expect(!try store.remove(wide("A"), &guid_a));
    try store.set(wide("A"), &guid_a, nv_attribute, "x");
    const ops = flash.ops;
    try testing.expect(!try store.remove(wide("A"), &guid_b));
    try testing.expectEqual(ops, flash.ops);
}

test "remove of a variable when the bank is full compacts it away" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("B"), &guid_a, nv_attribute, "bravo");
    const big: [4000]u8 = @splat(1);
    try store.set(wide("A"), &guid_a, nv_attribute, &big);
    try testing.expect(bankRemaining(&store) < recordLen(4, 0));
    try testing.expect(try store.remove(wide("A"), &guid_a));
    try testing.expectEqual(@as(u32, 2), store.sequence);
    try testing.expectEqual(@as(?Entry, null), store.get(wide("A"), &guid_a));
    try expectData(&store, wide("B"), &guid_a, "bravo");
    try testing.expectEqual(bank_header_len + recordLen(4, 5), store.end);
}

fn bankRemaining(store: *const TestStore) usize {
    return test_geo.bank_len - store.end;
}

test "a flash error in set gives DeviceError and the next set compacts first" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("A"), &guid_a, nv_attribute, "one");
    flash.cut_at = flash.ops;
    flash.cut_bytes = 0;
    try testing.expectError(error.DeviceError, store.set(wide("A"), &guid_a, nv_attribute, "two"));
    try testing.expect(store.needs_compaction);
    try expectData(&store, wide("A"), &guid_a, "one");

    clearCut(&flash);
    try store.set(wide("B"), &guid_a, nv_attribute, "bravo");
    try testing.expect(!store.needs_compaction);
    try testing.expectEqual(@as(u32, 2), store.sequence);
    try testing.expectEqual(@as(u1, 1), store.active);

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try expectData(&again, wide("A"), &guid_a, "one");
    try expectData(&again, wide("B"), &guid_a, "bravo");
}

test "a torn append followed by a reload gives recovered" {
    var flash = TestFlash.init(1024);
    var store = TestStore.init(&flash);
    _ = store.load();
    try store.set(wide("A"), &guid_a, nv_attribute, "one");
    flash.cut_at = flash.ops;
    flash.cut_bytes = 10;
    try testing.expectError(error.DeviceError, store.set(wide("A"), &guid_a, nv_attribute, "two"));
    clearCut(&flash);

    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.recovered, again.load());
    try testing.expect(!again.needs_compaction);
    try testing.expectEqual(@as(u32, 2), again.sequence);
    try expectData(&again, wide("A"), &guid_a, "one");

    var third = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, third.load());
    try expectData(&third, wide("A"), &guid_a, "one");
}

/// Which of the two allowed values a reload found.
const Seen = enum { old, new };

const SweepCount = struct {
    points: usize = 0,
    old: usize = 0,
    new: usize = 0,
};

/// Cuts operation `index` of `S.run` after `cut_bytes` bytes, then reloads and checks the store.
/// It returns the full length of the cut operation, or null when `S.run` has no such operation.
fn cutOnce(comptime S: type, index: usize, cut_bytes: usize, count: *SweepCount) !?usize {
    var flash = TestFlash.init(test_geo.erase_size);
    var store = TestStore.init(&flash);
    _ = store.load();
    try S.prepare(&store);
    flash.cut_at = flash.ops + index;
    flash.cut_bytes = cut_bytes;
    S.run(&store);
    if (!flash.dead) return null;
    const len = flash.cut_len;
    clearCut(&flash);

    var after = TestStore.init(&flash);
    _ = after.load();
    const seen = try S.check(&after);
    try after.set(wide("After"), &guid_b, nv_attribute, "after");
    var again = TestStore.init(&flash);
    try testing.expectEqual(LoadResult.loaded, again.load());
    try testing.expectEqual(seen, try S.check(&again));
    try expectData(&again, wide("After"), &guid_b, "after");

    count.points += 1;
    switch (seen) {
        .old => count.old += 1,
        .new => count.new += 1,
    }
    return len;
}

/// Cuts every operation of `S.run` in turn. With `every_byte` it tries each byte count
/// from 0 to the full length, else 0, 1, half and all but one.
fn sweep(comptime S: type, every_byte: bool) !SweepCount {
    var count: SweepCount = .{};
    var index: usize = 0;
    while (try cutOnce(S, index, 0, &count)) |len| : (index += 1) {
        if (every_byte) {
            var bytes: usize = 1;
            while (bytes <= len) : (bytes += 1) _ = try cutOnce(S, index, bytes, &count);
            continue;
        }
        var last: usize = 0;
        for ([_]usize{ 1, len / 2, len - 1 }) |bytes| {
            if (bytes <= last or bytes >= len) continue;
            last = bytes;
            _ = try cutOnce(S, index, bytes, &count);
        }
    }
    return count;
}

/// The count of flash operations in `S.run` without a cut.
fn opCount(comptime S: type) !usize {
    var flash = TestFlash.init(test_geo.erase_size);
    var store = TestStore.init(&flash);
    _ = store.load();
    try S.prepare(&store);
    const before = flash.ops;
    S.run(&store);
    return flash.ops - before;
}

const base_vars = [_]struct { name: []const u16, data: []const u8 }{
    .{ .name = wide("B"), .data = "bravo" },
    .{ .name = wide("C"), .data = "charlie" },
    .{ .name = wide("D"), .data = "delta" },
};

fn setBase(store: *TestStore) !void {
    try store.set(wide("A"), &guid_a, nv_attribute, "old");
    for (base_vars) |v| try store.set(v.name, &guid_a, nv_attribute, v.data);
}

/// Checks the base variables and gives which value `A` has. A null `new` means a delete.
fn checkBase(store: *const TestStore, new: ?[]const u8) !Seen {
    for (base_vars) |v| try expectData(store, v.name, &guid_a, v.data);
    const a = store.get(wide("A"), &guid_a);
    if (a) |entry| {
        if (std.mem.eql(u8, entry.data, "old")) return .old;
        if (new != null and std.mem.eql(u8, entry.data, new.?)) return .new;
        return error.TestUnexpectedResult;
    }
    return if (new == null) .new else error.TestUnexpectedResult;
}

const AppendSet = struct {
    const prepare = setBase;
    fn run(store: *TestStore) void {
        store.set(wide("A"), &guid_a, nv_attribute, "new value") catch {};
    }
    fn check(store: *const TestStore) !Seen {
        return checkBase(store, "new value");
    }
};

const AppendRemove = struct {
    const prepare = setBase;
    fn run(store: *TestStore) void {
        _ = store.remove(wide("A"), &guid_a) catch false;
    }
    fn check(store: *const TestStore) !Seen {
        return checkBase(store, null);
    }
};

test "a power loss at any byte of an append keeps the old or the new value" {
    const count = try sweep(AppendSet, true);
    try testing.expectEqual(@as(usize, 1), try opCount(AppendSet));
    try testing.expectEqual(recordLen(4, 9) + 1, count.points);
    try testing.expect(count.old > 0 and count.new > 0);
}

test "a power loss at any byte of a delete keeps the variable or removes it" {
    const count = try sweep(AppendRemove, true);
    try testing.expectEqual(@as(usize, 1), try opCount(AppendRemove));
    try testing.expectEqual(recordLen(4, 0) + 1, count.points);
    try testing.expect(count.old > 0 and count.new > 0);
}

/// Fills both banks once, so the compaction under test erases an older valid bank.
const CompactSet = struct {
    const f_len = 120;
    var f_last: [f_len]u8 = undefined;

    fn prepare(store: *TestStore) !void {
        try setBase(store);
        const f_rec_len = recordLen(4, f_len);
        var n: u8 = 0;
        while (store.sequence < 2 or test_geo.bank_len - store.end >= f_rec_len) : (n += 1) {
            try testing.expect(n < 200);
            f_last = @splat(n);
            try store.set(wide("F"), &guid_a, nv_attribute, &f_last);
        }
        try testing.expectEqual(@as(u32, 2), store.sequence);
        try testing.expect(test_geo.bank_len - store.end < recordLen(4, new_value.len));
    }
    const new_value: [160]u8 = @splat(0x5a);
    fn run(store: *TestStore) void {
        store.set(wide("A"), &guid_a, nv_attribute, &new_value) catch {};
    }
    fn check(store: *const TestStore) !Seen {
        try expectData(store, wide("F"), &guid_a, &f_last);
        return checkBase(store, &new_value);
    }
};

test "a power loss in a compaction keeps the old value and every other variable" {
    const ops = try opCount(CompactSet);
    // Four erase units, the header, five records and the valid mark.
    try testing.expectEqual(@as(usize, 4 + 1 + 5 + 1), ops);
    const count = try sweep(CompactSet, false);
    try testing.expectEqual(ops * 4, count.points);
    try testing.expectEqual(@as(usize, 0), count.new);
}

/// Leaves garbage after the last record, so `load` starts a compaction.
const LoadRecovery = struct {
    fn prepare(store: *TestStore) !void {
        try setBase(store);
        const junk: [8]u8 = @splat(0);
        try testing.expect(store.flash.program(test_geo.bank_offsets[store.active] + store.end + 40, &junk));
    }
    fn run(store: *TestStore) void {
        _ = store.load();
    }
    fn check(store: *const TestStore) !Seen {
        return checkBase(store, "old");
    }
};

test "a power loss in the compaction that load starts is recovered on the next load" {
    const ops = try opCount(LoadRecovery);
    try testing.expectEqual(@as(usize, 4 + 1 + 4 + 1), ops);
    const count = try sweep(LoadRecovery, false);
    try testing.expectEqual(ops * 4, count.points);
}

const FirstSet = struct {
    fn prepare(store: *TestStore) !void {
        _ = store;
    }
    fn run(store: *TestStore) void {
        store.set(wide("A"), &guid_a, nv_attribute, "first") catch {};
    }
    fn check(store: *const TestStore) !Seen {
        const a = store.get(wide("A"), &guid_a) orelse return .old;
        try testing.expectEqualStrings("first", a.data);
        return .new;
    }
};

test "a power loss while the first set creates bank 0 leaves an empty store" {
    const ops = try opCount(FirstSet);
    try testing.expectEqual(@as(usize, 4 + 1 + 1 + 1), ops);
    const count = try sweep(FirstSet, false);
    try testing.expectEqual(ops * 4, count.points);
    try testing.expectEqual(@as(usize, 0), count.new);
}
