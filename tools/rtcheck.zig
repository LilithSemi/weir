//! Build-time check of the EFI runtime region in the linked firmware ELF.
//! The OS maps only `.rt_text` and `.rt_data` and calls the code there with
//! its own gp and tp. So the code in `.rt_text` must not jump out of it, must
//! not make an address outside the two sections, and must not touch gp or tp.
//!
//! Usage: rtcheck <elf>
//!
//! The check decodes each function in `.rt_text`, or the full section when the
//! ELF has no symbols, in address order. It follows
//! the value of each register that auipc or lui sets, and checks the address
//! when a jump, a load, a store or an addi uses that value. A register that
//! holds an auipc value and is used in any other way is an error. The check
//! does not follow branches, so it does not see values that join from two paths.

const std = @import("std");

const page = 0x1000;

const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const Shdr = extern struct {
    name: u32,
    type: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

const Sym = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,
};

const sht_symtab = 2;
const sht_nobits = 8;
const stt_object = 1;
const stt_func = 2;
const em_riscv = 243;

const Range = struct {
    start: u64,
    end: u64,

    fn has(r: Range, addr: u64) bool {
        return addr >= r.start and addr < r.end;
    }
};

const Region = struct {
    text: Range,
    data: Range,

    fn hasAddress(r: Region, addr: u64) bool {
        return r.text.has(addr) or r.data.has(addr);
    }
};

const Origin = enum { none, auipc, constant };

const Value = struct {
    origin: Origin = .none,
    value: u64 = 0,
};

const Checker = struct {
    region: Region,
    function: []const u8,
    regs: [32]Value = @splat(.{}),
    errors: usize = 0,

    fn fail(c: *Checker, pc: u64, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("rtcheck: {s} at {x}: " ++ fmt ++ "\n", .{ c.function, pc } ++ args);
        c.errors += 1;
    }

    /// Reads `reg` as a plain value. An auipc value used this way is an address
    /// the check cannot follow.
    fn readPlain(c: *Checker, pc: u64, reg: u5) void {
        if (reg == 3 or reg == 4) c.fail(pc, "uses gp or tp (x{d})", .{reg});
        if (c.regs[reg].origin == .auipc) c.fail(pc, "uses an auipc value in x{d} with no low part", .{reg});
    }

    fn write(c: *Checker, pc: u64, reg: u5, value: Value) void {
        if (reg == 0) return;
        if (reg == 3 or reg == 4) c.fail(pc, "writes gp or tp (x{d})", .{reg});
        c.regs[reg] = value;
    }

    /// A load, store or atomic access at `imm(base)`.
    fn access(c: *Checker, pc: u64, base: u5, imm: i64) void {
        if (base == 3 or base == 4) c.fail(pc, "uses gp or tp (x{d})", .{base});
        const v = c.regs[base];
        if (v.origin == .none) return;
        const addr = v.value +% @as(u64, @bitCast(imm));
        if (!c.region.hasAddress(addr)) c.fail(pc, "accesses {x}, outside the runtime region", .{addr});
    }

    /// addi, or c.addi, on `src`.
    fn addImmediate(c: *Checker, pc: u64, dest: u5, src: u5, imm: i64) void {
        if (src == 3 or src == 4) c.fail(pc, "uses gp or tp (x{d})", .{src});
        const v = c.regs[src];
        if (v.origin == .none) return c.write(pc, dest, .{});
        const sum = v.value +% @as(u64, @bitCast(imm));
        if (v.origin == .auipc and !c.region.hasAddress(sum)) {
            c.fail(pc, "makes the address {x}, outside the runtime region", .{sum});
        }
        // The full address is now in `dest`. Later uses are pointer arithmetic.
        c.write(pc, dest, if (v.origin == .constant) .{ .origin = .constant, .value = sum } else .{});
    }

    fn jumpTarget(c: *Checker, pc: u64, target: u64) void {
        if (!c.region.text.has(target)) c.fail(pc, "jumps to {x}, outside .rt_text", .{target});
    }

    /// jalr, c.jr or c.jalr through `base`.
    fn jumpRegister(c: *Checker, pc: u64, link: u5, base: u5, imm: i64) void {
        const v = c.regs[base];
        const is_return = link == 0 and base == 1 and imm == 0 and v.origin == .none;
        if (v.origin != .none) {
            c.jumpTarget(pc, v.value +% @as(u64, @bitCast(imm)));
        } else if (!is_return) {
            c.fail(pc, "jumps through x{d} to an address the check cannot see", .{base});
        }
        c.write(pc, link, .{});
        // Only a branch reaches the code after a return, so the values are unknown there.
        if (is_return) c.regs = @splat(.{});
    }
};

fn bits(word: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (word >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

fn signExtend(value: u64, comptime width: u7) i64 {
    const shift: u6 = @intCast(64 - width);
    return @as(i64, @bitCast(value << shift)) >> shift;
}

fn regAt(word: u32, comptime lo: u5) u5 {
    return @intCast(bits(word, lo + 4, lo));
}

fn regPrime(word: u32, comptime lo: u5) u5 {
    return @intCast(8 + bits(word, lo + 2, lo));
}

fn checkWide(c: *Checker, pc: u64, w: u32) void {
    const rd = regAt(w, 7);
    const rs1 = regAt(w, 15);
    const rs2 = regAt(w, 20);
    const imm_i = signExtend(bits(w, 31, 20), 12);
    const imm_s = signExtend(bits(w, 31, 25) << 5 | bits(w, 11, 7), 12);
    const imm_u = signExtend(@as(u64, w & 0xfffff000), 32);
    switch (bits(w, 6, 0)) {
        0x37 => c.write(pc, rd, .{ .origin = .constant, .value = @bitCast(imm_u) }),
        0x17 => c.write(pc, rd, .{ .origin = .auipc, .value = pc +% @as(u64, @bitCast(imm_u)) }),
        0x6f => {
            const imm = bits(w, 31, 31) << 20 | bits(w, 19, 12) << 12 | bits(w, 20, 20) << 11 | bits(w, 30, 21) << 1;
            c.jumpTarget(pc, pc +% @as(u64, @bitCast(signExtend(imm, 21))));
            c.write(pc, rd, .{});
        },
        0x67 => c.jumpRegister(pc, rd, rs1, imm_i),
        0x63 => {
            c.readPlain(pc, rs1);
            c.readPlain(pc, rs2);
            const imm = bits(w, 31, 31) << 12 | bits(w, 7, 7) << 11 | bits(w, 30, 25) << 5 | bits(w, 11, 8) << 1;
            c.jumpTarget(pc, pc +% @as(u64, @bitCast(signExtend(imm, 13))));
        },
        0x03 => {
            c.access(pc, rs1, imm_i);
            c.write(pc, rd, .{});
        },
        0x23 => {
            c.access(pc, rs1, imm_s);
            c.readPlain(pc, rs2);
        },
        0x13 => if (bits(w, 14, 12) == 0) c.addImmediate(pc, rd, rs1, imm_i) else {
            c.readPlain(pc, rs1);
            c.write(pc, rd, .{});
        },
        0x1b => {
            c.readPlain(pc, rs1);
            c.write(pc, rd, .{});
        },
        0x33, 0x3b => {
            c.readPlain(pc, rs1);
            c.readPlain(pc, rs2);
            c.write(pc, rd, .{});
        },
        0x2f => {
            c.access(pc, rs1, 0);
            c.readPlain(pc, rs2);
            c.write(pc, rd, .{});
        },
        0x0f => {},
        // ecall, ebreak and unimp only. A CSR access has no place here.
        0x73 => if (w != 0x00000073 and w != 0x00100073 and w != 0xc0001073) {
            c.fail(pc, "system instruction {x:0>8}", .{w});
        },
        else => c.fail(pc, "unknown instruction {x:0>8}", .{w}),
    }
}

fn checkCompressed(c: *Checker, pc: u64, h: u16) void {
    const w: u32 = h;
    const imm6 = signExtend(bits(w, 12, 12) << 5 | bits(w, 6, 2), 6);
    const rd = regAt(w, 7);
    const rs2 = regAt(w, 2);
    switch (bits(w, 1, 0) << 3 | bits(w, 15, 13)) {
        // Quadrant 0. All zero bits is the unimp trap.
        0b00_000 => if (h != 0) c.write(pc, regPrime(w, 2), .{}),
        0b00_010, 0b00_011 => {
            c.access(pc, regPrime(w, 7), 0);
            c.write(pc, regPrime(w, 2), .{});
        },
        0b00_110, 0b00_111 => {
            c.access(pc, regPrime(w, 7), 0);
            c.readPlain(pc, regPrime(w, 2));
        },
        // Quadrant 1.
        0b01_000 => c.addImmediate(pc, rd, rd, imm6),
        0b01_001 => {
            c.readPlain(pc, rd);
            c.write(pc, rd, .{});
        },
        // c.li gives a value from -32 to 31, which is no address.
        0b01_010 => c.write(pc, rd, .{}),
        0b01_011 => if (rd == 2) {
            c.write(pc, 2, .{});
        } else {
            c.write(pc, rd, .{ .origin = .constant, .value = @bitCast(imm6 << 12) });
        },
        0b01_100 => {
            const dest = regPrime(w, 7);
            c.readPlain(pc, dest);
            if (bits(w, 11, 10) == 3) c.readPlain(pc, regPrime(w, 2));
            c.write(pc, dest, .{});
        },
        0b01_101 => {
            const imm = bits(w, 12, 12) << 11 | bits(w, 8, 8) << 10 | bits(w, 10, 9) << 8 | bits(w, 6, 6) << 7 |
                bits(w, 7, 7) << 6 | bits(w, 2, 2) << 5 | bits(w, 11, 11) << 4 | bits(w, 5, 3) << 1;
            c.jumpTarget(pc, pc +% @as(u64, @bitCast(signExtend(imm, 12))));
        },
        0b01_110, 0b01_111 => {
            c.readPlain(pc, regPrime(w, 7));
            const imm = bits(w, 12, 12) << 8 | bits(w, 6, 5) << 6 | bits(w, 2, 2) << 5 | bits(w, 11, 10) << 3 | bits(w, 4, 3) << 1;
            c.jumpTarget(pc, pc +% @as(u64, @bitCast(signExtend(imm, 9))));
        },
        // Quadrant 2.
        0b10_000 => {
            c.readPlain(pc, rd);
            c.write(pc, rd, .{});
        },
        0b10_010, 0b10_011 => c.write(pc, rd, .{}),
        0b10_100 => {
            const high = bits(w, 12, 12) == 1;
            if (rs2 == 0) {
                if (high and rd == 0) return; // c.ebreak
                c.jumpRegister(pc, if (high) 1 else 0, rd, 0);
            } else {
                if (high) c.readPlain(pc, rd);
                c.readPlain(pc, rs2);
                c.write(pc, rd, .{});
            }
        },
        0b10_110, 0b10_111 => c.readPlain(pc, rs2),
        else => c.fail(pc, "unknown instruction {x:0>4}", .{h}),
    }
}

fn checkFunction(c: *Checker, code: []const u8, start: u64) void {
    c.regs = @splat(.{});
    var off: usize = 0;
    while (off + 2 <= code.len) {
        const pc = start + off;
        const low = std.mem.readInt(u16, code[off..][0..2], .little);
        if (low & 3 != 3) {
            checkCompressed(c, pc, low);
            off += 2;
        } else if (off + 4 <= code.len) {
            checkWide(c, pc, std.mem.readInt(u32, code[off..][0..4], .little));
            off += 4;
        } else {
            c.fail(pc, "instruction past the end of the function", .{});
            return;
        }
    }
}

fn cString(table: []const u8, offset: u32) []const u8 {
    if (offset >= table.len) return "";
    return std.mem.sliceTo(table[offset..], 0);
}

fn read(comptime T: type, bytes: []const u8, offset: u64) !T {
    if (offset > bytes.len or bytes.len - offset < @sizeOf(T)) return error.Truncated;
    return std.mem.bytesToValue(T, bytes[@intCast(offset)..][0..@sizeOf(T)]);
}

fn sectionBytes(elf: []const u8, s: Shdr) ![]const u8 {
    if (s.offset > elf.len or elf.len - s.offset < s.size) return error.Truncated;
    return elf[@intCast(s.offset)..][0..@intCast(s.size)];
}

fn pageRange(name: []const u8, s: Shdr) !Range {
    if (s.addr % page != 0 or s.size % page != 0) {
        std.debug.print("rtcheck: {s} at {x}, size {x}, is not whole pages\n", .{ name, s.addr, s.size });
        return error.NotPageAligned;
    }
    return .{ .start = s.addr, .end = s.addr + s.size };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // zippy:ignore discarded_error -- the tool ignores the program name arg
    const elf_path = args.next() orelse return error.Usage;

    const elf = try std.Io.Dir.cwd().readFileAlloc(io, elf_path, gpa, .unlimited);
    defer gpa.free(elf);

    const eh = try read(Ehdr, elf, 0);
    if (!std.mem.eql(u8, eh.ident[0..4], "\x7fELF") or eh.ident[4] != 2 or eh.machine != em_riscv)
        return error.NotRiscv64Elf;
    if (eh.shentsize != @sizeOf(Shdr)) return error.BadSectionHeader;

    const names = try sectionBytes(elf, try read(Shdr, elf, eh.shoff + @as(u64, eh.shstrndx) * @sizeOf(Shdr)));
    var text: ?Shdr = null;
    var text_index: u16 = 0;
    var data: ?Shdr = null;
    var symtab: ?Shdr = null;
    for (0..eh.shnum) |i| {
        const s = try read(Shdr, elf, eh.shoff + i * @sizeOf(Shdr));
        const name = cString(names, s.name);
        if (std.mem.eql(u8, name, ".rt_text")) {
            text = s;
            text_index = @intCast(i);
        } else if (std.mem.eql(u8, name, ".rt_data")) {
            data = s;
        } else if (s.type == sht_symtab) {
            symtab = s;
        }
    }
    const text_shdr = text orelse return error.NoRtText;
    const data_shdr = data orelse return error.NoRtData;
    if (data_shdr.type != sht_nobits) {
        std.debug.print("rtcheck: .rt_data takes space in the image\n", .{});
        return error.RtDataLoaded;
    }

    const region: Region = .{
        .text = try pageRange(".rt_text", text_shdr),
        .data = try pageRange(".rt_data", data_shdr),
    };
    if (region.text.end != region.data.start) {
        std.debug.print("rtcheck: .rt_data starts at {x}, .rt_text ends at {x}\n", .{ region.data.start, region.text.end });
        return error.RegionNotAdjacent;
    }
    const code = try sectionBytes(elf, text_shdr);
    var checker: Checker = .{ .region = region, .function = ".rt_text" };

    // With no runtime data, the build left out the EFI services and the region is empty.
    const has_code = std.mem.indexOfNone(u8, code, &.{0}) != null;
    if (!has_code) {
        if (region.data.start == region.data.end) return;
        std.debug.print("rtcheck: .rt_text holds no code\n", .{});
        std.process.exit(1);
    }

    if (symtab) |symtab_shdr| {
        try checkSymbols(gpa, &checker, elf, eh, symtab_shdr, text_index, code);
    } else {
        // A release build has no symbols. Decode the section as one function.
        // The padding after the code is zero, which decodes as unimp.
        checkFunction(&checker, code, region.text.start);
    }
    if (checker.errors != 0) {
        std.debug.print("rtcheck: {d} error(s) in the EFI runtime region\n", .{checker.errors});
        std.process.exit(1);
    }
}

fn checkSymbols(
    gpa: std.mem.Allocator,
    checker: *Checker,
    elf: []const u8,
    eh: Ehdr,
    symtab_shdr: Shdr,
    text_index: u16,
    code: []const u8,
) !void {
    const strtab = try sectionBytes(elf, try read(Shdr, elf, eh.shoff + @as(u64, symtab_shdr.link) * @sizeOf(Shdr)));
    const syms = try sectionBytes(elf, symtab_shdr);
    const start = checker.region.text.start;

    // Bytes that no function or object covers must be padding.
    const covered = try gpa.alloc(bool, code.len);
    defer gpa.free(covered);
    @memset(covered, false);

    var i: usize = 0;
    while (i + @sizeOf(Sym) <= syms.len) : (i += @sizeOf(Sym)) {
        const sym = std.mem.bytesToValue(Sym, syms[i..][0..@sizeOf(Sym)]);
        const kind = sym.info & 0xf;
        if (sym.shndx != text_index or sym.size == 0) continue;
        if (kind != stt_func and kind != stt_object) continue;
        if (sym.value < start or sym.value + sym.size > start + code.len) {
            std.debug.print("rtcheck: symbol {s} is outside .rt_text\n", .{cString(strtab, sym.name)});
            checker.errors += 1;
            continue;
        }
        const off: usize = @intCast(sym.value - start);
        const len: usize = @intCast(sym.size);
        @memset(covered[off..][0..len], true);
        if (kind == stt_func) {
            checker.function = cString(strtab, sym.name);
            checkFunction(checker, code[off..][0..len], sym.value);
        }
    }
    for (code, covered, 0..) |byte, is_covered, off| {
        if (!is_covered and byte != 0) {
            std.debug.print("rtcheck: byte {x} at {x} is in no function\n", .{ byte, start + off });
            checker.errors += 1;
            break;
        }
    }
}
