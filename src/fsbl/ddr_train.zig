//! FSBL runtime DDR training engine.
//!
//! Some Harbor DDR builds do the JEDEC init in hardware but leave the PHY delay
//! knobs open for the CPU to centre at boot. genip builds those with
//! `train=runtime`. It maps the controller wb2 port as a knob register window and
//! it describes the window with a `training` node in the device tree.
//!
//! This module reads that node at comptime (the same way soc.zig reads the SoC
//! addresses) and it drives the knobs at boot with one generic sweep engine. The
//! engine does the same steps for every knob: it sweeps the tap range, it checks
//! a known pattern through the main DRAM path, and it parks the tap at the centre
//! of the widest passing window.
//!
//! The register window is bus-width-agnostic. The `training` node carries the base
//! address, the register stride, the geometry, and the ordered knob table. Each
//! register is the low 32 bits of the bus word at its stride-sized offset:
//!   0x00 WLEVEL   per-lane write-leveling  (feedback = map)
//!   0x08 ODELAY   per-lane write tap 0..31 (feedback = pattern)
//!   0x10 IDELAY   per-lane read tap 0..31  (feedback = pattern)
//!   0x18 BITSLIP  per-lane bitslip 0..7    (feedback = pattern, a 1-bit level)
//!   0x20 CTL  (wo) bit0 SET, bit1 LOAD/APPLY, bits[11:8] lane selector
//!   0x28 STATUS (ro) bit0 BUSY
//!   0x30 CAP  (ro) bit0 active, bits[7:4] lanes, bits[15:8] tapMax, bits[19:16] slipMax
//!
//! The knob protocol is uniform. Write the tap value to the knob register, put the
//! lane in CTL[11:8], pulse CTL SET, pulse CTL LOAD/APPLY, then poll STATUS.BUSY
//! until it clears. BITSLIP is a 1-bit level in the RTL, so the engine reaches a
//! count of N with N repeated APPLY pulses.

const std = @import("std");
const uart = @import("uart");
const conduit = @import("conduit");
const fsbl_options = @import("fsbl_options");

/// The largest knob table the parser stores. The current controller exposes 4.
const MAX_KNOBS: usize = 8;

/// The largest name the parser keeps for a knob. Long names truncate.
const NAME_CAP: usize = 24;

/// Register byte offsets inside the window, in stride units (index * stride). The
/// `training` node gives each knob its own offset. The control block is fixed by
/// the contract at index 4..6.
const CTL_INDEX: u32 = 4;
const STATUS_INDEX: u32 = 5;
const CAP_INDEX: u32 = 6;

/// CTL bit fields.
const CTL_SET: u32 = 0x1;
const CTL_APPLY: u32 = 0x2;
const CTL_LANE_SHIFT: u5 = 8;

/// STATUS bit fields.
const STATUS_BUSY: u32 = 0x1;

/// A bounded poll count so a stuck controller can never hang the boot.
const POLL_LIMIT: usize = 1_000_000;

/// Where the pattern check writes and reads its scratch words. It sits 1 MiB above
/// the DRAM base, clear of the FSBL stack and of the main image copy that runs
/// after training.
const SCRATCH_OFFSET: usize = 0x0010_0000;

/// The width of one pattern check burst, in 32-bit words. More words exercise more
/// data transitions per tap.
const PATTERN_WORDS: usize = 8;

/// How a knob spreads over the data bus. The device tree gives the scope per knob.
pub const KnobScope = enum {
    global,
    per_lane,
    per_bit,
};

/// How the engine judges a tap. `pattern` writes and reads DRAM. `map` reads a
/// controller result register.
pub const KnobFeedback = enum {
    pattern,
    map,
};

/// One tunable PHY delay, taken from a `knob@N` node in the device tree.
pub const Knob = struct {
    name_buf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    name_len: usize = 0,
    /// Register byte offset inside the window.
    reg: u32 = 0,
    scope: KnobScope = .per_lane,
    feedback: KnobFeedback = .pattern,
    min: u32 = 0,
    max: u32 = 0,
    /// True when the RTL applies this knob as a 1-bit level, so a count of N needs
    /// N repeated APPLY pulses. BITSLIP is the only such knob today.
    advance_only: bool = false,

    pub fn name(self: *const Knob) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The whole `training` node, resolved to values. The struct holds fixed arrays so
/// the parser can run at comptime and the result can be a plain const.
pub const TrainDesc = struct {
    train_base: u64 = 0,
    stride: u32 = 8,
    lanes: u32 = 0,
    knobs: [MAX_KNOBS]Knob = undefined,
    knob_count: usize = 0,
    rows: u32 = 0,
    cols: u32 = 0,
    banks: u32 = 0,
    ranks: u32 = 0,
};

/// The training description baked from the embedded device tree, or null when the
/// build has no DTB or the DTB has no `training` node. The FSBL takes the runtime
/// path only when this is non-null.
pub const desc: ?TrainDesc = if (fsbl_options.has_dtb)
    parseTrainingNode(@embedFile("soc_dtb"))
else
    null;

/// Read a big-endian u32 cell from a device-tree property value. Return `dflt`
/// when the value is too short, so a malformed node cannot fault the parser.
fn cellU32(value: []const u8, dflt: u32) u32 {
    if (value.len < 4) return dflt;
    return std.mem.readInt(u32, value[0..4], .big);
}

/// Copy a device-tree string value into a knob name buffer. The value keeps the
/// trailing NUL, so drop it and truncate at the buffer size.
fn copyName(dst: *Knob, value: []const u8) void {
    var len = value.len;
    if (len > 0 and value[len - 1] == 0) len -= 1;
    if (len > NAME_CAP) len = NAME_CAP;
    var i: usize = 0;
    while (i < len) : (i += 1) dst.name_buf[i] = value[i];
    dst.name_len = len;
}

/// Match a scope string. Default to per-lane, the widest safe assumption for an
/// unknown scope.
fn parseScope(value: []const u8) KnobScope {
    const s = std.mem.sliceTo(value, 0);
    if (std.mem.eql(u8, s, "global")) return .global;
    if (std.mem.eql(u8, s, "per-bit")) return .per_bit;
    return .per_lane;
}

/// Match a feedback string. Default to pattern, which needs no controller result
/// signal.
fn parseFeedback(value: []const u8) KnobFeedback {
    const s = std.mem.sliceTo(value, 0);
    if (std.mem.eql(u8, s, "map")) return .map;
    return .pattern;
}

/// Walk the embedded device tree and build the training description for the first
/// sdram-controller node that has a `training` child. Return null when no such
/// node exists. This runs at comptime for the embedded DTB and at runtime for the
/// unit-test fixture, so it uses no allocator and no I/O.
pub fn parseTrainingNode(dtb: []const u8) ?TrainDesc {
    @setEvalBranchQuota(4_000_000);
    const reader = conduit.dtree.Reader.initBuffer(dtb) catch return null;
    var it = reader.nodeIterator();

    var out: TrainDesc = .{};
    var in_ctrl = false;
    var ctrl_depth: usize = 0;
    var in_training = false;
    var training_depth: usize = 0;
    var in_knob = false;
    var knob_depth: usize = 0;
    var have_training = false;
    var cur: Knob = .{};

    while (it.next() catch return null) |node| switch (node) {
        .begin => |b| {
            if (!in_ctrl and std.mem.startsWith(u8, b.name, "sdram-controller")) {
                in_ctrl = true;
                ctrl_depth = b.depth;
                out = .{};
                have_training = false;
            } else if (in_ctrl and !in_training and b.depth == ctrl_depth + 1 and
                std.mem.eql(u8, b.name, "training"))
            {
                in_training = true;
                training_depth = b.depth;
            } else if (in_training and !in_knob and b.depth == training_depth + 1 and
                std.mem.startsWith(u8, b.name, "knob"))
            {
                in_knob = true;
                knob_depth = b.depth;
                cur = .{};
            }
        },
        .prop => |p| {
            if (in_knob) {
                if (std.mem.eql(u8, p.name, "harbor,knob")) {
                    copyName(&cur, p.value);
                    // BITSLIP is a 1-bit level in the RTL. Mark it so the engine
                    // reaches a count with repeated APPLY pulses.
                    if (std.mem.eql(u8, cur.name(), "bitslip")) cur.advance_only = true;
                } else if (std.mem.eql(u8, p.name, "harbor,reg")) {
                    cur.reg = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,scope")) {
                    cur.scope = parseScope(p.value);
                } else if (std.mem.eql(u8, p.name, "harbor,feedback")) {
                    cur.feedback = parseFeedback(p.value);
                } else if (std.mem.eql(u8, p.name, "harbor,min")) {
                    cur.min = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,max")) {
                    cur.max = cellU32(p.value, 0);
                }
            } else if (in_training) {
                if (std.mem.eql(u8, p.name, "harbor,train-reg")) {
                    // The value is <base size>. Take the base cell. Support a
                    // 64-bit base when the cell is 8 bytes wide.
                    if (p.value.len >= 16) {
                        out.train_base = std.mem.readInt(u64, p.value[0..8], .big);
                    } else {
                        out.train_base = cellU32(p.value, 0);
                    }
                } else if (std.mem.eql(u8, p.name, "harbor,train-stride")) {
                    out.stride = cellU32(p.value, 8);
                }
            } else if (in_ctrl) {
                if (std.mem.eql(u8, p.name, "harbor,ddr-lanes")) {
                    out.lanes = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,ddr-rows")) {
                    out.rows = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,ddr-cols")) {
                    out.cols = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,ddr-banks")) {
                    out.banks = cellU32(p.value, 0);
                } else if (std.mem.eql(u8, p.name, "harbor,ddr-ranks")) {
                    out.ranks = cellU32(p.value, 0);
                }
            }
        },
        .end => |e| {
            if (in_knob and e.depth == knob_depth) {
                if (out.knob_count < MAX_KNOBS) {
                    out.knobs[out.knob_count] = cur;
                    out.knob_count += 1;
                }
                in_knob = false;
            } else if (in_training and e.depth == training_depth) {
                in_training = false;
                have_training = true;
            } else if (in_ctrl and e.depth == ctrl_depth) {
                if (have_training) return out;
                // This controller has no training child. Look for the next one.
                in_ctrl = false;
            }
        },
    };
    return null;
}

// === Register access ===================================================

fn r32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
fn w32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

/// The MMIO address of a control-block register at the given index.
fn ctlAddr(d: *const TrainDesc, index: u32) usize {
    return @intCast(d.train_base + @as(u64, index) * d.stride);
}

/// Wait for the controller to finish the last apply. Return true when BUSY clears
/// inside the poll budget. A timeout is a runtime fault, not a programmer error,
/// so the caller decides what to do.
fn waitNotBusy(d: *const TrainDesc) bool {
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (r32(ctlAddr(d, STATUS_INDEX)) & STATUS_BUSY == 0) return true;
    }
    return false;
}

/// Run the knob protocol once. Write the value, select the lane, pulse SET, pulse
/// APPLY, then wait for BUSY to clear.
fn applyKnob(d: *const TrainDesc, knob: *const Knob, lane: u32, value: u32) void {
    const lane_sel = (lane & 0xF) << CTL_LANE_SHIFT;
    w32(@intCast(d.train_base + knob.reg), value);
    w32(ctlAddr(d, CTL_INDEX), CTL_SET | lane_sel);
    w32(ctlAddr(d, CTL_INDEX), CTL_APPLY | lane_sel);
    _ = waitNotBusy(d);
}

// === Pattern feedback ==================================================

/// Build a 32-bit compare mask that keeps only the bytes a slice owns. Lane L owns
/// the bytes whose index modulo the lane count equals L, which matches the byte
/// interleave the read-capture path already uses.
fn sliceMask(d: *const TrainDesc, knob: *const Knob, slice: u32) u32 {
    switch (knob.scope) {
        .global => return 0xFFFF_FFFF,
        .per_lane => {
            const lane = slice;
            return laneByteMask(d.lanes, lane);
        },
        .per_bit => {
            const lane = slice / 8;
            const bit: u5 = @intCast(slice % 8);
            const one_bit: u32 = @as(u32, 0x0101_0101) << bit;
            return laneByteMask(d.lanes, lane) & one_bit;
        },
    }
}

fn laneByteMask(lanes: u32, lane: u32) u32 {
    if (lanes == 0) return 0xFFFF_FFFF;
    var mask: u32 = 0;
    var b: u32 = 0;
    while (b < 4) : (b += 1) {
        if (b % lanes == lane) mask |= @as(u32, 0xFF) << @intCast(b * 8);
    }
    return mask;
}

/// Write a known pattern to the DRAM scratch words, read it back, and return true
/// when every masked word matches. The mask narrows the check to the bytes the
/// slice under test owns.
fn patternPasses(dram_base: usize, mask: u32) bool {
    const scratch = dram_base + SCRATCH_OFFSET;
    // A 0xC0DE tag plus a rolling low half exercises the data lines. The 0x5555
    // and 0xAAAA words drive every bit in both directions.
    const pats = [PATTERN_WORDS]u32{
        0xC0DE_0000, 0xC0DE_FFFF, 0xC0DE_5555, 0xC0DE_AAAA,
        0xC0DE_1234, 0xC0DE_8001, 0xC0DE_0F0F, 0xC0DE_F0F0,
    };
    var i: usize = 0;
    while (i < PATTERN_WORDS) : (i += 1) w32(scratch + i * 4, pats[i]);
    // A warm-up read absorbs the write-to-read turnaround so the first compared
    // word is not the turnaround bubble.
    _ = r32(scratch);
    i = 0;
    while (i < PATTERN_WORDS) : (i += 1) {
        if ((r32(scratch + i * 4) & mask) != (pats[i] & mask)) return false;
    }
    return true;
}

// === Sweep and centre ==================================================

/// The result of sweeping one slice of one knob.
const SweepResult = struct {
    found: bool,
    center: u32,
};

/// Find the centre of the widest run of set bits in `pass[min..=max]`.
fn widestCenter(pass: []const bool, min: u32, max: u32) SweepResult {
    var best_start: u32 = 0;
    var best_len: u32 = 0;
    var run_start: u32 = min;
    var run_len: u32 = 0;
    var t: u32 = min;
    while (t <= max) : (t += 1) {
        if (pass[t]) {
            if (run_len == 0) run_start = t;
            run_len += 1;
            if (run_len > best_len) {
                best_len = run_len;
                best_start = run_start;
            }
        } else {
            run_len = 0;
        }
        if (t == max) break; // guard the u32 wrap when max is the type maximum
    }
    if (best_len == 0) return .{ .found = false, .center = min };
    return .{ .found = true, .center = best_start + best_len / 2 };
}

/// Sweep one slice of an absolute-value knob. Each tap writes an absolute value,
/// so the engine can set any tap directly. Return the centre of the widest passing
/// window.
fn sweepAbsolute(
    con: *uart.Ns16550a,
    d: *const TrainDesc,
    knob: *const Knob,
    lane: u32,
    slice: u32,
    dram_base: usize,
) SweepResult {
    var pass = [_]bool{false} ** 33; // taps 0..31 plus a guard slot
    const mask = sliceMask(d, knob, slice);
    var tap = knob.min;
    var pass_count: u32 = 0;
    while (tap <= knob.max) : (tap += 1) {
        applyKnob(d, knob, lane, tap);
        const ok = patternPasses(dram_base, mask);
        if (tap < pass.len) pass[tap] = ok;
        if (ok) pass_count += 1;
        if (tap == knob.max) break;
    }
    logSlice(con, knob, slice, pass_count);
    const res = widestCenter(pass[0..], knob.min, @min(knob.max, @as(u32, pass.len - 1)));
    if (res.found) applyKnob(d, knob, lane, res.center);
    return res;
}

/// Advance a 1-bit-level knob by one count. The value written does not carry the
/// count. Each APPLY pulse steps the level by one.
fn advanceOne(d: *const TrainDesc, knob: *const Knob, lane: u32) void {
    applyKnob(d, knob, lane, 1);
}

/// Sweep one slice of a 1-bit-level knob (BITSLIP). The level cannot be set to an
/// absolute count, so the engine steps it forward and checks each count. The count
/// range wraps at max+1. The sweep assumes the level starts at 0.
fn sweepAdvance(
    con: *uart.Ns16550a,
    d: *const TrainDesc,
    knob: *const Knob,
    lane: u32,
    slice: u32,
    dram_base: usize,
) SweepResult {
    var pass = [_]bool{false} ** 9; // counts 0..7 plus a guard slot
    const mask = sliceMask(d, knob, slice);
    const span = knob.max + 1; // the wrap period, e.g. 8 for a 3-bit slip
    var pass_count: u32 = 0;
    var count: u32 = 0;
    while (count <= knob.max) : (count += 1) {
        const ok = patternPasses(dram_base, mask);
        if (count < pass.len) pass[count] = ok;
        if (ok) pass_count += 1;
        advanceOne(d, knob, lane); // step to the next count
        if (count == knob.max) break;
    }
    // The sweep issued max+1 pulses, so the level wrapped back to 0.
    logSlice(con, knob, slice, pass_count);
    const res = widestCenter(pass[0..], knob.min, @min(knob.max, @as(u32, pass.len - 1)));
    if (res.found) {
        // Step from 0 to the chosen centre.
        var i: u32 = 0;
        while (i < res.center % span) : (i += 1) advanceOne(d, knob, lane);
    }
    return res;
}

// === Logging ===========================================================

fn hexNibble(con: *uart.Ns16550a, n: u8) void {
    const digits = "0123456789ABCDEF";
    con.putc(digits[n & 0xF]);
}

fn hex32(con: *uart.Ns16550a, v: u32) void {
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        hexNibble(con, @intCast((v >> @intCast(i * 4)) & 0xF));
    }
}

fn logSlice(con: *uart.Ns16550a, knob: *const Knob, slice: u32, pass_count: u32) void {
    con.writeStr("[fsbl] train: knob=");
    con.writeStr(knob.name());
    con.writeStr(" slice=");
    hexNibble(con, @intCast(slice & 0xF));
    con.writeStr(" passes=0x");
    hex32(con, pass_count);
    con.putc('\n');
}

/// How many slices a knob covers, given its scope and the lane count.
fn sliceCount(d: *const TrainDesc, knob: *const Knob) u32 {
    return switch (knob.scope) {
        .global => 1,
        .per_lane => d.lanes,
        .per_bit => d.lanes * 8,
    };
}

/// The lane a slice belongs to, for the CTL lane selector.
fn sliceLane(knob: *const Knob, slice: u32) u32 {
    return switch (knob.scope) {
        .global => 0,
        .per_lane => slice,
        .per_bit => slice / 8,
    };
}

/// Drive one controller through the whole knob table. For each knob, in the device
/// tree order (which is the apply order), sweep every slice and park the tap at the
/// widest passing window. Finish with the shared memtest. Return true when every
/// knob centres and the memtest passes.
pub fn trainController(
    con: *uart.Ns16550a,
    d: *const TrainDesc,
    dram_base: usize,
    memtest: *const fn (*uart.Ns16550a) bool,
) bool {
    const cap = r32(ctlAddr(d, CAP_INDEX));
    con.writeStr("[fsbl] train: window base=0x");
    hex32(con, @intCast(d.train_base & 0xFFFF_FFFF));
    con.writeStr(" lanes=");
    hexNibble(con, @intCast(d.lanes & 0xF));
    con.writeStr(" knobs=");
    hexNibble(con, @intCast(d.knob_count & 0xF));
    con.writeStr(" cap=0x");
    hex32(con, cap);
    con.putc('\n');

    var ki: usize = 0;
    while (ki < d.knob_count) : (ki += 1) {
        const knob = &d.knobs[ki];
        if (knob.feedback == .map) {
            // The controller has no clean write-leveling result signal yet, so the
            // STATUS map is a placeholder. Skip the map read for this first cut and
            // leave write-leveling at its hardware default.
            con.writeStr("[fsbl] train: knob=");
            con.writeStr(knob.name());
            con.writeStr(" feedback=map placeholder, skipped\n");
            continue;
        }
        const slices = sliceCount(d, knob);
        var s: u32 = 0;
        while (s < slices) : (s += 1) {
            const lane = sliceLane(knob, s);
            const res = if (knob.advance_only)
                sweepAdvance(con, d, knob, lane, s, dram_base)
            else
                sweepAbsolute(con, d, knob, lane, s, dram_base);
            if (!res.found) {
                con.writeStr("[fsbl] train: knob=");
                con.writeStr(knob.name());
                con.writeStr(" slice=");
                hexNibble(con, @intCast(s & 0xF));
                con.writeStr(" NO PASSING TAP\n");
                return false;
            }
            con.writeStr("[fsbl] train: knob=");
            con.writeStr(knob.name());
            con.writeStr(" slice=");
            hexNibble(con, @intCast(s & 0xF));
            con.writeStr(" centred tap=0x");
            hex32(con, res.center);
            con.putc('\n');
        }
    }

    con.writeStr("[fsbl] train: knobs centred, running memtest\n");
    return memtest(con);
}

// === Tests =============================================================

test "parseTrainingNode reads the creek runtime training node" {
    if (!@hasDecl(fsbl_options, "has_test_dtb") or !fsbl_options.has_test_dtb) {
        return error.SkipZigTest;
    }
    const dtb = @embedFile("train_test_dtb");
    const d = parseTrainingNode(dtb) orelse return error.NoTrainingNode;

    try std.testing.expectEqual(@as(u64, 0x8ffff000), d.train_base);
    try std.testing.expectEqual(@as(u32, 8), d.stride);
    try std.testing.expectEqual(@as(u32, 2), d.lanes);
    try std.testing.expectEqual(@as(usize, 4), d.knob_count);

    // The knobs must land in device-tree order, which is the apply order.
    try std.testing.expectEqualStrings("write-level", d.knobs[0].name());
    try std.testing.expectEqual(@as(u32, 0x0), d.knobs[0].reg);
    try std.testing.expectEqual(KnobFeedback.map, d.knobs[0].feedback);
    try std.testing.expectEqual(KnobScope.per_lane, d.knobs[0].scope);

    try std.testing.expectEqualStrings("write-odelay", d.knobs[1].name());
    try std.testing.expectEqual(@as(u32, 0x8), d.knobs[1].reg);
    try std.testing.expectEqual(KnobFeedback.pattern, d.knobs[1].feedback);
    try std.testing.expectEqual(@as(u32, 0x0), d.knobs[1].min);
    try std.testing.expectEqual(@as(u32, 0x1f), d.knobs[1].max);

    try std.testing.expectEqualStrings("read-idelay", d.knobs[2].name());
    try std.testing.expectEqual(@as(u32, 0x10), d.knobs[2].reg);
    try std.testing.expectEqual(@as(u32, 0x1f), d.knobs[2].max);

    try std.testing.expectEqualStrings("bitslip", d.knobs[3].name());
    try std.testing.expectEqual(@as(u32, 0x18), d.knobs[3].reg);
    try std.testing.expectEqual(@as(u32, 0x7), d.knobs[3].max);
    try std.testing.expect(d.knobs[3].advance_only);
}

test "widestCenter picks the centre of the widest run" {
    // Two runs: 1..2 (width 2) and 5..8 (width 4). The wider run wins.
    var pass = [_]bool{false} ** 33;
    pass[1] = true;
    pass[2] = true;
    pass[5] = true;
    pass[6] = true;
    pass[7] = true;
    pass[8] = true;
    const res = widestCenter(pass[0..], 0, 31);
    try std.testing.expect(res.found);
    try std.testing.expectEqual(@as(u32, 7), res.center); // 5 + 4/2
}

test "widestCenter reports no window when nothing passes" {
    const pass = [_]bool{false} ** 33;
    const res = widestCenter(pass[0..], 0, 31);
    try std.testing.expect(!res.found);
}

test "laneByteMask splits a 16-bit bus into two lanes" {
    // Two lanes over a 4-byte word: lane 0 owns bytes 0 and 2, lane 1 owns 1 and 3.
    try std.testing.expectEqual(@as(u32, 0x00FF_00FF), laneByteMask(2, 0));
    try std.testing.expectEqual(@as(u32, 0xFF00_FF00), laneByteMask(2, 1));
}
