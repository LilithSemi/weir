//! DDR controller bring-up + read-eye training.
//!
//! Harbor's controller does JEDEC init in hardware. On an ECP5 DLL-ON trainable
//! build (DDR clock PLL'd above the osc, so the PHY is DELAYF + IDDRX2DQA +
//! DQSBUFM-strobed with a runtime read-DLL), the read eye is NOT fixed by the
//! bitstream: the FSBL must find and centre it at boot by a write+readback sweep
//! of a known pattern, exactly like the standalone RiverDdrLevel maskrom sweep.
//! Once centred the eye self-centres per-part/temperature, so a fresh placement
//! or a thermal drift no longer moves it out from under the read (the whole point
//! of the trained path vs the placement-lottery static DELAYG tap).
//!
//! MMIO train-control window (8-byte-strided 32-bit regs, above the DRAM array at
//! `ddr_train_base` = dram_base + dram_size - 0x1000):
//!   reg0 +0x00 RDTAP_TARGET  7-bit DELAYF read tap target (0..127)
//!   reg1 +0x08 CTL           bit0 SET (load RDTAP target into the DELAYF walk)
//!   reg2 +0x10 RDSLACK       read-window slack (also moves the fabric capture cyc)
//!   reg3 +0x18 STATUS (RO)   busy[0], curTap[7:1], DATAVALID[8], BURSTDET[9],
//!                            DLL_LOCK[10], BDET_SEEN[11], DVALID_SEEN[12]
//!   reg4 +0x20 READCLKSEL    3-bit DQSBUFM read-gate select (0..7); low 2 bits
//!                            also select the per-DQ read-beat bitslip
//!   reg6 +0x30 WLRES (RO)    write-leveling result: lane0[3:0], lane1[7:4],
//!                            wlDone[8]
//!
//! The sweep writes a 4-word C0DE pattern to dram_base, warm-up reads (absorbs the
//! write->read turnaround), reads back, and judges a combo PASSING iff all 4 words
//! match. The eye = the widest contiguous run of passing RDTAP taps at the best
//! (READCLKSEL, RDSLACK); the tap is parked at that run's centre. On no-eye the
//! FSBL halts (the caller must not run from unvalidated DRAM).

const uart = @import("uart");
const cfg = @import("config.zig");
const ddr_train = @import("ddr_train.zig");

const RDTAP_TARGET = 0x00;
const CTL = 0x08;
const RDSLACK = 0x10;
const STATUS = 0x18;
const READCLKSEL = 0x20;
const RDPCTL = 0x28; // reg5: DQSBUFM read-POINTER control (RDLOADN/RDDIR/RDMOVE)
const WLRES = 0x30; // reg6 (RO): write-leveling result, bit8 = wlDone
const WRDLY = 0x38; // reg7: per-lane write-DQS-delay tap (additive) + dir/apply
// reg6 (@ +0x30): on a dqsGatedRead build this reads back the raw DQS capture
// (dbg_beats). reg7 there is WRDLY, so the base-path chBeats readout is not
// reachable; the controller routes dbg_beats to reg6 instead.
const DQS_DBG = 0x30;
const WTRIM = 0x40; // reg8: PER-LANE DQSBUFM DYNDELAY (lane0[7:0], lane1[15:8])
// reg14 (Xilinx runtime write-DQS re-center): [3:0] lane0 write-beat, [7:4] lane1
// write-beat, [8] enable. Sweeping this walks the write-DQS launch across the CK.
const WRBEAT = 0x70;
const WRBEAT_EN: u32 = 0x100;
const DQSEL = 0x50; // reg10: PER-BIT DQ DESKEW select {broadcastBit(MSB), dqIndex}
const RDPULSE = 0x58; // reg11: INDEPENDENT READ0/READ1 read-pulse position (0..14;
// 15 = "use legacy gate"). Shifts ONLY the DQSBUFM read-gate open tap relative to
// the read command, DECOUPLED from the RDSLACK capture anchor, so the FSBL can walk
// the read pulse onto the DATA BURST (framed by BURSTDET) instead of the preamble.
// This is the burst-framing lever: the DLL-on read was data-INVARIANT (0x5A / 0xC0DE
// read the same preamble/idle constant) because the read window framed the preamble;
// sweeping this until BURSTDET asserts AND the pattern reads back moves the window
// onto the burst so the readback finally TRACKS the written data.

// reg10 layout for a 16-bit DQ bus: dqIndex is bits[4:0] (0..15), broadcast bit
// is bit5. Broadcast (0x20) = the shared group walk (reset default); a plain
// index (0..15) gates the DELAYF MOVE/LOADN to that one DQ bit so it deskews
// independently. DQ_BITS = the data-bus width.
const DQ_BITS: u32 = 8;
// DQS-eye sweep sentinel: a per-bit IDELAY lane index the DQ bits (0..DQ_BITS-1)
// do NOT use, so centring the DQS strobe's own IDELAY does not disturb the DQ
// lanes and the DQ centring loop does not disturb the DQS. Matches the PHY's
// dqsGatedRead sentinel (= dataBits).
const DQS_LANE: u32 = DQ_BITS;
const DQSEL_BCAST: u32 = 0x20; // 1 << 5 (broadcast bit set)

const CTL_SET: u32 = 0x1;
const CTL_LOAD: u32 = 0x2;
// reg1 CTL bit2: CLEAR the sticky BURSTDET/DATAVALID-seen latches (one pulse per
// write edge). Lets the FSBL use BURSTDET as a per-STEP read-level oracle: clear,
// step the read pointer / read-pulse, issue a read, then check if BURSTDET latched
// again = the read window saw a valid burst at this step. This is the knob that
// PINS the DQSBUFM read-FIFO pointer to a deterministic phase each boot (the read
// pointer otherwise powers up on an arbitrary DQS-vs-sclk phase = the boot-to-boot
// frame wander). Requires the reg1-bit2 BDET-clear RTL (harbor ddr/ddr_phy_ecp5).
const CTL_BDET_CLEAR: u32 = 0x4;

// reg5 RDPCTL bit layout (matches HarborDdrController):
//   bit0 RDLOADN   active-low: 0 loads the DDRDEL 90-deg code (init default)
//   bit1 RDDIRECTION  1 = increment the read-FIFO pointer
//   bit2 RDMOVE    write with this set = one DQSBUFM read-pointer STEP pulse
// RDMOVE is the newly-wired coarse read-pointer centering knob: each write with
// bit2 set advances (or retards, per RDDIRECTION) the read pointer one step,
// shifting which captured sub-beat the read framing lands on.
const RDP_LOADN_LOW: u32 = 0x0; // RDLOADN=0 (assert), RDDIR/RDMOVE=0
const RDP_DIR_INC: u32 = 0x2; // RDDIRECTION=1
const RDP_MOVE: u32 = 0x4; // RDMOVE pulse bit

const STATUS_BUSY: u32 = 0x1;
const STATUS_DATAVALID: u32 = 1 << 8;
const STATUS_BURSTDET: u32 = 1 << 9; // live lane-0 DQSBUFM BURSTDET
const STATUS_DLL_LOCK: u32 = 1 << 10;
const STATUS_BDET_SEEN: u32 = 1 << 11; // sticky "BURSTDET ever asserted"
const STATUS_DVALID_SEEN: u32 = 1 << 12; // sticky "DATAVALID ever asserted"

// reg11 RDPULSE: read-pulse position sweep extent. The PHY field is 5 bits
// (pulseW = (maxRdPulse+1).bitLength = 5 for maxRdPulse=15); positions 0..15 are
// real taps and the ALL-ONES value (31 = 0x1F) is the "legacy gate" sentinel /
// reset default. The burst arrives up to ~15 sclk cycles after the read command
// on the board round-trip, so the whole 0..15 range is swept.
const RDPULSE_TOP: u32 = 16; // sweep positions 0..15 (all real taps)
const RDPULSE_LEGACY: u32 = 0x1F; // sentinel = legacy gate (5-bit all-ones)
const WLRES_DONE: u32 = 1 << 8;
// reg6 WITNESS bitmap (bits [23:16]): per-tap voted WL DQ feedback for the last
// lane the WL FSM scanned. bit t = feedback high at write-DQS tap t. The FSM
// stops the sweep at the 0->1 edge, so a real training result is a NON-ZERO map
// whose highest set bit is the trained tap; an ALL-ZERO map means the feedback
// never flipped as the write-DQS delay swept = an RTL feedback-path fault (the
// DRAM's WL-mode DQ is not reaching the FSM), NOT a firmware sweep problem.
const WLRES_FBMAP_SHIFT: u5 = 16;
const WLRES_FBMAP_MASK: u32 = 0xFF;

// Known pattern written+checked at dram_base each combo.
const PAT0: u32 = 0xC0DE0000;
const PAT1: u32 = 0xC0DE1111;
const PAT2: u32 = 0xC0DE2222;
const PAT3: u32 = 0xC0DE3333;

// Sweep extents (see RiverDdrLevel: the real eye is not a multiple of 16, so step
// RDTAP by 8; READCLKSEL and RDSLACK both move the read window).
const TAP_STEP: u7 = 8;
const TAP_TOP: u9 = 128; // taps 0,8,..,120
const RCS_TOP: u32 = 8; // READCLKSEL 0..7
const SLK_TOP: u32 = 8; // RDSLACK 0..7

const POLL_LIMIT = 1_000_000;

// HW bring-up probe: emit RDMOVE/DYNDELAY movement diagnostics then halt (fast),
// instead of running the full centering sweep. Set false for the real training.
const PROBE = false;

// STEP-1 LANE0 CLASSIFICATION PROBE (2026-07-11): the OTHER byte lane (bytes 0,2
// = lane0 = DQ[7:0]) reads CONSTANT 0xFF while the captured lane (bytes 1,3) frames.
// Constant-FF (not varying) => lane0 DQ is NOT being captured => a WRITE-side or a
// per-lane READ-GATE fault, NOT read-strobe centering (DYNDELAY cannot move a
// constant). This probe writes a KNOWN non-FF pattern, sweeps lane0's DYNDELAY (reg8
// d0 field) + the read framing (rdpulse/rcs/slk), and prints lane0's bytes (0,2) at
// each. THE QUESTION: does byte0/2 EVER read non-FF? NEVER => write-path / read-gate
// (RTL). SOMETIMES => read-training (widen the land sweep, firmware). Also runs a
// 5A-vs-A5 DATA-TRACKING discriminator on lane0 (does it TRACK the written data or
// stay a constant). Set true to run this instead of the training; halts after.
const PROBE_LANE0 = false;

// Post-eye VERIFY + sustained-read STRESS gate. When true, after a centred eye is
// found ddr.init runs stressVerify() (5A/C0DE per-bit-error map on all 16 lanes +
// a seq/random sustained-read memtest) and reports the numbers over UART BEFORE
// returning true. Off for the fast production boot; on for the de-risk verdict.
const DDR_STRESS = @import("fsbl_options").ddr_stress;

fn r32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}
fn w32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

// === Read-pipe WINDOW + per-lane read-tap setup (vendorless train-control MMIO).
// The Harbor DDR train-control window decodes these regs the same way regardless
// of FPGA vendor (the PHY maps them onto its own primitive - IDELAYE2 on Xilinx,
// DELAYF on ECP5). reg[10] loads a per-lane read delay tap (VAR_LOAD); reg[12]
// selects the ctrl-domain read-pipe WINDOW (which controller cycle the read BL8
// line is latched relative to the read command - the read analog of write-launch);
// reg[11] pulses per-lane bitslip. The DEFAULT-FIRST path below never writes the
// WINDOW, so the boot read runs at the PHY power-up cycle - fine for paced access
// but MARGINAL for main's streaming fetches. rdReadSetup() pins the window +
// centres the taps so both the FSBL copy and main Weir read a framed eye.
const RD_IDELAY = 0x50; // reg10: [4:0]tap [5]LD [9:6]lane
const RD_BITSLIP = 0x58; // reg11: [3:0]lane [4]slip
const RD_WINDOW = 0x60; // reg12: [3:0] ctrl read-pipe cycle
const RD_REFRESH = 0x68; // reg13: [1:0] refresh level (0=1x 1=2x 2=4x tREFI)
const RD_IDELAY_LD: u32 = 0x20; // reg10 bit5 = VAR_LOAD
const RD_TAP_TOP: u32 = 32; // 5-bit tap counter (taps 0..31)
const RD_WINDOW_VAL: u32 = 5; // the live burst-landing read-pipe cycle
const RD_CENTER_TAP: u32 = 17; // per-lane read-eye centre

fn rdSetLaneTap(lane: u32, tap: u32) void {
    w32(cfg.ddr_train_base + RD_IDELAY, (lane << 6) | RD_IDELAY_LD | (tap & 0x1f));
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = r32(cfg.ddr_train_base + STATUS);
}
fn rdSetAllTaps(tap: u32) void {
    var l: u32 = 0;
    while (l < DQ_BITS) : (l += 1) rdSetLaneTap(l, tap);
}
fn rdSetWindow(win: u32) void {
    w32(cfg.ddr_train_base + RD_WINDOW, win);
    var i: usize = 0;
    while (i < 16) : (i += 1) _ = r32(cfg.ddr_train_base + STATUS);
}

fn hexNibble(con: *uart.Ns16550a, n: u8) void {
    const c: u8 = if (n < 10) '0' + n else 'A' + (n - 10);
    con.putc(c);
}
fn hex8(con: *uart.Ns16550a, v: u32) void {
    var i: i32 = 28;
    while (i >= 0) : (i -= 4) {
        hexNibble(con, @intCast((v >> @intCast(i)) & 0xF));
    }
}

/// Print the popcount (one hex nibble each) of a word's two bytes on ONE lane, in
/// BEAT order (even beat first = the high 16-bit half's byte, then odd beat = the
/// low half's byte). cap=true -> the captured DQS lane bytes (byte3, byte1);
/// cap=false -> the float lane bytes (byte2, byte0). Used by the STEP-A beat->byte
/// popcount map: a word = packWord(evenBeat, oddBeat) = (evenBeat<<16)|oddBeat, so
/// [byte3,byte1] (cap) or [byte2,byte0] (flt) = [evenBeat, oddBeat] popcounts.
fn printBytePops(con: *uart.Ns16550a, w: u32, cap: bool) void {
    const evenByte: u8 = if (cap) @intCast((w >> 24) & 0xFF) else @intCast((w >> 16) & 0xFF);
    const oddByte: u8 = if (cap) @intCast((w >> 8) & 0xFF) else @intCast(w & 0xFF);
    hexNibble(con, popc(evenByte));
    hexNibble(con, popc(oddByte));
}

/// Walk the read tap to `tap` (reg0 target + reg1 SET) and wait until idle.
fn walkTap(tap: u7) void {
    w32(cfg.ddr_train_base + RDTAP_TARGET, tap);
    w32(cfg.ddr_train_base + CTL, CTL_SET);
    var i: usize = 0;
    while (i < POLL_LIMIT) : (i += 1) {
        if (r32(cfg.ddr_train_base + STATUS) & STATUS_BUSY == 0) break;
    }
}

fn setReadClkSel(rcs: u32) void {
    w32(cfg.ddr_train_base + READCLKSEL, rcs);
}
/// Program the INDEPENDENT read-pulse position (reg11 RDPULSE). 0..14 = a real
/// tap that shifts ONLY the DQSBUFM READ0/READ1 gate open point relative to the
/// read command (decoupled from the RDSLACK capture anchor); 15 = legacy gate.
/// Quasi-static: crosses to sclk, so settle a few cycles before relying on it.
fn setRdPulse(pos: u32) void {
    w32(cfg.ddr_train_base + RDPULSE, pos);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = r32(cfg.ddr_train_base + STATUS);
    }
}
/// Do a read burst at dram_base and return the STATUS word sampled right after,
/// so BURSTDET/DATAVALID (which pulse during the read window) can be witnessed.
/// The sticky BDET_SEEN/DVALID_SEEN bits latch a single-cycle pulse the live poll
/// would miss. A read is issued to make the DQSBUFM open its gate this instant.
fn readStatusAfterRead() u32 {
    _ = r32(cfg.dram_base + 0x0);
    return r32(cfg.ddr_train_base + STATUS);
}
fn setRdSlack(slk: u32) void {
    w32(cfg.ddr_train_base + RDSLACK, slk);
}
/// Additive per-lane write-DQS-delay launch tap (reg7). Each write steps the
/// write pointer to WL_base + laneOff; a write EDGE applies it. dir bit8.
fn setWrDly(lane0: u32, lane1: u32) void {
    w32(cfg.ddr_train_base + WRDLY, (lane1 << 4) | lane0);
}
/// PER-LANE DQSBUFM DYNDELAY (reg8), quasi-static. lane0 -> bits[7:0], lane1 ->
/// bits[15:8]. DYNDELAY shifts the WHOLE byte lane's DQS strobe, so it is the
/// FINE per-DQS-group read-strobe centering knob (the DQS_LI static-delay path)
/// as well as the write trim. Wait a few cycles after a change (the DQSBUFM
/// PAUSE-4T settle) before relying on the new strobe delay.
fn setDynDelay(lane0: u8, lane1: u8) void {
    w32(cfg.ddr_train_base + WTRIM, (@as(u32, lane1) << 8) | lane0);
    // Quasi-static settle (PAUSE window + bus->sclk sync).
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        _ = r32(cfg.ddr_train_base + STATUS);
    }
}
/// PER-BIT DQ DESKEW select (reg10). Broadcast = the shared group walk (reset
/// default); a bit index gates the DELAYF MOVE/LOADN to that one DQ bit. The
/// value is quasi-static (crosses to sclk), so settle a few cycles after a write.
fn setDeskewSel(sel: u32) void {
    w32(cfg.ddr_train_base + DQSEL, sel);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = r32(cfg.ddr_train_base + STATUS);
    }
}
fn setDeskewBroadcast() void {
    setDeskewSel(DQSEL_BCAST);
}
/// Walk ONLY DQ bit `dq`'s read-DELAYF to `tap`. Selects the bit (reg10), LOADs
/// (resets ONLY that bit's DELAYF + the walk's tracked tap to 0), then SETs the
/// target. Because LOADN is gated per-bit, other bits keep their trained taps.
fn deskewBit(dq: u32, tap: u7) void {
    setDeskewSel(dq);
    // LOAD (reg1 bit1) resets the selected bit's DELAYF + the tracked tap to 0.
    w32(cfg.ddr_train_base + CTL, 0x2);
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (r32(cfg.ddr_train_base + STATUS) & STATUS_BUSY == 0) break;
    }
    // SET (reg0 target + reg1 SET) walks the selected bit to `tap`.
    walkTap(tap);
}

/// Reset the DQSBUFM read pointer to its loaded reference (RDLOADN asserted).
fn rdpLoad() void {
    w32(cfg.ddr_train_base + RDPCTL, RDP_LOADN_LOW | RDP_DIR_INC);
}
/// Step the DQSBUFM read pointer one position (one RDMOVE pulse) in the
/// increment direction. This is the coarse read-pointer centering knob wired
/// through reg5 RDPCTL. Two separate writes give two clean, separated MOVE
/// edges (the controller edge-detects the RDMOVE toggle).
fn rdpStep() void {
    // First write with RDMOVE=0 (level), then a write with RDMOVE=1 makes the
    // edge the controller turns into one read-pointer MOVE pulse.
    w32(cfg.ddr_train_base + RDPCTL, RDP_DIR_INC);
    w32(cfg.ddr_train_base + RDPCTL, RDP_DIR_INC | RDP_MOVE);
    // Let the MOVE cross to sclk + settle before the next step / read.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        _ = r32(cfg.ddr_train_base + STATUS);
    }
}

/// Clear the sticky BURSTDET/DATAVALID-seen latches (reg1 CTL bit2). Two writes
/// with the bit set give two clean toggle edges; the PHY turns each edge into one
/// sclk clear pulse. Settle a few cycles so the clear crosses to sclk before the
/// next read arms the sticky again.
fn clearBdet() void {
    w32(cfg.ddr_train_base + CTL, CTL_BDET_CLEAR);
    w32(cfg.ddr_train_base + CTL, 0);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = r32(cfg.ddr_train_base + STATUS);
    }
}

/// True iff BURSTDET has been seen (sticky) since the last clearBdet. Issues a
/// read at dram_base so the DQSBUFM opens its gate this instant, then samples the
/// sticky seen bit (which latches a single-cycle BURSTDET pulse the live poll
/// would miss).
fn bdetSeen() bool {
    _ = r32(cfg.dram_base + 0x0);
    return (r32(cfg.ddr_train_base + STATUS) & STATUS_BDET_SEEN) != 0;
}

/// READ-LEVEL the DQSBUFM read-FIFO pointer: step RDMOVE and find the pointer
/// position where BURSTDET asserts STABLY (over a few reads) after a clear. This
/// PINS the read pointer to a known DQS-vs-sclk phase each boot (it otherwise
/// powers up arbitrary = the boot-to-boot frame wander). Walks up to `steps`
/// RDMOVE positions; parks at the FIRST position that shows BURSTDET on all of a
/// few consecutive clear+read trials. Returns the step index parked at, or -1 if
/// none showed a stable BURSTDET (the caller then falls back / halts). Assumes
/// reg11 is at a real (non-legacy) pulse position and the read setting is sane.
fn readLevelPointer(steps: u32) i32 {
    rdpLoad();
    var s: u32 = 0;
    while (s < steps) : (s += 1) {
        // Test stability: 3 clear+read trials must all latch BURSTDET.
        var ok = true;
        var t: u32 = 0;
        while (t < 3) : (t += 1) {
            clearBdet();
            if (!bdetSeen()) {
                ok = false;
                break;
            }
        }
        if (ok) return @intCast(s);
        rdpStep();
    }
    return -1;
}

/// Number of read samples the majority-vote backstop takes per word. A residual
/// marginal read (a lone metastable capture) is outvoted by the stable majority,
/// so a centred-but-not-perfect eye still yields the correct word. Kept small so
/// the boot-time sweep stays fast; the residual glitch rate at a CENTRED eye is
/// low, so 3 samples resolve nearly all of them.
const VOTE_N = 3;

/// Read one word with a small majority vote: sample VOTE_N times and return the
/// value seen by a majority (>= 2 of 3). Falls back to the last sample if no
/// value repeats (a fully-random capture, i.e. the eye is not landed at all -
/// the caller's match check then fails and the sweep moves on). This is the
/// DLL-on read-retry/majority backstop: once the eye is CENTRED, an occasional
/// marginal read self-corrects instead of corrupting a boot.
fn readVoted(addr: usize) u32 {
    const a = r32(addr);
    const b = r32(addr);
    if (a == b) return a;
    const c = r32(addr);
    if (c == a or c == b) return c;
    // No two agree: unresolved. Return the last sample; the match check fails.
    return c;
}

// DDR3 BL8 line stride: 8 beats x 16-bit bus = 16 bytes per line. Each Harbor
// write transaction is a SINGLE-word masked BL8 to one line; beatSel = addr[3:2]
// picks which of the 4 words in the line is unmasked. HW-DECISIVE (2026-07-10,
// bringup-debugger + probe): writing 4 consecutive words to the SAME 16-byte line
// back-to-back COLLIDES in the PHY write-launch pipe / DQS preamble at DLL-on
// 132MHz - the previous transaction's launch is still draining when the next
// wrStart re-latches wrWord, so the array holds a data-INVARIANT preamble constant
// (0x69/0x6B/0xCB family) regardless of what was written. A single isolated write
// to a line reads back its own data CLEAN (probe 1: 5A -> 5AFF5AFF). The FIX for
// the training oracle: write each pattern word to its OWN separate line (stride
// LINE), so every write is a clean isolated beatSel=0 BL8 with no same-line
// collision. This makes the write ground-truth clean so the read sweep can
// actually find the eye. (The real main copy is drained the same way, see below.)
const LINE: usize = 0x20; // >= 16B BL8 line, keeps each test word on its own line

/// Write the 4-word pattern (each to its OWN 16-byte line so no same-line write
/// collision), warm-up read, read back into out[0..4] using the majority-vote
/// read so a marginal capture does not spuriously fail a centred eye (and does
/// not spuriously pass a garbage one - the vote needs agreement).
fn writeReadback(out: *[4]u32) void {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, PAT0);
    w32(b + 1 * LINE, PAT1);
    w32(b + 2 * LINE, PAT2);
    w32(b + 3 * LINE, PAT3);
    _ = r32(b + 0 * LINE); // warm-up: absorb write->read turnaround beat
    out[0] = readVoted(b + 0 * LINE);
    out[1] = readVoted(b + 1 * LINE);
    out[2] = readVoted(b + 2 * LINE);
    out[3] = readVoted(b + 3 * LINE);
}

/// Count how many of the 4 pattern words read back correctly (0..4).
fn matchCount(w: *const [4]u32) u8 {
    var n: u8 = 0;
    if (w[0] == PAT0) n += 1;
    if (w[1] == PAT1) n += 1;
    if (w[2] == PAT2) n += 1;
    if (w[3] == PAT3) n += 1;
    return n;
}

/// Write the 4-word pattern, warm-up read, read back, return true iff all match.
fn tapPasses() bool {
    var w: [4]u32 = undefined;
    writeReadback(&w);
    return matchCount(&w) == 4;
}

/// Run the post-eye VERIFY + sustained-read STRESS pass (task gate). Called only
/// after ddr.init has landed a centred eye, so the numbers characterise the
/// closed eye - not the search. Reports:
///   1. 0x5A5A5A5A + 0xC0DE readback CLEANLINESS with a per-DQ-bit error map (all
///      16 lanes) so a residual scramble is localised bit-by-bit vs the pattern.
///   2. A Linux-grade sustained SEQ + pseudo-random write/read stress over a DRAM
///      window (STRESS_WORDS words), counting mismatches. Zero mismatch = the
///      eye holds under continuous access (the failure mode that wedged main).
/// Gated by DDR_STRESS so the normal fast boot path is unaffected.
fn stressVerify(con: *uart.Ns16550a) void {
    const b = cfg.dram_base;
    // --- 1. Pattern cleanliness + per-DQ-bit error map --------------------------
    // Write each pattern to 4 consecutive words, read back voted, OR the per-bit
    // differences across the 4 words. A set bit in errAll = that DQ position (mod
    // 32; DQ0..15 repeat every 16 bits on the 16-bit bus) mis-sampled at least
    // once. errLo/errHi split the two beats to expose the 2nd-beat scramble.
    const pats = [_]u32{ 0x5A5A5A5A, 0xC0DEC0DE };
    for (pats) |pat| {
        // Separate lines (no same-line write collision - see LINE/writeReadback).
        w32(b + 0 * LINE, pat);
        w32(b + 1 * LINE, pat);
        w32(b + 2 * LINE, pat);
        w32(b + 3 * LINE, pat);
        _ = r32(b + 0 * LINE);
        var errAll: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            errAll |= readVoted(b + i * LINE) ^ pat;
        }
        con.writeStr("[fsbl] ddr: VERIFY pat=");
        hex8(con, pat);
        con.writeStr(" biterr=");
        hex8(con, errAll);
        // popcount of the low 16 (the 16 DQ lanes) = distinct lanes in error.
        var lanes: u32 = 0;
        var m: u32 = 0;
        while (m < 16) : (m += 1) {
            if ((errAll | (errAll >> 16)) & (@as(u32, 1) << @intCast(m)) != 0) lanes += 1;
        }
        con.writeStr(" lanes_err=");
        hexNibble(con, @intCast((lanes >> 4) & 0xF));
        hexNibble(con, @intCast(lanes & 0xF));
        con.writeStr(if (errAll == 0) " CLEAN\n" else " DIRTY\n");
    }
    // --- 2. Sustained SEQ + pseudo-random stress --------------------------------
    // Write a marching pattern over STRESS_WORDS words, then read every word back
    // and count mismatches. Uses a 32-bit LCG so the data is address-dependent
    // (catches stuck-bit / aliasing) and the read pass is a long continuous burst
    // (the sustained-read pattern Linux would drive that wedged main historically).
    const STRESS_WORDS: usize = 8192; // 32 KiB window, ~keeps the UART window short
    var seed: u32 = 0x1234_5678;
    var addr: usize = 0;
    while (addr < STRESS_WORDS) : (addr += 1) {
        seed = seed *% 1664525 +% 1013904223;
        w32(b + addr * 4, seed ^ @as(u32, @intCast(addr)));
    }
    seed = 0x1234_5678;
    var errs: u32 = 0;
    addr = 0;
    while (addr < STRESS_WORDS) : (addr += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const want = seed ^ @as(u32, @intCast(addr));
        // Sustained: a plain read (NOT voted) so this measures the raw eye under
        // a continuous burst, exactly as main's ifetch/loads hit it.
        if (r32(b + addr * 4) != want) errs += 1;
    }
    con.writeStr("[fsbl] ddr: STRESS words=");
    hex8(con, @intCast(STRESS_WORDS));
    con.writeStr(" errs=");
    hex8(con, errs);
    con.writeStr(if (errs == 0) " SUSTAINED-CLEAN\n" else " SUSTAINED-ERRORS\n");
}

/// Bulk STREAMING read-error count. Writes [nwords] LCG words with PER-WORD
/// verify-retry (so the DRAM data is ground truth - isolates the READ path from
/// the marginal write path), then reads them ALL back in one continuous burst and
/// counts mismatches. Unlike the paced 4-word tapPasses (which a marginal eye can
/// pass), this is the back-to-back streaming read main Weir's icache fetches hit -
/// the access pattern that actually wedges the boot. Returns the mismatch count.
fn bulkReadErrs(nwords: usize) u32 {
    const b = cfg.dram_base;
    var seed: u32 = 0x1234_5678;
    var i: usize = 0;
    while (i < nwords) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        var tries: usize = 0;
        while (tries < 16) : (tries += 1) {
            w32(b + i * 4, seed);
            if (r32(b + i * 4) == seed) break;
        }
    }
    seed = 0x1234_5678;
    var errs: u32 = 0;
    i = 0;
    while (i < nwords) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        if (r32(b + i * 4) != seed) errs += 1;
    }
    return errs;
}

/// Xilinx read-setup: pin the read-pipe WINDOW (reg12) + centre the per-lane
/// IDELAY (reg10), then measure the STREAMING read-error rate. If window 5 is not
/// clean, sweep the window 0..7 (the read-launch-cycle framing lever the paced
/// eye test cannot see) and park the best. Runs before the copy so both the FSBL
/// copy AND main Weir read the framed eye. Reports its numbers over UART.
/// Bulk STREAMING WRITE-then-read error count: write [nwords] LCG words BACK-TO-
/// BACK (NO verify-retry - the streaming store pattern Weir's stack pushes and
/// data stores hit, vs the FSBL copy's paced verify-retry), then streaming-read
/// them back and count mismatches. Isolates the streaming WRITE path (the copy
/// already proves paced writes land; this proves whether back-to-back ones do).
fn streamWriteErrs(nwords: usize) u32 {
    const b = cfg.dram_base;
    var seed: u32 = 0x2468_1357;
    var i: usize = 0;
    while (i < nwords) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        w32(b + i * 4, seed);
    }
    seed = 0x2468_1357;
    var errs: u32 = 0;
    i = 0;
    while (i < nwords) : (i += 1) {
        seed = seed *% 1664525 +% 1013904223;
        if (r32(b + i * 4) != seed) errs += 1;
    }
    return errs;
}

/// Pin the read-pipe WINDOW + centre the read taps, then verify the STREAMING
/// eye. Returns true iff streaming read+write are clean (the framed eye main Weir
/// needs). On a clean result the caller uses DRAM directly; on failure it sweeps
/// the window for the best, and if still dirty returns false so the caller falls
/// through to the legacy per-lane sweep.
/// PER-LANE read-eye centring (the deterministic-boot fix). With the read-pipe
/// WINDOW pinned, write four eye patterns to four lines - all-0, all-1, and both
/// alternating phases, so every DQ lane sees 0s AND 1s with worst-case ISI, and
/// all four are half-swap invariant (robust to the beat packing). Then for each
/// lane, sweep its IDELAY tap 0..31 and record the widest CONTIGUOUS run of taps
/// where that lane's two beat bits read back correct across a few passes; park the
/// lane at the run's CENTRE. A uniform tap leaves skewed lanes near their eye edge
/// - the source of the rare metastable read that made the boot non-deterministic
/// (a single glitched fetch faults Ferrite). Centring each lane independently
/// maximises per-lane margin so sustained reads stay clean.
fn rdCenterLanes() void {
    const b = cfg.dram_base;
    rdSetAllTaps(RD_CENTER_TAP); // nominal so the word reads well enough to judge
    const pats = [_]u32{ 0x00000000, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA };
    inline for (pats, 0..) |p, i| w32(b + i * LINE, p);
    _ = r32(b + 0 * LINE); // warm-up
    var lane: u32 = 0;
    while (lane < DQ_BITS) : (lane += 1) {
        const mask: u32 = (@as(u32, 1) << @intCast(lane)) | (@as(u32, 1) << @intCast(lane + 16));
        var lo: i32 = -1;
        var hi: i32 = -1;
        var tap: u32 = 0;
        while (tap < RD_TAP_TOP) : (tap += 1) {
            rdSetLaneTap(lane, tap);
            var pass = true;
            var k: u32 = 0;
            while (k < 3 and pass) : (k += 1) {
                _ = r32(b + 0 * LINE); // warm-up each pass
                inline for (pats, 0..) |p, i| {
                    if ((r32(b + i * LINE) ^ p) & mask != 0) pass = false;
                }
            }
            if (pass) {
                if (lo < 0) lo = @intCast(tap);
                hi = @intCast(tap);
            }
        }
        const center: u32 = if (lo >= 0) @intCast(@divTrunc(lo + hi, 2)) else RD_CENTER_TAP;
        rdSetLaneTap(lane, center);
    }
}

/// Centre the DQS strobe's own IDELAY eye (dqsGatedRead builds). DQS is edge-
/// aligned with DQ, so the DQ-centred tap lands DQS on its transition edge (it
/// reads a partial 0xA0). Sweep the DQS IDELAY (sentinel lane), driving a fresh
/// DDR read per tap so the strobe bursts, and lock the centre of the taps where
/// reg7 (the raw DQS capture) reads a clean 0xAA/0x55. No-op if none is found.
fn dqsCenterEye(con: *uart.Ns16550a) void {
    var lo: i32 = -1;
    var hi: i32 = -1;
    var samples = [_]u32{ 0, 0, 0, 0 };
    var tap: u32 = 0;
    while (tap < RD_TAP_TOP) : (tap += 1) {
        rdSetLaneTap(DQS_LANE, tap);
        // Fresh DDR read (stride by a line so each misses the dcache) to burst the
        // strobe; reg7 latches this read's captured DQS.
        _ = r32(cfg.dram_base + tap * 64);
        var s: usize = 0;
        while (s < 4) : (s += 1) _ = r32(cfg.ddr_train_base + STATUS);
        const raw = r32(cfg.ddr_train_base + DQS_DBG) & 0xFF;
        if (tap == 0) samples[0] = raw;
        if (tap == 8) samples[1] = raw;
        if (tap == 16) samples[2] = raw;
        if (tap == 24) samples[3] = raw;
        if (raw == 0xAA or raw == 0x55) {
            if (lo < 0) lo = @intCast(tap);
            hi = @intCast(tap);
        }
    }
    // Confirm the DQS IDELAY sweep actually moves the capture: if these differ, the
    // sentinel VAR_LOAD works; if all identical, the tap is not being loaded.
    con.writeStr("[fsbl] ddr: dqs-samples t0/8/16/24=");
    hex8(con, samples[0]);
    con.putc('/');
    hex8(con, samples[1]);
    con.putc('/');
    hex8(con, samples[2]);
    con.putc('/');
    hex8(con, samples[3]);
    con.putc('\n');
    if (lo >= 0) {
        const centre: u32 = @intCast(@divTrunc(lo + hi, 2));
        rdSetLaneTap(DQS_LANE, centre);
        con.writeStr("[fsbl] ddr: dqs-eye tap=");
        hex8(con, centre);
        con.writeStr(" width=");
        hex8(con, @intCast(hi - lo + 1));
        con.putc('\n');
    } else {
        con.writeStr("[fsbl] ddr: dqs-eye NONE\n");
    }
}

/// Pulse the per-DQ-bit fabric bitslip rotate once for every DQ bit (reg11 with
/// [4]=slip, [3:0]=lane). Advances each lane read-beat rotation by one beat, so
/// all 8 bits of the byte lane frame together.
fn bitslipPulseAll() void {
    var l: u32 = 0;
    while (l < 8) : (l += 1) {
        w32(cfg.ddr_train_base + RD_BITSLIP, 0x10 | l);
    }
}

/// The live read path never wrote reg11, so every lane sits at bitslip rotate 0,
/// which frames the burst one beat late (read data comes back byte-rotated:
/// got == exp << 8). Sweep the rotate 0..7: at each step write a distinctive
/// per-word tag, read it back and count matches, and lock at the rotation where
/// all words read exactly. The WL feedback uses the SAME capture path, so a
/// locked read frame is also what lets write-leveling see its DQ feedback.
fn rdBitslipAlign(con: *uart.Ns16550a) bool {
    const b = cfg.dram_base;
    var bs: u32 = 0;
    while (bs < 8) : (bs += 1) {
        // Hammer each write (writes are marginal at rated CK, so a single write
        // may not land; repetition forces it), isolating the READ bitslip.
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            var h: u32 = 0;
            while (h < 16) : (h += 1) w32(b + i * 4, 0xC0DE0000 | i);
        }
        _ = r32(b + 0);
        var m: u32 = 0;
        i = 0;
        while (i < 8) : (i += 1) {
            if (r32(b + i * 4) == (0xC0DE0000 | i)) m += 1;
        }
        con.writeStr("[fsbl] ddr: bsalign bs=");
        hexNibble(con, @intCast(bs & 0xF));
        con.writeStr(" match=");
        hexNibble(con, @intCast(m & 0xF));
        con.writeStr("/8 w0=");
        hex8(con, r32(b + 0));
        con.putc('\n');
        if (m == 8) {
            con.writeStr("[fsbl] ddr: bsalign LOCKED bs=");
            hexNibble(con, @intCast(bs & 0xF));
            con.putc('\n');
            return true;
        }
        bitslipPulseAll();
    }
    con.writeStr("[fsbl] ddr: bsalign NO-LOCK\n");
    return false;
}

/// Definitive framing probe: is the read data recoverable by any (RDSLACK,
/// bitslip) frame at the current CK? Window is already at its best tap. For each
/// RDSLACK 0..3, sweep the per-bit bitslip rotate 0..7, hammer-write a known tag
/// set, read back and count matches. Locks (and leaves the frame set) at the
/// first combo that reads all 8 words exactly. A NO-LOCK means the one-beat
/// capture offset is not a pure frame rotation (deeper CL / half-cycle issue).
fn rdFrameProbe(con: *uart.Ns16550a) bool {
    const b = cfg.dram_base;
    var slk: u32 = 0;
    while (slk < 4) : (slk += 1) {
        setRdSlack(slk);
        var bs: u32 = 0;
        while (bs < 8) : (bs += 1) {
            var i: u32 = 0;
            while (i < 8) : (i += 1) {
                var h: u32 = 0;
                while (h < 8) : (h += 1) w32(b + i * 4, 0xC0DE0000 | i);
            }
            _ = r32(b + 0);
            var m: u32 = 0;
            i = 0;
            while (i < 8) : (i += 1) {
                if (r32(b + i * 4) == (0xC0DE0000 | i)) m += 1;
            }
            con.writeStr("[fsbl] ddr: frame slk=");
            hexNibble(con, @intCast(slk & 0xF));
            con.writeStr(" bs=");
            hexNibble(con, @intCast(bs & 0xF));
            con.writeStr(" m=");
            hexNibble(con, @intCast(m & 0xF));
            con.writeStr(" w0=");
            hex8(con, r32(b + 0));
            con.putc('\n');
            if (m == 8) {
                con.writeStr("[fsbl] ddr: frame LOCKED slk=");
                hexNibble(con, @intCast(slk & 0xF));
                con.writeStr(" bs=");
                hexNibble(con, @intCast(bs & 0xF));
                con.putc('\n');
                return true;
            }
            bitslipPulseAll();
        }
    }
    con.writeStr("[fsbl] ddr: frame NO-LOCK\n");
    return false;
}

fn rdReadSetup(con: *uart.Ns16550a) bool {
    // Refresh level = 2 (4x tREFI, 1.95us). DDR3 retention halves above 85C and
    // this board heats under load, so run the max refresh rate for retention (the
    // openXC7 toolchain has no XADC, so there is no on-die temperature source; the
    // FSBL picks the rate and Linux can retune reg13 down when cool for bandwidth).
    w32(cfg.ddr_train_base + RD_REFRESH, 2);
    rdSetWindow(RD_WINDOW_VAL);
    // Per-lane widest-contiguous-run IDELAY centring (was dead code): a uniform
    // tap leaves skewed lanes at their eye edge, so a single glitched fetch faults
    // Ferrite. Centring each lane at its own eye centre maximises per-lane margin
    // for main's sustained i+d fetch cadence, where the paced bulk verify is clean
    // but the streaming reads were marginal.
    rdCenterLanes();
    const e0 = bulkReadErrs(16384);
    const we = streamWriteErrs(16384);
    con.writeStr("[fsbl] ddr: read-setup win5 per-lane-centred bulkerrs=");
    hex8(con, e0);
    con.writeStr(" streamwrite=");
    hex8(con, we);
    con.putc('\n');
    // DIAGNOSTIC (dqsGatedRead build): reg7 read = the sticky DQS burst-position
    // map (which rd_pipe taps [7:0] saw the 0xAA/0x55 strobe over all the reads
    // above). One stable bit near RD_WINDOW_VAL=5 => a fixed offset can align it;
    // a spread => the strobe position varies per read.
    con.writeStr("[fsbl] ddr: dqs-raw=");
    hex8(con, r32(cfg.ddr_train_base + DQS_DBG));
    con.putc('\n');
    if (e0 == 0 and we == 0) return true;
    // Not clean: the live path never swept READCLKSEL (the DQSBUFM read-gate /
    // bitslip position). rdCenterLanes centres per-bit IDELAY and rdSetWindow
    // moves the pipe cycle, but neither reaches a sub-window (beat-level) frame
    // offset. Sweep the read-gate (RCS 0..7), re-centre per-bit IDELAY at each,
    // and keep the position with the fewest errors. LiteDRAM sweeps bitslip x
    // delay the same way; this is the framing freedom the live path was missing.
    var bestRcs: u32 = 0;
    var rcsErr: u32 = e0;
    var rcs: u32 = 0;
    while (rcs < RCS_TOP) : (rcs += 1) {
        setReadClkSel(rcs);
        rdCenterLanes();
        const e = bulkReadErrs(4096);
        con.writeStr("[fsbl] ddr: rcs=");
        hexNibble(con, @intCast(rcs & 0xF));
        con.writeStr(" errs=");
        hex8(con, e);
        con.putc('\n');
        if (e < rcsErr) {
            rcsErr = e;
            bestRcs = rcs;
        }
    }
    setReadClkSel(bestRcs);
    rdCenterLanes();
    // Now at the best read-gate: sweep the read-pipe window for the best.
    var bestWin: u32 = RD_WINDOW_VAL;
    var bestErr: u32 = rcsErr;
    var win: u32 = 0;
    while (win < 8) : (win += 1) {
        rdSetWindow(win);
        const e = bulkReadErrs(4096);
        if (e < bestErr) {
            bestErr = e;
            bestWin = win;
        }
    }
    rdSetWindow(bestWin);
    con.writeStr("[fsbl] ddr: read-setup best win=");
    hexNibble(con, @intCast(bestWin & 0xF));
    con.writeStr(" errs=");
    hex8(con, bestErr);
    con.putc('\n');
    const locked = rdFrameProbe(con);
    if (locked) {
        const e = bulkReadErrs(4096);
        con.writeStr("[fsbl] ddr: post-bitslip bulkerrs=");
        hex8(con, e);
        con.putc('\n');
        if (e == 0) bestErr = 0;
    }
    rdErrPattern(con);
    return bestErr == 0;
}

/// Characterise the 25% read-error floor that is invariant to RCS/window/IDELAY.
/// Write a per-word index tag C0DE0000|i (retry-verified, so the DATA is known
/// good in DRAM), then bulk-read and classify each failing word by its 4:1-phase
/// slot (i & 3), OR-accumulate which DQ bits ever mismatch, and count re-read
/// changes (determinism). Failures on ONE phase slot => the 4:1 beat-gather, not
/// the PHY read capture, is the fault.
fn rdErrPattern(con: *uart.Ns16550a) void {
    const b = cfg.dram_base;
    const N: u32 = 16384; // 64KB span, 16 blocks of 4KB (1024 words each)
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const v: u32 = 0xC0DE0000 | i;
        var t: usize = 0;
        while (t < 16) : (t += 1) {
            w32(b + i * 4, v);
            if (r32(b + i * 4) == v) break;
        }
    }
    var blk = [_]u16{0} ** 16; // fails per 4KB block
    var zeros: u32 = 0; // failures that read exactly 0 (idle-bus capture)
    var errs: u32 = 0;
    var samp: u32 = 0;
    var orDiff: u32 = 0; // OR of all (got ^ exp): which bit positions ever differ
    i = 0;
    while (i < N) : (i += 1) {
        const exp: u32 = 0xC0DE0000 | i;
        const got = r32(b + i * 4);
        if (got != exp) {
            errs += 1;
            blk[i >> 10] += 1;
            orDiff |= got ^ exp;
            if (got == 0) zeros += 1;
            if (samp < 6) {
                con.writeStr("[fsbl] ddr: errpat i=");
                hex8(con, i);
                con.writeStr(" exp=");
                hex8(con, exp);
                con.writeStr(" got=");
                hex8(con, got);
                con.putc('\n');
                samp += 1;
            }
        }
    }
    con.writeStr("[fsbl] ddr: errpat orDiff=");
    hex8(con, orDiff);
    con.putc('\n');
    con.writeStr("[fsbl] ddr: errpat total=");
    hex8(con, errs);
    con.writeStr(" zeros=");
    hex8(con, zeros);
    con.writeStr("\n[fsbl] ddr: errpat blocks(4KB each)=");
    var k: u32 = 0;
    while (k < 16) : (k += 1) {
        hexNibble(con, @intCast((blk[k] >> 8) & 0xF));
        hexNibble(con, @intCast((blk[k] >> 4) & 0xF));
        hexNibble(con, @intCast(blk[k] & 0xF));
        con.putc(' ');
    }
    con.putc('\n');
}

/// Program a full read setting: RDTAP (reg0+SET), READCLKSEL (reg4), RDSLACK
/// (reg2). Never touches the write path (reg7/reg8), so the WL-trained write
/// pointer is preserved across the whole read sweep.
fn setRead(tap: u7, rcs: u32, slk: u32) void {
    setReadClkSel(rcs);
    setRdSlack(slk);
    walkTap(tap);
}

/// Result of the read-framing search for a fixed write setting.
const FrameResult = struct {
    n: u8, // best matchCount found (0..4)
    tap: u7,
    rcs: u32,
    slk: u32,
};

/// Reduced read-framing tap set: only these 3 taps are walked (walkTap is the
/// 1M-poll expensive op). The read eye centre was ~40 on this silicon (memory
/// project_creek_weir_readtap: tap40 best); bracket it with 0 and 80.
const FRAME_TAPS = [_]u7{ 0, 40, 80 };
const FRAME_SLK_TOP: u32 = 4; // RDSLACK 0..3 (the useful window range)

/// With the write launch (reg7) and per-lane DYNDELAY (reg8) already programmed,
/// sweep only the READ framing (RCS=bitslip x RDSLACK x a small RDTAP set) and
/// return the best matchCount + the combo that achieved it. Fast: at most
/// 8 x 4 x 3 = 96 read-backs, walkTap called only 3x per (rcs,slk) via the tap
/// inner loop. Stops early on a full 4/4 match.
fn frameSweep() FrameResult {
    var best: FrameResult = .{ .n = 0, .tap = 0, .rcs = 0, .slk = 0 };
    var rcs: u32 = 0;
    while (rcs < RCS_TOP) : (rcs += 1) {
        var slk: u32 = 0;
        while (slk < FRAME_SLK_TOP) : (slk += 1) {
            for (FRAME_TAPS) |tap| {
                setRead(tap, rcs, slk);
                var w: [4]u32 = undefined;
                writeReadback(&w);
                const n = matchCount(&w);
                if (n > best.n) {
                    best = .{ .n = n, .tap = tap, .rcs = rcs, .slk = slk };
                    if (n == 4) return best;
                }
            }
        }
    }
    return best;
}

/// Result of the READ-PULSE-POSITION framing search. `pos` is the reg11 RDPULSE
/// value; `n` the best matchCount reached there; `bdet` whether BURSTDET (or its
/// sticky seen bit) asserted at that pulse position (the DQSBUFM saw a valid read
/// burst in the window). `fr` carries the RCS/RDSLACK/RDTAP that hit `n`.
const PulseResult = struct {
    pos: u32,
    n: u8,
    bdet: bool,
    fr: FrameResult,
};

// A uniform framing pattern whose captured-lane bytes are distinctive. The DQS
// read captures the two byte lanes independently. HW probe: 0x5A5A5A5A read back
// 0x5AFF5AFF at the framed pulse position, i.e. bytes 1,3 (0x5A) carry the REAL
// DATA while bytes 0,2 (0xFF) are the FLOATING lane. So the CAPTURED lane is mask
// 0xFF00FF00 (bytes 1,3) and the floating lane is 0x00FF00FF (bytes 0,2). A full
// 4-word match is impossible until the floating lane is landed, so the FRAMING
// search must score by CAPTURED-LANE tracking (mask out the float), NOT a full
// 4-word match. Once the captured lane frames, the per-lane DYNDELAY sweep lands
// the other lane in the SAME window and full matches become possible.
const CAP_LANE_MASK: u32 = 0xFF00FF00; // bytes 1 and 3 = the captured DQS lane

/// Write a uniform pattern to dram_base, warm-up read, read word0 back (voted),
/// and return TRUE iff the CAPTURED lane (bytes 1,3) reads back the written
/// pattern's bytes there. This is the burst-framing witness: the captured lane
/// tracking the written data means the read pulse has landed the window on the
/// DATA BURST (not the preamble constant, which is data-INVARIANT). The floating
/// lane (bytes 0,2 = FF) is masked out - it is landed later by per-lane DYNDELAY.
fn lane0Frames(pat: u32) bool {
    const b = cfg.dram_base;
    // Two SEPARATE lines (no same-line write collision - see LINE/writeReadback).
    w32(b + 0 * LINE, pat);
    w32(b + 1 * LINE, pat);
    _ = r32(b + 0 * LINE); // warm-up
    const w0 = readVoted(b + 0 * LINE);
    return (w0 & CAP_LANE_MASK) == (pat & CAP_LANE_MASK);
}

/// Does the read at the CURRENT framing TRACK the written data on lane 0? Writes
/// TWO different uniform patterns and confirms lane-0 readback DIFFERS between them
/// AND each matches its own written lane-0 bytes. This rejects a data-INVARIANT
/// preamble capture (which reads the same constant regardless of what was written)
/// - the exact fault the read-pulse fix targets. Returns a 0..2 confidence score.
fn lane0TracksData() u8 {
    var score: u8 = 0;
    if (lane0Frames(0x5A5A5A5A)) score += 1;
    if (lane0Frames(0xA5A5A5A5)) score += 1;
    return score;
}

// === Distinct framing patterns (bringup-debugger, 2026-07-10) ================
// 0x5A5A5A5A is BYTE-UNIFORM, so it is invariant under the RCS 8-beat rotation,
// RDSLACK whole-cycle shift, and packWord half-swap - it CANNOT distinguish a
// framed-but-bit-permuted capture (0x72 read for a 0x5A write = a WITHIN-BYTE
// per-DQ read-timing skew) from a correct one. So framing uses TWO distinct
// pattern families:
//   (a) BEAT identity: a C0DE counting line C0DE0000/1111/2222/3333, one word per
//       separate BL8 line, scored on "reads back IN ORDER" (the beat/word gather
//       is correct). This drives RCS/RDSLACK/reg11 framing.
//   (b) BIT identity: a walking-1 across the 16 DQ lanes (0x0001,0x0002,...,0x8000
//       replicated into both 16-bit halves). Read back, the set bit names the
//       exact DQ lane; a per-bit deskew walk (reg10) closes the 0x72->0x5A skew.
const CNT0: u32 = 0xC0DE0000;
const CNT1: u32 = 0xC0DE1111;
const CNT2: u32 = 0xC0DE2222;
const CNT3: u32 = 0xC0DE3333;

// POPCOUNT-DISTINCT framing pattern (bringup-debugger, 2026-07-10, THE unlock).
// Each DQ bit has its OWN Ecp5Iddrx2dqa + OWN Ecp5Delayf, so a per-DQ read-timing
// skew can cross a bit into the neighbor BEAT - the captured 32-bit word is a
// per-bit MIXTURE of beats. So NO value-based frame metric (exact-match, distinct
// value, hamming) can separate "beats framed" from "bits deskewed": both permute
// the composed word. BUT popcount is INVARIANT under any WITHIN-byte bit
// permutation. So frame the BEAT/WORD gather with 4 words whose CAPTURED-LANE
// bytes have DISTINCT popcounts 1,2,3,4 (0x01,0x03,0x07,0x0F): they stay
// distinguishable no matter how the bits within a byte are permuted, and if bits
// cross beats BETWEEN words the popcounts smear and the ordered set breaks = the
// correct "not framed" signal. (Distinct-VALUE fails: 0x55/0xAA are bit-perms of
// each other, both popcount 8, and alias.) Captured lane = bytes 1,3 (0xFF00FF00);
// the floating/other lane (bytes 0,2) is a don't-care until DYNDELAY lands it.
const POP0: u32 = 0x01000100; // captured-lane bytes 0x01 -> popcount 1
const POP1: u32 = 0x03000300; // popcount 2
const POP2: u32 = 0x07000700; // popcount 3
const POP3: u32 = 0x0F000F00; // popcount 4

// BOTH-LANE popcount patterns: the popcount value in ALL FOUR bytes (both DQS
// lanes), so a per-lane land score can check the FLOAT lane (bytes 0,2) too. The
// original POPn set only the captured-lane bytes (1,3) and left lane0 bytes 0x00
// (popcount 0), which made popFrameScoreBoth STRUCTURALLY unable to ever score the
// float lane (0x00 popcount 0 != want) => land fn0 every boot regardless of whether
// lane0 physically captured. These replicate the distinct popcounts 1,2,3,4 into
// every byte so BOTH lanes are scorable (still popcount-invariant under the
// pre-deskew within-byte DQ permutation).
const POPB0: u32 = 0x01010101; // all bytes 0x01 -> popcount 1
const POPB1: u32 = 0x03030303; // popcount 2
const POPB2: u32 = 0x07070707; // popcount 3
const POPB3: u32 = 0x0F0F0F0F; // popcount 4

/// Write the C0DE counting line (each word to its OWN BL8 line, no same-line
/// collision), read back voted, and return how many of the 4 words read back
/// their written value IN ORDER (0..4). This is the BEAT-identity frame score:
/// a high count means the read window frames the burst AND the beat/word gather
/// order is correct (the RCS/RDSLACK/reg11 combo is right). Independent of the
/// within-byte per-DQ skew (that is closed later by reg10 deskew).
fn cntInOrder() u8 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, CNT0);
    w32(b + 1 * LINE, CNT1);
    w32(b + 2 * LINE, CNT2);
    w32(b + 3 * LINE, CNT3);
    _ = r32(b + 0 * LINE);
    var n: u8 = 0;
    if (readVoted(b + 0 * LINE) == CNT0) n += 1;
    if (readVoted(b + 1 * LINE) == CNT1) n += 1;
    if (readVoted(b + 2 * LINE) == CNT2) n += 1;
    if (readVoted(b + 3 * LINE) == CNT3) n += 1;
    return n;
}

/// CAPTURED-LANE beat-frame score on the C0DE counting line: like cntInOrder but
/// masks to the captured DQS lane (bytes 1,3) so it scores framing even while the
/// other lane still floats (landed later by DYNDELAY). 0..4.
fn cntInOrderCap() u8 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, CNT0);
    w32(b + 1 * LINE, CNT1);
    w32(b + 2 * LINE, CNT2);
    w32(b + 3 * LINE, CNT3);
    _ = r32(b + 0 * LINE);
    // Plain (non-voted) reads in the frame SEARCH: fast, and a spurious marginal
    // read only costs a missed combo (re-scored voted at accept). 512 combos with
    // voting would blow the UART window.
    var n: u8 = 0;
    const m = CAP_LANE_MASK;
    if ((r32(b + 0 * LINE) & m) == (CNT0 & m)) n += 1;
    if ((r32(b + 1 * LINE) & m) == (CNT1 & m)) n += 1;
    if ((r32(b + 2 * LINE) & m) == (CNT2 & m)) n += 1;
    if ((r32(b + 3 * LINE) & m) == (CNT3 & m)) n += 1;
    return n;
}

/// Popcount of the captured-lane bytes (1,3) of a word, summed. For a POPn word
/// framed correctly this = n (both captured bytes carry the same popcount-n value,
/// but we take byte3 as the witness since both bytes are equal in POPn). We use
/// byte3's popcount as the per-word popcount witness.
fn capBytePop(w: u32) u8 {
    return popc((w >> 24) & 0xFF);
}

/// POPCOUNT-DISTINCT beat-frame score: write the 4 popcount-distinct words (each
/// to its own line), read back voted, and return TRUE iff the captured lane reads
/// them back with byte-popcounts {1,2,3,4} IN THE RCS-DEFINED ORDER. Robust to any
/// within-byte per-DQ bit permutation (popcount-invariant); breaks only if the
/// beat gather is wrong (bits cross beats between words -> popcounts smear). This
/// is the frame oracle that survives the pre-deskew bit permutation.
fn popFramed() bool {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, POP0);
    w32(b + 1 * LINE, POP1);
    w32(b + 2 * LINE, POP2);
    w32(b + 3 * LINE, POP3);
    _ = r32(b + 0 * LINE);
    return capBytePop(readVoted(b + 0 * LINE)) == 1 and
        capBytePop(readVoted(b + 1 * LINE)) == 2 and
        capBytePop(readVoted(b + 2 * LINE)) == 3 and
        capBytePop(readVoted(b + 3 * LINE)) == 4;
}

/// Number of the 4 popcount-distinct words whose captured-lane byte popcount
/// matches the expected {1,2,3,4} in order (0..4). A partial score guides the
/// search toward the best frame even when not all 4 land.
fn popFrameScore() u8 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, POP0);
    w32(b + 1 * LINE, POP1);
    w32(b + 2 * LINE, POP2);
    w32(b + 3 * LINE, POP3);
    _ = r32(b + 0 * LINE);
    var n: u8 = 0;
    if (capBytePop(r32(b + 0 * LINE)) == 1) n += 1;
    if (capBytePop(r32(b + 1 * LINE)) == 2) n += 1;
    if (capBytePop(r32(b + 2 * LINE)) == 3) n += 1;
    if (capBytePop(r32(b + 3 * LINE)) == 4) n += 1;
    return n;
}

/// BOTH-lane popcount frame score (0..4): like popFrameScore but requires BOTH
/// captured bytes (1 and 3) AND both floating-lane bytes (0 and 2) of each word to
/// carry the expected popcount. Used to land the OTHER lane's DYNDELAY: as the
/// floating lane comes onto the burst, its bytes start carrying the right popcount
/// too, so this rises to 4 when both lanes are framed - robust to the pre-deskew
/// per-DQ bit permutation (popcount-invariant).
fn popFrameScoreBoth() u8 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, POPB0);
    w32(b + 1 * LINE, POPB1);
    w32(b + 2 * LINE, POPB2);
    w32(b + 3 * LINE, POPB3);
    _ = r32(b + 0 * LINE);
    const want = [_]u8{ 1, 2, 3, 4 };
    var n: u8 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const w = readVoted(b + i * LINE);
        // both lanes' bytes: byte3+byte1 (cap) and byte2+byte0 (float) each == want.
        if (popc((w >> 24) & 0xFF) == want[i] and popc((w >> 8) & 0xFF) == want[i] and
            popc((w >> 16) & 0xFF) == want[i] and popc(w & 0xFF) == want[i]) n += 1;
    }
    return n;
}

// Captured-lane and float-lane byte masks (the two DQS byte lanes). HW-decisive
// (2026-07-11 lane0 classification, gttrack probe): at rdpulse pos1 BOTH lanes'
// bytes read back written data (CF=BOTH); at the captured-lane-only positions the
// float lane reads 0xFF. So the read-pulse position that captures BOTH lanes is
// pos1, NOT the position that maximizes the captured-lane-only popcount (which is
// high at many positions incl. the lane0-float ones). framePulse must select on a
// BOTH-lane signal, not the captured-lane-only score.
var g_maxBoth: u8 = 0; // framePulse: max bothLaneTrack seen in the search (probe)
var g_bothPos: u32 = 0; // rdpulse pos where g_maxBoth was seen
var g_bothRcs: u32 = 0;
var g_bothSlk: u32 = 0;
const CAP_MASK: u32 = 0xFF00FF00; // bytes 1,3 = the captured DQS lane (lane1)
const FLT_MASK: u32 = 0x00FF00FF; // bytes 0,2 = the float DQS lane (lane0)

/// BOTH-LANE DATA-TRACK score (0..2) at the CURRENT read setting, PERMUTATION-ROBUST.
/// Write 0x5A then 0xA5 (bitwise-distinct) and return +1 if the captured lane's
/// bytes DIFFER between the two writes (that lane tracks the written data, i.e. is
/// captured - not a fixed 0xFF float or a data-invariant preamble constant), +1 if
/// the float lane's bytes DIFFER. Score 2 = BOTH byte lanes are captured in the
/// SAME read window at this (rdpulse,rcs,slk). This is the signal that finds the
/// rdpulse position where lane0 stops floating; it needs no clean popcount (works
/// before per-bit deskew, when the bytes are bit-permuted).
fn bothLaneTrack() u8 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, 0x5A5A5A5A);
    w32(b + 1 * LINE, 0x5A5A5A5A);
    _ = r32(b + 0 * LINE);
    const w5 = readVoted(b + 0 * LINE);
    w32(b + 0 * LINE, 0xA5A5A5A5);
    w32(b + 1 * LINE, 0xA5A5A5A5);
    _ = r32(b + 0 * LINE);
    const wa = readVoted(b + 0 * LINE);
    var n: u8 = 0;
    if ((w5 & CAP_MASK) != (wa & CAP_MASK)) n += 1;
    if ((w5 & FLT_MASK) != (wa & FLT_MASK)) n += 1;
    return n;
}

/// Read the C0DE counting line and return the OR of per-bit errors across the 4
/// words (each word vs its written value), so a set bit names a DQ position (mod
/// 32) that mis-samples. Used to drive the per-bit deskew: minimize this.
fn cntBitErr() u32 {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, CNT0);
    w32(b + 1 * LINE, CNT1);
    w32(b + 2 * LINE, CNT2);
    w32(b + 3 * LINE, CNT3);
    _ = r32(b + 0 * LINE);
    var e: u32 = 0;
    e |= readVoted(b + 0 * LINE) ^ CNT0;
    e |= readVoted(b + 1 * LINE) ^ CNT1;
    e |= readVoted(b + 2 * LINE) ^ CNT2;
    e |= readVoted(b + 3 * LINE) ^ CNT3;
    return e;
}

/// Popcount of a 32-bit word (DQ error count over the 2 beats).
fn popc(v: u32) u8 {
    var x = v;
    var n: u8 = 0;
    while (x != 0) : (x &= x - 1) n += 1;
    return n;
}

/// PER-BIT DQ DESKEW at the CURRENT (framed) read setting. For each of the 16 DQ
/// lanes walk its Ecp5Delayf over DESKEW_TAPS and keep the tap that minimizes the
/// C0DE-line bit-error (the within-byte 0x72->0x5A skew closer). Greedy per-bit:
/// a bit's own DELAYF only affects that bit, so accepting each bit's best tap
/// never worsens the others. Returns the final in-order match count (0..4).
fn deskewAll(con: *uart.Ns16550a) u8 {
    // Coarser tap set (8 taps) to keep the 16-bit walk inside the UART window; each
    // deskewBit does a walkTap (up to POLL_LIMIT poll), so 16*13 was minutes.
    const DESKEW_TAPS = [_]u7{ 0, 32, 64, 96 };
    con.writeStr("[fsbl] ddr: deskew ");
    var dq: u32 = 0;
    while (dq < DQ_BITS) : (dq += 1) {
        var bestTap: u7 = 0;
        var bestErr: u8 = 0xFF;
        for (DESKEW_TAPS) |t| {
            deskewBit(dq, t);
            const e = popc(cntBitErr());
            if (e < bestErr) {
                bestErr = e;
                bestTap = t;
                if (e == 0) break;
            }
        }
        deskewBit(dq, bestTap);
        con.putc('.'); // one dot per DQ bit deskewed (progress = not wedged)
    }
    con.putc('\n');
    setDeskewBroadcast();
    return cntInOrder();
}

/// THE BURST-FRAMING SWEEP (the fix). Walk the INDEPENDENT read-pulse position
/// (reg11 RDPULSE) 0..14 and, at each, (1) clear the sticky BURSTDET-seen bit,
/// (2) run the fast frameSweep (RCS x RDSLACK x a few RDTAPs) against the written
/// pattern, and (3) sample BURSTDET/BDET_SEEN. The read window frames the DATA
/// BURST at the position where BURSTDET asserts AND the pattern reads back (the
/// readback finally TRACKS the written data, no longer the preamble constant).
/// Returns the BEST position: prefer a full 4/4 match with BURSTDET; else the
/// highest matchCount seen (with BURSTDET as a tie-break). Leaves reg11 parked at
/// the winning position. The caller then fine-centres with DYNDELAY/per-bit.
fn framePulse() PulseResult {
    var best: PulseResult = .{
        .pos = RDPULSE_LEGACY,
        .n = 0,
        .bdet = false,
        .fr = .{ .n = 0, .tap = 0, .rcs = 0, .slk = 0 },
    };
    setReadClkSel(0);
    setRdSlack(0);
    setDynDelay(64, 64);
    walkTap(40);
    // For each reg11 read-pulse position: (1) PRUNE by BURSTDET (a data-independent
    // gate oracle) - clear the sticky, read, keep only positions where BURSTDET
    // latches (the read gate saw a valid burst). Then (2) at a BURSTDET position,
    // frame the BEAT/WORD gather with the POPCOUNT-DISTINCT pattern (0x01/03/07/0F,
    // popcounts 1/2/3/4) which is robust to the pre-deskew within-byte per-DQ bit
    // permutation. Score = popFrameScore (how many captured-lane words carry the
    // right popcount in order). Sweep RCS x RDSLACK at each BURSTDET position. The
    // per-DQ within-byte skew is NOT closed here - deskew closes it AFTER framing.
    // Tap fixed at 40 (RCS/RDSLACK don't reset the DELAYF walk), walkTap hoisted.
    // COMPOSITE SCORE that prioritizes BOTH-LANE capture (2026-07-11 fix). The old
    // score maximized popFrameScore = CAPTURED-lane-only popcount, which is high at
    // MANY rdpulse positions INCLUDING the ones where the float lane (lane0) reads
    // 0xFF - so it parked a lane0-float position and land fn0 followed every boot.
    // HW-decisive (gttrack probe): only rdpulse pos1 captures BOTH byte lanes in one
    // window (bothLaneTrack==2). So score each (pos,rcs,slk) by
    //   composite = bothLaneTrack()*8 + popFrameScore()
    // which STRICTLY prefers a both-lane position (track 2) over any captured-lane-
    // only position (track <=1), and among both-lane positions prefers the best
    // popcount frame. best.n keeps the captured-lane popcount (for the accept path).
    var bestScore: u32 = 0;
    var pos: u32 = 0;
    while (pos < RDPULSE_TOP) : (pos += 1) {
        setRdPulse(pos);
        setReadClkSel(0);
        setRdSlack(0);
        clearBdet();
        const bd = bdetSeen();
        var rcs: u32 = 0;
        while (rcs < RCS_TOP) : (rcs += 1) {
            var slk: u32 = 0;
            while (slk < FRAME_SLK_TOP) : (slk += 1) {
                setReadClkSel(rcs);
                setRdSlack(slk);
                const both = bothLaneTrack();
                const nf = popFrameScore();
                if (both > g_maxBoth) {
                    g_maxBoth = both;
                    g_bothPos = pos;
                    g_bothRcs = rcs;
                    g_bothSlk = slk;
                }
                const score: u32 = @as(u32, both) * 8 + nf;
                if (score > bestScore) {
                    bestScore = score;
                    best = .{
                        .pos = pos,
                        .n = nf,
                        .bdet = bd,
                        .fr = .{ .n = nf, .tap = 40, .rcs = rcs, .slk = slk },
                    };
                }
            }
        }
        // Max composite = both(2)*8 + popcount(4) = 20: both lanes tracked AND the
        // captured lane fully popcount-framed. Stop the search there.
        if (bestScore >= 20) break;
    }
    // Park the winning read-pulse position + the framing (rcs,slk,tap) that scored.
    setRdPulse(best.pos);
    setRead(best.fr.tap, best.fr.rcs, best.fr.slk);
    return best;
}

/// Bring up DRAM: find the read eye against the write-leveling-trained write
/// launch. Returns true once dram_base is usable, false if no valid eye was
/// found (caller must not run from DRAM).
// Write-DQS path witnesses on the XILINX ddr3Fast read mux (xilStatus in
// ddr.dart). reg3 STATUS packs [0]IDELAYCTRL-rdy [1]init-done [7:4]FSM-state
// [15:8]write-cmd-count [23:16]DQ-drive-overlap-count. reg4=chWrWord (bus write
// word reaching the PHY), reg5=chDataLine (the launched 8-beat line the write
// gearbox produced), reg6=chDqsClk (DQS launch-clock alive heartbeat, 0=dead).
// Together these localise the dead 400MHz write path: no init-done/idelay-rdy =
// operating point bad; wrcmd climbing but overlap=0 = the pad OE window misses
// the burst; wrword ok but dataline garbage = the gearbox mangles at 400; dqsclk
// 0 = DQS launch clock dead. Runs BEFORE rdReadSetup (which halts) at any CK.
fn wrDqsDiag(con: *uart.Ns16550a) void {
    const b = cfg.dram_base;
    w32(b + 0 * LINE, 0xC0DEC0DE);
    w32(b + 1 * LINE, 0x5A5A5A5A);
    _ = r32(b + 0 * LINE);
    con.writeStr("[fsbl] ddr: xilstat(ovl/cmd/st/id)=");
    hex8(con, r32(cfg.ddr_train_base + STATUS));
    con.writeStr(" wrword=");
    hex8(con, r32(cfg.ddr_train_base + READCLKSEL));
    con.writeStr(" dataline=");
    hex8(con, r32(cfg.ddr_train_base + RDPCTL));
    con.writeStr(" dqsclk=");
    hex8(con, r32(cfg.ddr_train_base + DQS_DBG));
    con.writeStr("\n");
}

// Set ONE DQ bit's read IDELAY tap (reg10: [4:0]tap [5]LD [9:6]lane, lane=bit).
fn setBitIdelay(bit: u32, tap: u32) void {
    w32(cfg.ddr_train_base + RD_IDELAY, (bit << 6) | RD_IDELAY_LD | (tap & 0x1F));
}

// PER-BIT MPR READ LEVELING (LiteDRAM read_leveling style, mpr=true build).
// The DRAM's MPR page-0 pattern drives an ALTERNATING 0/1 per BEAT on every DQ,
// so a correctly-captured word has each DQ bit toggling across its 4 beats (bits
// i, i+8, i+16, i+24). For each DQ bit, sweep its OWN IDELAY tap and find the
// window where its 4 beats alternate cleanly; centre the tap there. This
// calibrates OUT the per-bit routing skew openXC7 leaves uncorrected - the thing
// creek's coarse per-LANE centring can't do at a tight (400MHz) read eye.
const RDLVL_PAT: u32 = 0x00FF00FF; // per-beat alternating (beat0=00,beat1=FF,...)
fn perBitReadLevel(con: *uart.Ns16550a) void {
    // Written-pattern per-bit read leveling (non-mpr build). Write a per-beat
    // ALTERNATING pattern (each DQ bit toggles 0/1 across its 4 beats), then for
    // each DQ bit sweep its OWN IDELAY and find the window where its beats toggle
    // cleanly. First find WHICH read-pipe window the burst lands in.
    var b: u32 = 0;
    while (b < 8) : (b += 1) setBitIdelay(b, 16);
    w32(cfg.dram_base + 0 * 0x20, RDLVL_PAT);
    w32(cfg.dram_base + 1 * 0x20, RDLVL_PAT);
    w32(cfg.dram_base + 2 * 0x20, RDLVL_PAT);
    w32(cfg.dram_base + 3 * 0x20, RDLVL_PAT);
    _ = r32(cfg.dram_base + 0);
    var wsel: u32 = 0;
    var burstWin: u32 = RD_WINDOW_VAL;
    var bestPop: u32 = 0;
    while (wsel < 16) : (wsel += 1) {
        rdSetWindow(wsel);
        var s: usize = 0;
        while (s < 16) : (s += 1) _ = r32(cfg.ddr_train_base + STATUS);
        const v = r32(cfg.dram_base + 0);
        con.writeStr("[fsbl] ddr: rdlvl win=");
        hex8(con, wsel);
        con.writeStr(" v=");
        hex8(con, v);
        con.writeStr("\n");
        // Prefer the window whose read is closest to the alternating pattern.
        const diff = v ^ RDLVL_PAT;
        var pop: u32 = 0;
        var k: u5 = 0;
        while (true) : (k +%= 1) {
            if ((diff >> k) & 1 == 0) pop += 1;
            if (k == 31) break;
        }
        if (pop > bestPop) {
            bestPop = pop;
            burstWin = wsel;
        }
    }
    rdSetWindow(burstWin);
    con.writeStr("[fsbl] ddr: rdlvl burst-win=");
    hex8(con, burstWin);
    con.writeStr("\n");
    var bit: u32 = 0;
    while (bit < 8) : (bit += 1) {
        var lo: i32 = -1;
        var hi: i32 = -1;
        var tap: u32 = 0;
        while (tap < RD_TAP_TOP) : (tap += 1) {
            setBitIdelay(bit, tap);
            var s: usize = 0;
            while (s < 16) : (s += 1) _ = r32(cfg.ddr_train_base + STATUS);
            var ok: bool = true;
            var line: usize = 0;
            while (line < 4) : (line += 1) {
                const w = r32(cfg.dram_base + line * 0x20);
                const b0 = (w >> @intCast(bit)) & 1;
                const b1 = (w >> @intCast(bit + 8)) & 1;
                const b2 = (w >> @intCast(bit + 16)) & 1;
                const b3 = (w >> @intCast(bit + 24)) & 1;
                if (b0 == b1 or b1 == b2 or b2 == b3) ok = false;
            }
            if (ok) {
                if (lo < 0) lo = @intCast(tap);
                hi = @intCast(tap);
            } else if (lo >= 0) {
                break; // window closed
            }
        }
        const centre: u32 = if (lo >= 0) @intCast(@divTrunc(lo + hi, 2)) else 0;
        setBitIdelay(bit, centre);
        con.writeStr("[fsbl] ddr: rdlvl bit=");
        hex8(con, bit);
        con.writeStr(" lo=");
        hex8(con, @bitCast(lo));
        con.writeStr(" hi=");
        hex8(con, @bitCast(hi));
        con.writeStr(" c=");
        hex8(con, centre);
        con.writeStr("\n");
    }
    // After per-bit centring, dump the MPR read: a clean alternating word
    // (0x00FF00FF-family) = the read eye is recovered at this CK.
    con.writeStr("[fsbl] ddr: rdlvl MPR=");
    hex8(con, r32(cfg.dram_base + 0));
    con.writeStr("/");
    hex8(con, r32(cfg.dram_base + 0x20));
    con.writeStr("\n");
}

/// Prove the DRAM array with a short, direct read-after-write test. It covers
/// sequential 32-bit words at the base, 64-bit read-after-write across the low and
/// high addresses (the top of the window is the stack region), and a nested
/// push/pop stack pattern. Return true when every word reads back its written
/// value. The runtime training engine and the UberDDR3 path both use it as the
/// final go/no-go check.
pub fn memtest(con: *uart.Ns16550a) bool {
    const b = cfg.dram_base;
    const S = struct {
        fn w64(a: usize, v: u64) void {
            @as(*volatile u64, @ptrFromInt(a)).* = v;
        }
        fn r64(a: usize) u64 {
            return @as(*volatile u64, @ptrFromInt(a)).*;
        }
    };
    // (1) sequential 32-bit words at the base
    var e1: u32 = 0;
    var i: u32 = 0;
    while (i < 256) : (i += 1) w32(b + i * 4, 0xC0DE0000 | i);
    i = 0;
    while (i < 256) : (i += 1) if (r32(b + i * 4) != (0xC0DE0000 | i)) {
        e1 += 1;
    };
    // (2) 64-bit read-after-write at LOW + HIGH addresses (top of 128MB = stack region)
    var e2: u32 = 0;
    const addrs = [_]usize{ b, b + 0x1000, b + 0x04000000, b + 0x07FF_FF00, b + 0x07FF_FFF8 };
    for (addrs) |a| {
        const v: u64 = 0xDEADBEEF_00000000 | @as(u64, @intCast(a & 0xFFFFFFFF));
        S.w64(a, v);
        if (S.r64(a) != v) e2 += 1; // read immediately after write
    }
    // (3) nested push/pop (stack pattern) near the top of the window
    var e3: u32 = 0;
    var sp: usize = b + 0x07FF_FF00;
    var vals: [16]u64 = undefined;
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        sp -= 8;
        vals[k] = 0xABCD_0000 + k;
        S.w64(sp, vals[k]);
    }
    k = 16;
    while (k > 0) {
        k -= 1;
        if (S.r64(sp) != vals[k]) e3 += 1;
        sp += 8;
    }
    con.writeStr("[fsbl] ddr: memtest seq32=");
    hex8(con, e1);
    con.writeStr(" rw64=");
    hex8(con, e2);
    con.writeStr(" stack=");
    hex8(con, e3);
    con.putc('\n');
    return (e1 + e2 + e3) == 0;
}

pub fn init(con: *uart.Ns16550a) bool {
    // Runtime DDR training path. When genip built the controller with train=runtime
    // it emits a `training` device-tree node, which ddr_train reads at comptime.
    // Drive the knob window, then run the memtest. A build with no training node
    // (train=hw) keeps `desc` null and falls through to the unchanged path below.
    if (ddr_train.desc) |*d| {
        con.writeStr("[fsbl] train: runtime training window present\n");
        if (!ddr_train.trainController(con, d, cfg.dram_base, memtest)) {
            con.writeStr("[fsbl] train: FAILED\n");
            return false;
        }
        con.writeStr("[fsbl] train: complete\n");
        return true;
    }

    if (true) {
        // HACK (UberDDR3 e2e test on creek_hack): the harbor DDR PHY is gone and
        // UberDDR3 self-calibrates. The wb CDC bridge stalls the first DDR access
        // until DONE_CALIBRATE, so just memtest dram_base and return - do NOT poke
        // the (now unmapped) harbor train registers.
        con.writeStr("[fsbl] ddr: UberDDR3 hack - cal + extended memtest\n");
        return memtest(con);
    }
    if (cfg.ddr_train_base == 0) {
        con.writeStr("[fsbl] ddr: hardware-initialised, no read training needed\n");
        return true;
    }

    // DLL-ON path: the DDRDLLA must lock AND the write-leveling FSM must finish
    // and REPLAY its trained write pointer (wlDone) before the write launch is
    // aligned and the read eye is stable. Spin for BOTH. CRITICAL: do NOT write
    // reg7 (WRDLY) anywhere before or during the read sweep - the first reg7
    // write latches fwOwned in the PHY, permanently SUPPRESSING the WL replay and
    // parking the write pointer at an untrained absolute tap (writes then deposit
    // garbage -> every read reads zero, the observed no-eye). The WL-trained
    // write is the ground truth; the read sweep centres the read on top of it.
    {
        var i: usize = 0;
        while (i < POLL_LIMIT) : (i += 1) {
            const st = r32(cfg.ddr_train_base + STATUS);
            const wl = r32(cfg.ddr_train_base + WLRES);
            if ((st & STATUS_DLL_LOCK != 0) and (wl & WLRES_DONE != 0)) break;
        }
        const wl = r32(cfg.ddr_train_base + WLRES);
        con.writeStr("[fsbl] ddr: WL l0=");
        hexNibble(con, @intCast(wl & 0xF));
        con.writeStr(" l1=");
        hexNibble(con, @intCast((wl >> 4) & 0xF));
        con.writeStr(" done=");
        hexNibble(con, @intCast((wl >> 8) & 0x1));
        // WITNESS: the per-tap voted WL feedback bitmap. fbmap==00 => the WL DQ
        // feedback never flipped as the write-DQS delay swept (RTL feedback-path
        // fault); a non-zero map => the WL edge is real (trained tap = highest
        // set bit). Either way the write centering below does NOT depend on WL
        // converging: it sweeps reg8 DYNDELAY + reg7 WRDLY to land the write.
        const fbmap = (wl >> WLRES_FBMAP_SHIFT) & WLRES_FBMAP_MASK;
        con.writeStr(" fbmap=");
        hex8(con, fbmap);
        con.writeStr("\n");
    }

    // Write-DQS path witnesses (before the read-setup halt, so they print at any
    // CK). Localises the dead 400MHz write path: is the launch firing, and what
    // does the write OSERDES drive?
    wrDqsDiag(con);

    // Pin the read-pipe WINDOW + centre the read taps via the (vendorless) train-
    // control MMIO and verify the STREAMING eye BEFORE the copy: the default-first
    // path's paced read passes a window that is marginal for main Weir's streaming
    // fetches. If streaming is clean, DRAM is ready for both the copy and Weir; if
    // not, fall through to the legacy per-lane sweep below.
    // Centre the read-DQS strobe's own IDELAY eye first (dqsGatedRead builds); the
    // gated read window can't frame until the strobe capture is clean 0xAA/0x55.
    dqsCenterEye(con);
    if (rdReadSetup(con)) {
        con.writeStr("[fsbl] ddr: read-setup clean; DRAM ready\n");
        return true;
    }

    // XILINX WRITE-DQS RE-CENTER (reg14 runtime override). At a higher CK the
    // 200MHz-tuned write launch mis-lands the DQS edge so writes never latch (and
    // the read-setup's write+read then fails on the corrupted pattern). Sweep the
    // per-lane write-beat rotation (0..7 = 0.5 CK each) until the read-setup comes
    // clean. Independent of the WL FSM (which can't train without a roughly-right
    // DQS). Leaves the override enabled at the landed beat.
    {
        var wb: u32 = 0;
        while (wb < 8) : (wb += 1) {
            w32(cfg.ddr_train_base + WRBEAT, WRBEAT_EN | (wb << 4) | wb);
            var s: usize = 0;
            while (s < 64) : (s += 1) _ = r32(cfg.ddr_train_base + STATUS);
            con.writeStr("[fsbl] ddr: wr-beat wb=");
            hex8(con, wb);
            con.writeStr("\n");
            if (rdReadSetup(con)) {
                con.writeStr("[fsbl] ddr: WRITE-BEAT LANDED; DRAM ready\n");
                return true;
            }
        }
    }

    // === STEP-1 LANE0 CLASSIFICATION: WRITE-side vs READ-side. ==================
    // Write a KNOWN non-FF pattern, sweep lane0 DYNDELAY (reg8 d0) + read framing,
    // and answer: does lane0 (bytes 0,2 = mask 0x00FF00FF) EVER read non-FF? Anchors
    // the captured lane1 at DYNDELAY 64 (its framed eye) throughout so lane1 stays
    // valid while lane0's strobe delay + read window are swept. NEVER non-FF at any
    // (dyndelay,rdpulse,rcs,slk) => lane0 DQ is not captured (WRITE path or per-lane
    // DQSBUFM read-gate = RTL). Non-FF somewhere => read-training (widen land sweep).
    if (PROBE_LANE0) {
        const b = cfg.dram_base;
        rdpLoad();
        con.writeStr("[fsbl] LANE0 classify: lane0=bytes0,2 (mask 00FF00FF)\n");
        // Global verdicts across the WHOLE sweep.
        var ever_nonff: bool = false; // lane0 ever read a byte != 0xFF for a 5A write
        var ever_track: bool = false; // lane0 5A-vs-A5 bytes ever DIFFER (data lands)
        var best_l0lo: u8 = 0; // the "most 5A-like" lane0 byte0 seen (for report)
        var best_pos: u32 = 0;
        var best_rcs: u32 = 0;
        var best_slk: u32 = 0;
        var best_d0: u32 = 0;
        // Read-framing positions to try. rdpulse: a coarse set spanning the round-trip;
        // rcs 0..3 (8-beat bitslip / read-gate select), slk 0..1 (capture cycle).
        // Read-framing positions to try. rdpulse: a coarse set spanning the
        // round-trip. Per position: fix tap40 ONCE (rcs/slk do not reset the DELAYF
        // walk), sweep rcs 0..3 x lane0 DYNDELAY (step 32), print ONE streaming line
        // so partial output is useful even if the window cuts short.
        const PHASE1 = false; // skip the (already conclusive) classify sweep
        const POSSET = [_]u32{ 0, 2, 4, 5, 6, 8, 10, 12, 14 };
        for (POSSET) |pos| {
            if (!PHASE1) break;
            setRdPulse(pos);
            walkTap(40);
            var pos_nonff: u8 = 0xFF; // lowest lane0 byte0 seen at this pos (0xFF=none)
            var pos_track: bool = false;
            var rcs: u32 = 0;
            while (rcs < 4) : (rcs += 1) {
                setReadClkSel(rcs);
                setRdSlack(0);
                var d0: u32 = 0;
                while (d0 < 256) : (d0 += 32) {
                    setDynDelay(@intCast(d0), 64);
                    w32(b + 0 * LINE, 0x5A5A5A5A);
                    w32(b + 1 * LINE, 0x5A5A5A5A);
                    _ = r32(b + 0 * LINE);
                    const w5 = readVoted(b + 0 * LINE);
                    const l0b0: u8 = @intCast(w5 & 0xFF);
                    const l0b2: u8 = @intCast((w5 >> 16) & 0xFF);
                    w32(b + 0 * LINE, 0xA5A5A5A5);
                    w32(b + 1 * LINE, 0xA5A5A5A5);
                    _ = r32(b + 0 * LINE);
                    const wa = readVoted(b + 0 * LINE);
                    if ((w5 & 0x00FF00FF) != (wa & 0x00FF00FF)) {
                        pos_track = true;
                        ever_track = true;
                    }
                    if (l0b0 != 0xFF and l0b0 < pos_nonff) pos_nonff = l0b0;
                    if (l0b2 != 0xFF and l0b2 < pos_nonff) pos_nonff = l0b2;
                    if (l0b0 != 0xFF or l0b2 != 0xFF) {
                        if (!ever_nonff) {
                            ever_nonff = true;
                            best_l0lo = l0b0;
                            best_pos = pos;
                            best_rcs = rcs;
                            best_slk = 0;
                            best_d0 = d0;
                        }
                    }
                    if ((w5 & 0x00FF00FF) != (wa & 0x00FF00FF)) {
                        best_l0lo = l0b0;
                        best_pos = pos;
                        best_rcs = rcs;
                        best_slk = 0;
                        best_d0 = d0;
                    }
                }
            }
            // Streaming per-position summary: pos, lowest lane0 byte (or -- if all FF),
            // and whether 5A/A5 ever tracked here.
            con.writeStr("[fsbl] L0 pos");
            hexNibble(con, @intCast(pos & 0xF));
            con.writeStr(" lo=");
            if (pos_nonff == 0xFF) con.writeStr("--") else hex8(con, pos_nonff);
            con.writeStr(if (pos_track) " TRK\n" else " ff\n");
        }
        con.writeStr("[fsbl] L0 everNonFF=");
        con.putc(if (ever_nonff) 'Y' else 'N');
        con.writeStr(" everTrack=");
        con.putc(if (ever_track) 'Y' else 'N');
        con.writeStr("\n[fsbl] L0 best pos=");
        hexNibble(con, @intCast(best_pos & 0xF));
        con.writeStr(" rcs=");
        hexNibble(con, @intCast(best_rcs & 0xF));
        con.writeStr(" slk=");
        hexNibble(con, @intCast(best_slk & 0xF));
        con.writeStr(" d0=");
        hex8(con, best_d0);
        con.writeStr(" l0b0=");
        hex8(con, best_l0lo);
        con.writeStr("\n");
        // GROUND-TRUTH both-lane DATA TRACK at the candidate positions p0,p1 (the
        // raw 5A scan showed NO FF there = both lanes captured). At each (pos,rcs)
        // write 5A then A5 and confirm BOTH lane masks (cap 0xFF00FF00 AND float
        // 0x00FF00FF) TRACK the written data (differ 5A vs A5). BOTH = both byte lanes
        // are genuinely captured in ONE read window at this position.
        // === STEP A (HALF-SWAP confirm, 2026-07-11): CODE ANALYSIS says the read
        // half-order is the bug. Write wrWord=(fall<<16)|rise; PHY sets beat0=rise=
        // low16, beat1=fall=high16; read word0 = packWord(aBeat0,aBeat1) =
        // [aBeat0,aBeat1].swizzle() = (aBeat0<<16)|aBeat1 = (rise<<16)|fall = the two
        // 16-bit halves SWAPPED (written C0DE0000 -> read 0000C0DE = never exact). To
        // CONFIRM without the within-byte bit scramble, write halves of DISTINCT
        // popcount: wrWord=0x0F0F0101 (high=0x0F0F pc4, low=0x0101 pc1). If the read
        // word0 HIGH half reads pc1 and LOW half pc4 => halves swapped (bug). Print
        // the cap-lane HIGH-byte popcount (h) and LOW-byte popcount (l) per (rcs,slk).
        // Expected if swapped: h=1 l=4; if correct: h=4 l=1.
        con.writeStr("[fsbl] STEP-A halfswap: write 0x0F0F0101 (hi pc4/lo pc1)\n");
        con.writeStr("  (rcs,slk): hL = cap hi-byte pc, lo-byte pc; raw word0:\n");
        setRdPulse(1);
        walkTap(40);
        setDynDelay(64, 64);
        {
            var rcs: u32 = 0;
            while (rcs < 8) : (rcs += 1) {
                con.writeStr("  r");
                hexNibble(con, @intCast(rcs & 0xF));
                con.putc(' ');
                var slk: u32 = 0;
                while (slk < 4) : (slk += 1) {
                    setReadClkSel(rcs);
                    setRdSlack(slk);
                    const base = b + 0x100 + (rcs * 4 + slk) * 0x40;
                    w32(base + 0, 0x0F0F0101);
                    _ = r32(b + 0x4000); // drain
                    _ = r32(base + 0); // warm-up
                    const w0 = readVoted(base + 0);
                    // cap lane: hi byte = byte3 (bits31:24), lo byte = byte1 (bits15:8)
                    const hpc = popc((w0 >> 24) & 0xFF);
                    const lpc = popc((w0 >> 8) & 0xFF);
                    hexNibble(con, hpc);
                    hexNibble(con, lpc);
                    con.putc(':');
                    hex8(con, w0);
                    con.putc(' ');
                }
                con.putc('\n');
            }
        }
        con.writeStr("[fsbl] LANE0 classify done; halting\n");
        return false;
    }

    // === PROBE: does the newly-wired RDMOVE / DYNDELAY actually MOVE the read
    // capture on silicon? Write the pattern ONCE, then vary ONLY the read-pointer
    // (RDMOVE) and ONLY the DQS-strobe delay (DYNDELAY), reading word0 RAW (no
    // vote) each step. If word0 CHANGES across steps, the knob reaches the DQSBUFM
    // and moves the eye (the wiring works); if it is frozen, the knob is dead.
    if (PROBE) {
        const b = cfg.dram_base;
        rdpLoad();
        // === WRITE-COLLISION CONFIRM (2026-07-10, THE decisive probe). ==========
        // Hypothesis (bringup-debugger): the multi-word readback is a data-INVARIANT
        // preamble constant because writing 4 consecutive words to the SAME 16-byte
        // BL8 line back-to-back COLLIDES in the PHY write-launch pipe at DLL-on
        // 132MHz - the data never reaches the array. A single isolated write is
        // clean. So separating the writes onto their OWN lines (or draining the pipe
        // between them) should make the readback TRACK the written data.
        // Frame at the pos that framed a single write in the earlier probe (5),
        // rcs0/slk0/tap40/dyn64.
        setReadClkSel(0);
        setRdSlack(0);
        setDynDelay(64, 64);
        walkTap(40);
        setRdPulse(5);
        con.writeStr("[fsbl] WRCOLL confirm (cap-lane mask FF00FF00):\n");
        {
            // (A) SINGLE write to b+0, read b+0 (known-clean baseline).
            w32(b + 0x0, 0x5A5A5A5A);
            _ = r32(b + 0x0);
            const sa = r32(b + 0x0);
            w32(b + 0x0, 0xA5A5A5A5);
            _ = r32(b + 0x0);
            const sb = r32(b + 0x0);
            con.writeStr("  1WR   5A=");
            hex8(con, sa);
            con.writeStr(" A5=");
            hex8(con, sb);
            con.writeStr(if ((sa & 0xFF00FF00) != (sb & 0xFF00FF00)) " DIFF(data lands)\n" else " SAME(invariant)\n");
        }
        {
            // (B) SAME-LINE 2 writes (b+0, b+4) then read b+0 = the SUSPECT case.
            w32(b + 0x0, 0x5A5A5A5A);
            w32(b + 0x4, 0x5A5A5A5A);
            _ = r32(b + 0x0);
            const sa = r32(b + 0x0);
            w32(b + 0x0, 0xA5A5A5A5);
            w32(b + 0x4, 0xA5A5A5A5);
            _ = r32(b + 0x0);
            const sb = r32(b + 0x0);
            con.writeStr("  2WRsl 5A=");
            hex8(con, sa);
            con.writeStr(" A5=");
            hex8(con, sb);
            con.writeStr(if ((sa & 0xFF00FF00) != (sb & 0xFF00FF00)) " DIFF(data lands)\n" else " SAME(COLLISION)\n");
        }
        {
            // (C) SEPARATE-LINE 2 writes (b+0, b+LINE) then read b+0 = the FIX.
            w32(b + 0 * LINE, 0x5A5A5A5A);
            w32(b + 1 * LINE, 0x5A5A5A5A);
            _ = r32(b + 0 * LINE);
            const sa = r32(b + 0 * LINE);
            w32(b + 0 * LINE, 0xA5A5A5A5);
            w32(b + 1 * LINE, 0xA5A5A5A5);
            _ = r32(b + 0 * LINE);
            const sb = r32(b + 0 * LINE);
            con.writeStr("  2WRsep 5A=");
            hex8(con, sa);
            con.writeStr(" A5=");
            hex8(con, sb);
            con.writeStr(if ((sa & 0xFF00FF00) != (sb & 0xFF00FF00)) " DIFF(FIX works)\n" else " SAME(still bad)\n");
        }
        {
            // (D) DRAINED same-line writes: read a DIFFERENT line between writes to
            // drain the launch pipe. If this makes it DIFF, spacing is the lever.
            w32(b + 0x0, 0x5A5A5A5A);
            _ = r32(b + 0x1000);
            w32(b + 0x4, 0x5A5A5A5A);
            _ = r32(b + 0x1000);
            _ = r32(b + 0x0);
            const sa = r32(b + 0x0);
            w32(b + 0x0, 0xA5A5A5A5);
            _ = r32(b + 0x1000);
            w32(b + 0x4, 0xA5A5A5A5);
            _ = r32(b + 0x1000);
            _ = r32(b + 0x0);
            const sb = r32(b + 0x0);
            con.writeStr("  2WRdrn 5A=");
            hex8(con, sa);
            con.writeStr(" A5=");
            hex8(con, sb);
            con.writeStr(if ((sa & 0xFF00FF00) != (sb & 0xFF00FF00)) " DIFF(drain works)\n" else " SAME(drain no help)\n");
        }
        {
            // (E) The 4-word SEPARATE-LINE oracle (the new writeReadback): does the
            // full C0DE pattern read back clean on the captured lane now?
            var w: [4]u32 = undefined;
            writeReadback(&w);
            con.writeStr("  4sep w0=");
            hex8(con, w[0]);
            con.writeStr(" w1=");
            hex8(con, w[1]);
            con.writeStr(" w2=");
            hex8(con, w[2]);
            con.writeStr(" w3=");
            hex8(con, w[3]);
            con.putc('\n');
        }
        setRdPulse(RDPULSE_LEGACY);
        // === PIVOTAL PROBE: the READ-PULSE-POSITION burst-framing sweep. =========
        // Write 5A5A5A5A once per pulse position, sweep reg11 RDPULSE 0..14 at a
        // fixed rcs0/slk0/tap40, and print BURSTDET + raw word0 at EACH position.
        // THE QUESTION this answers: does moving the independent read pulse make the
        // readback TRACK the written data (word0 -> 5A5A5A5A / data-dependent) with
        // BURSTDET asserting, instead of the fixed preamble constant? A position
        // where word0 == 5A5A5A5A (or clearly tracks 5A) with BDET=1 = the burst is
        // FRAMED (fix works). If every position reads the same preamble constant
        // with BDET=0, the pulse does not reach the burst (next lever needed).
        con.writeStr("[fsbl] RDPULSE (pos:bdet w0), rcs0 slk0 tap40:\n");
        setReadClkSel(0);
        setRdSlack(0);
        setDynDelay(64, 64);
        walkTap(40);
        {
            var pos: u32 = 0;
            while (pos < RDPULSE_TOP) : (pos += 1) {
                setRdPulse(pos);
                w32(b + 0x0, 0x5A5A5A5A);
                _ = r32(b + 0x0);
                const st = r32(cfg.ddr_train_base + STATUS);
                const q0 = r32(b + 0x0);
                hexNibble(con, @intCast(pos & 0xF));
                con.putc(':');
                con.putc(if ((st & (STATUS_BURSTDET | STATUS_BDET_SEEN)) != 0) 'B' else '-');
                con.putc(' ');
                hex8(con, q0);
                if (q0 == 0x5A5A5A5A) con.writeStr("<=5A");
                con.putc(' ');
            }
        }
        con.writeStr("\n[fsbl] RDPULSE C0DE (pos w0), rcs0 slk0 tap40:\n");
        {
            var pos: u32 = 0;
            while (pos < RDPULSE_TOP) : (pos += 1) {
                setRdPulse(pos);
                w32(b + 0x0, 0xC0DE1234);
                _ = r32(b + 0x0);
                const q0 = r32(b + 0x0);
                hexNibble(con, @intCast(pos & 0xF));
                con.putc(':');
                hex8(con, q0);
                if (q0 == 0xC0DE1234) con.writeStr("<=CD");
                con.putc(' ');
            }
        }
        // CAPTURED-LANE TRACKING discriminator: at each pulse position write 5A then
        // A5, print the captured-lane bytes (mask 0xFF00FF00), and mark TRK where the
        // captured lane reads back the written data for BOTH (proving data-dependence,
        // not a preamble constant). This is EXACTLY what framePulse's lane0TracksData
        // scores - so it shows the framing verdict the FSBL sees per position.
        con.writeStr("\n[fsbl] TRK (pos 5A|A5 cap-lane), rcs0 slk0 tap40 dyn64:\n");
        {
            var pos: u32 = 0;
            while (pos < RDPULSE_TOP) : (pos += 1) {
                setRdPulse(pos);
                w32(b + 0x0, 0x5A5A5A5A);
                w32(b + 0x4, 0x5A5A5A5A);
                _ = r32(b + 0x0);
                const r5 = r32(b + 0x0);
                w32(b + 0x0, 0xA5A5A5A5);
                w32(b + 0x4, 0xA5A5A5A5);
                _ = r32(b + 0x0);
                const ra = r32(b + 0x0);
                const cm: u32 = 0xFF00FF00;
                const f5 = (r5 & cm) == (0x5A5A5A5A & cm);
                const fa = (ra & cm) == (0xA5A5A5A5 & cm);
                hexNibble(con, @intCast(pos & 0xF));
                con.putc(' ');
                hex8(con, r5 & cm);
                con.putc('|');
                hex8(con, ra & cm);
                if (f5 and fa) con.writeStr("<=TRK2") else if (f5 or fa) con.writeStr("<=trk1");
                con.putc(' ');
            }
        }
        con.writeStr("\n");
        setRdPulse(RDPULSE_LEGACY); // restore legacy gate for the rest of the probe
        // WL now trains tap 1 (write centered). The residual: even both lanes
        // captured, 5A5A5A5A reads back BIT-CORRUPTED (not a clean uniform byte).
        // This probe isolates the per-bit DQ timing: sweep RDTAP (the DQ read
        // DELAYF, the fine per-bit read-capture centre) x lane-1 DYNDELAY at a
        // fixed slk=0 (both lanes captured there) rcs=0, writing 5A5A5A5A, and
        // print word0. A uniform 5A input can only read non-uniform if DQ bits are
        // mis-sampled, so the RDTAP/DYNDELAY that yields 5A5A5A5A is the per-bit
        // read centre. Report any CLEAN.
        con.writeStr("[fsbl] 5A-TAP (tap.d1 -> w0), l0dyn=32 slk0 rcs0:\n");
        setReadClkSel(0);
        setRdSlack(0);
        var anyClean = false;
        {
            var tap: u9 = 0;
            while (tap < 128) : (tap += 16) {
                walkTap(@intCast(tap));
                var d1: u32 = 0;
                while (d1 < 256) : (d1 += 32) {
                    setDynDelay(32, @intCast(d1));
                    w32(b + 0x0, 0x5A5A5A5A);
                    _ = r32(b + 0x0);
                    const q0 = r32(b + 0x0);
                    if (q0 == 0x5A5A5A5A) {
                        anyClean = true;
                        hexNibble(con, @intCast(tap >> 4));
                        con.putc('.');
                        hexNibble(con, @intCast(d1 >> 5));
                        con.writeStr(":5ACLEAN ");
                    }
                }
            }
        }
        if (!anyClean) con.writeStr("(no clean 5A at any tap.d1)");
        con.writeStr("\n");
        // Show a representative raw read at tap48/d1=64 for the byte pattern.
        walkTap(48);
        setDynDelay(32, 64);
        w32(b + 0x0, 0x5A5A5A5A);
        _ = r32(b + 0x0);
        con.writeStr("[fsbl] 5A raw t48 d1=64 w0=");
        hex8(con, r32(b + 0x0));
        con.writeStr("\n");
        // BITSLIP de-rotation probe: write the 4-word C0DE line ONCE per combo,
        // sweep RDSLACK anchor x RCS=bitslip, print ALL 4 words every combo.
        // If the gather fix works, some (slk,rcs) reads back C0DE0000 C0DE1111
        // C0DE2222 C0DE3333 clean + in order.
        con.writeStr("[fsbl] SLIP (slk.rcs w0 w1 w2 w3):\n");
        var slk: u32 = 0;
        while (slk < 8) : (slk += 1) {
            var rcs: u32 = 0;
            while (rcs < 8) : (rcs += 1) {
                setReadClkSel(rcs);
                setRdSlack(slk);
                w32(b + 0x0, 0xC0DE0000);
                w32(b + 0x4, 0xC0DE1111);
                w32(b + 0x8, 0xC0DE2222);
                w32(b + 0xC, 0xC0DE3333);
                _ = r32(b + 0x0);
                const r0 = r32(b + 0x0);
                const r1 = r32(b + 0x4);
                const r2 = r32(b + 0x8);
                const r3 = r32(b + 0xC);
                hexNibble(con, @intCast(slk));
                con.putc('.');
                hexNibble(con, @intCast(rcs));
                con.putc(' ');
                hex8(con, r0);
                con.putc(' ');
                hex8(con, r1);
                con.putc(' ');
                hex8(con, r2);
                con.putc(' ');
                hex8(con, r3);
                if ((r0 >> 16) == 0xC0DE and (r1 >> 16) == 0xC0DE and
                    (r2 >> 16) == 0xC0DE and (r3 >> 16) == 0xC0DE and
                    (r0 & 0xFFFF) == 0x0000 and (r1 & 0xFFFF) == 0x1111 and
                    (r2 & 0xFFFF) == 0x2222 and (r3 & 0xFFFF) == 0x3333)
                {
                    con.writeStr(" <=CLEAN");
                }
                con.putc('\n');
            }
        }
        // PER-LANE DYNDELAY probe: the readback is `xxFFxxFF` = LANE 1 (DQ[15:8])
        // floats while LANE 0 captures. Both lanes' DQS strobes need INDEPENDENT
        // centering. Fix lane0 DYNDELAY=64 and a promising (slk=2,rcs=2), write a
        // 5A line, then sweep LANE 1 DYNDELAY 0..255 (step 16) printing word0. If
        // lane1's high bytes stop floating (word0 -> ..5A..5A / all 5A5A5A5A) at
        // some lane1 delay, lane 1 IS landable and just needs its own trim.
        con.writeStr("[fsbl] L1DYN (s2r2, l0=64):\n");
        setReadClkSel(2);
        setRdSlack(2);
        walkTap(40);
        {
            var d1: u32 = 0;
            while (d1 < 256) : (d1 += 16) {
                setDynDelay(64, @intCast(d1));
                w32(b + 0x0, 0x5A5A5A5A);
                _ = r32(b + 0x0);
                const q0 = r32(b + 0x0);
                hexNibble(con, @intCast(d1 >> 4));
                con.putc(':');
                hex8(con, q0);
                con.putc(' ');
            }
        }
        con.writeStr("\n[fsbl] L1DYN r6:\n");
        setReadClkSel(6);
        setRdSlack(2);
        walkTap(40);
        {
            var d1: u32 = 0;
            while (d1 < 256) : (d1 += 16) {
                setDynDelay(64, @intCast(d1));
                w32(b + 0x0, 0x5A5A5A5A);
                _ = r32(b + 0x0);
                const q0 = r32(b + 0x0);
                hexNibble(con, @intCast(d1 >> 4));
                con.putc(':');
                hex8(con, q0);
                con.putc(' ');
            }
        }
        con.writeStr("\n[fsbl] probe done\n");
        return false;
    }

    // DEFAULT-FIRST: read at the PHY's built-in read settings (no train writes).
    {
        var w: [4]u32 = undefined;
        writeReadback(&w);
        const n = matchCount(&w);
        con.writeStr("[fsbl] ddr: dflt n");
        con.putc('0' + n);
        con.putc(' ');
        hex8(con, w[0]);
        con.putc(' ');
        hex8(con, w[1]);
        con.putc(' ');
        hex8(con, w[2]);
        con.putc(' ');
        hex8(con, w[3]);
        con.writeStr("\n");
        if (n == 4) {
            con.writeStr("[fsbl] ddr: default DLL-on eye good; DRAM ready\n");
            return true;
        }
    }

    // === PHASE RL: READ-LEVEL the DQSBUFM read pointer (PIN it per boot). ======
    // ROOT CAUSE of the multi-session boot-to-boot frame wander (HW-proven this
    // session): the DQSBUFM read-FIFO pointer (RDPNTR) powers up on an ARBITRARY
    // DQS-vs-sclk phase each cold boot and nothing pins it, so the captured burst
    // is an unbounded mix of real beats + preamble/float (popcounts of the readback
    // don't even match the written data = not a permutation = not framed). No
    // reg11/rcs/slk/deskew value can recover an unbounded burst. FIX: RDMOVE-vs-
    // BURSTDET read-level - step the read pointer until BURSTDET asserts STABLY
    // (litedram sdram_read_leveling), pinning the pointer to a deterministic phase
    // so beat0 is the same every boot. Uses the reg1-bit2 BDET-clear (RTL added
    // this session) as the per-step oracle. reg11 must be a real pulse position for
    // BURSTDET to fire, so set a nominal one first; framePulse then refines it.
    setReadClkSel(0);
    setRdSlack(0);
    setDynDelay(64, 64);
    walkTap(40);
    setRdPulse(4); // a nominal mid pulse so the gate can see a burst to level on
    const rl = readLevelPointer(8);
    con.writeStr("[fsbl] ddr: RL step=");
    if (rl < 0) con.writeStr("none") else hexNibble(con, @intCast(rl & 0xF));
    con.writeStr("\n");

    // === PHASE R0: BURST-FRAMING via the INDEPENDENT READ-PULSE POSITION. ======
    // With the read pointer PINNED by RL, walk reg11 RDPULSE, PRUNE by BURSTDET,
    // and frame the beat/word gather with the POPCOUNT-DISTINCT pattern (robust to
    // the pre-deskew within-byte per-DQ bit permutation). Park the best (pos,rcs,
    // slk); PHASE A0 then lands the other lane + per-bit deskews, then STRICT
    // accept-or-halt. If nothing frames, reg11 stays at the sentinel and we halt
    // (never boot a metastable eye).
    const pr = framePulse();
    con.writeStr("[fsbl] ddr: R0 pos=");
    hexNibble(con, @intCast(pr.pos & 0xF));
    con.writeStr(" rcs=");
    hexNibble(con, @intCast(pr.fr.rcs & 0xF));
    con.writeStr(" slk=");
    hexNibble(con, @intCast(pr.fr.slk & 0xF));
    // pr.n = captured-lane C0DE-in-order count (0..4): 4 = the burst is framed AND
    // the beat/word gather is correct on the captured lane. The other lane still
    // floats until the DYNDELAY landing below lands it in this SAME window; the
    // per-DQ within-byte skew is closed by the deskew below.
    con.writeStr(" capN");
    con.putc('0' + pr.n);
    con.writeStr(if (pr.bdet) " BDET" else " nobd");
    // Both-lane track at the parked frame (2 = both byte lanes captured here). This
    // is the fix's witness: framePulse now parks the rdpulse position that captures
    // BOTH lanes, so the DYNDELAY landing below can bring lane0 fully onto the eye.
    con.writeStr(" bt");
    con.putc('0' + bothLaneTrack());
    con.writeStr(" mB");
    con.putc('0' + g_maxBoth);
    con.writeStr("@p");
    hexNibble(con, @intCast(g_bothPos & 0xF));
    con.writeStr("r");
    hexNibble(con, @intCast(g_bothRcs & 0xF));
    con.writeStr("s");
    hexNibble(con, @intCast(g_bothSlk & 0xF));
    con.writeStr("\n");

    // === PHASE A0: LAND LANE 1, DESKEW PER-BIT, then STRICT accept-or-halt. =====
    // framePulse has parked the read-pulse position + (rcs,slk) that best frames
    // the C0DE counting line IN ORDER on the CAPTURED lane (bytes 1,3). Two things
    // remain before DRAM is trustworthy:
    //   (1) the OTHER byte lane (bytes 0,2) still floats/mis-samples - land it with
    //       its own reg8 DYNDELAY (the per-lane DQS-strobe delay) so BOTH lanes
    //       capture in the SAME framed window;
    //   (2) the within-byte per-DQ read skew (0x72 read for 0x5A) - close it with
    //       reg10 per-bit DELAYF deskew, driven by the C0DE line bit-error.
    // Then REQUIRE a full in-order C0DE readback (all 4 words, both lanes) AND a
    // walking-DQ readback clean, else HALT (do NOT boot from a metastable eye).
    // The WL-trained write is preserved (reg7 untouched) so the write stays
    // centered; only read-side knobs move.
    {
        // LAND METRIC = bothLaneTrack (0..2), PERMUTATION-ROBUST (2026-07-11 fix).
        // The old land metric was popFrameScoreBoth = a strict per-byte POPCOUNT match
        // on BOTH lanes, which requires the within-byte per-DQ skew to be ALREADY
        // deskewed (bits smear the popcount before deskew). But deskew was gated on
        // that same score >= 1 => a CIRCULAR dependency (land needs deskew, deskew
        // needs land) => land fn0 forever even when both lanes physically capture.
        // bothLaneTrack (5A-vs-A5 differ per lane mask) detects a CAPTURED lane BEFORE
        // deskew, so it lands the float lane's DYNDELAY, THEN deskew closes the skew,
        // THEN the exact-match accept runs. framePulse already parked an rdpulse pos
        // where both lanes can co-capture; here we fine-land the per-lane strobe.
        var best_bt: u8 = 0;
        var best_d0: u8 = 64;
        var best_d1: u8 = 64;
        setDynDelay(64, 64);
        best_bt = bothLaneTrack();

        // Anchor the captured lane at its framed 64 and sweep ONE lane at a time
        // (fine step 8): bring the floating lane onto the SAME window while the
        // captured lane holds. Sweep lane1 first (keep lane0=64), then lane0 (keep
        // lane1 best). bothLaneTrack rises to 2 when BOTH lanes carry data here.
        {
            var d1: u32 = 0;
            while (d1 < 256) : (d1 += 8) {
                setDynDelay(64, @intCast(d1));
                const n = bothLaneTrack();
                if (n > best_bt) {
                    best_bt = n;
                    best_d0 = 64;
                    best_d1 = @intCast(d1);
                    if (n == 2) break;
                }
            }
        }
        if (best_bt < 2) {
            var d0: u32 = 0;
            while (d0 < 256) : (d0 += 8) {
                setDynDelay(@intCast(d0), best_d1);
                const n = bothLaneTrack();
                if (n > best_bt) {
                    best_bt = n;
                    best_d0 = @intCast(d0);
                    if (n == 2) break;
                }
            }
        }
        setDynDelay(best_d0, best_d1);
        con.writeStr("[fsbl] ddr: land bt");
        con.putc('0' + best_bt);
        con.writeStr(" d0=");
        hexNibble(con, @intCast(best_d0 >> 4));
        con.writeStr(" d1=");
        hexNibble(con, @intCast(best_d1 >> 4));
        con.writeStr("\n");

        // --- Per-bit deskew (closes the within-byte 0x72->0x5A skew) once BOTH lanes
        // are captured (best_bt==2). It is the ONLY knob that fixes a within-byte
        // per-DQ skew; the group RDTAP cannot. Returns the EXACT in-order C0DE match
        // count (both lanes) after deskew - this is where exact-match becomes possible.
        var best_n: u8 = 0;
        if (best_bt >= 1) {
            // At the LANDED DYNDELAY (both lanes captured), re-sweep RCS x RDSLACK for
            // an EXACT in-order C0DE readback (both lanes). The composite framePulse
            // picked the rcs on a POPCOUNT frame (permutation-invariant), but the exact
            // BYTE ORDER (the 8-beat gather) may frame exactly at a DIFFERENT rcs. Find
            // it before the slow per-bit deskew (which cannot reorder beats, only shift
            // within-byte DQ timing). Report the best exact count + where it landed.
            var pre: u8 = 0;
            var pre_rcs: u32 = 0;
            var pre_slk: u32 = 0;
            {
                var rcs: u32 = 0;
                while (rcs < RCS_TOP) : (rcs += 1) {
                    var slk: u32 = 0;
                    while (slk < FRAME_SLK_TOP) : (slk += 1) {
                        setReadClkSel(rcs);
                        setRdSlack(slk);
                        const n = cntInOrder();
                        if (n > pre) {
                            pre = n;
                            pre_rcs = rcs;
                            pre_slk = slk;
                            if (n == 4) break;
                        }
                    }
                    if (pre == 4) break;
                }
            }
            setReadClkSel(pre_rcs);
            setRdSlack(pre_slk);
            con.writeStr("[fsbl] ddr: pre bn");
            con.putc('0' + pre);
            con.writeStr(" r");
            hexNibble(con, @intCast(pre_rcs & 0xF));
            con.writeStr(" s");
            hexNibble(con, @intCast(pre_slk & 0xF));
            con.writeStr("\n");
            if (pre == 4) {
                best_n = pre;
            } else {
                best_n = deskewAll(con);
                con.writeStr("[fsbl] ddr: deskew bn");
                con.putc('0' + best_n);
                con.writeStr("\n");
            }
        }

        // --- STRICT acceptance: require a full in-order C0DE readback AND a
        // walking-DQ readback clean (every DQ lane verified), else HALT. This
        // refuses to boot on a metastable/partial eye (the read framing wanders
        // boot-to-boot; a partial capture would wedge main). ---
        if (best_n == 4) {
            // Verify with a walking-1 across the 16 DQ lanes (bit identity): a
            // per-bit skew that the C0DE line happened to miss shows here.
            const b = cfg.dram_base;
            var ok = true;
            var bit: u5 = 0;
            while (bit < 16) : (bit += 1) {
                const half: u32 = @as(u32, 1) << bit;
                const pat: u32 = (half << 16) | half;
                w32(b + 0 * LINE, pat);
                _ = r32(b + 0 * LINE);
                if (readVoted(b + 0 * LINE) != pat) ok = false;
                if (bit == 15) break;
            }
            if (ok) {
                // Do NOT rdpLoad() here: that would RELOAD the read pointer to its
                // reference and UNDO the RDMOVE read-level (PHASE RL) that pinned
                // it to the framed phase. Leave the leveled pointer in place.
                con.writeStr("[fsbl] ddr: framed+deskewed eye; DRAM ready\n");
                if (DDR_STRESS) stressVerify(con);
                return true;
            }
            con.writeStr("[fsbl] ddr: walking-DQ verify FAILED (residual per-bit skew)\n");
        }

        // Restore neutral centering before halting.
        setDeskewBroadcast();
        setDynDelay(0, 0);
        rdpLoad();
    }

    // The DLL-on 132MHz read did not frame a full, verified eye this boot. The read
    // capture point wanders boot-to-boot (nothing pins the DQSBUFM read-FIFO
    // pointer deterministically per boot = an RTL gap), so a fixed firmware sweep
    // cannot guarantee convergence. Halt rather than run main from an unvalidated /
    // partially-framed DRAM (that wedges on the first sustained access). The R0
    // pos/rcs/slk + land/deskew lines above say how close this boot got.
    con.writeStr("[fsbl] ddr: no framed eye this boot; halting\n");
    return false;
}
