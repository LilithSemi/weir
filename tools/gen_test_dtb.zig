//! Build-time generator for the synthetic training-node device tree
//! `ddr_train.zig`'s own unit test embeds. It writes the same four-knob
//! Xilinx-shaped table `parseTrainingNode`'s test already asserts against,
//! using `dtree.Builder` so the fixture needs no external device-tree
//! compiler: the whole blob is produced in Zig, like every other generated
//! file in this build.
//!
//! Usage: gen-test-dtb <out-path>

const std = @import("std");
const dtree = @import("dtree");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // zippy:ignore discarded_error -- the tool ignores the program name arg
    const out_path = args.next() orelse return error.Usage;

    var b = dtree.Builder.init(gpa);
    defer b.deinit();

    try b.beginNode("");
    try b.beginNode("sdram-controller@8ffff000");
    try b.propU32("harbor,ddr-lanes", 2);
    try b.propU32("harbor,ddr-rows", 13);
    try b.propU32("harbor,ddr-cols", 10);
    try b.propU32("harbor,ddr-banks", 8);
    try b.propU32("harbor,ddr-ranks", 1);

    try b.beginNode("training");
    try b.propCells("harbor,train-reg", &.{ 0x8ffff000, 0x1000 });
    try b.propU32("harbor,train-stride", 8);

    try b.beginNode("knob@0");
    try b.propString("harbor,knob", "write-level");
    try b.propU32("harbor,reg", 0x00);
    try b.propString("harbor,scope", "per-lane");
    try b.propString("harbor,feedback", "map");
    try b.endNode();

    try b.beginNode("knob@1");
    try b.propString("harbor,knob", "write-odelay");
    try b.propU32("harbor,reg", 0x08);
    try b.propString("harbor,scope", "per-lane");
    try b.propString("harbor,feedback", "pattern");
    try b.propU32("harbor,min", 0);
    try b.propU32("harbor,max", 0x1f);
    try b.endNode();

    try b.beginNode("knob@2");
    try b.propString("harbor,knob", "read-idelay");
    try b.propU32("harbor,reg", 0x10);
    try b.propString("harbor,scope", "per-lane");
    try b.propString("harbor,feedback", "pattern");
    try b.propU32("harbor,min", 0);
    try b.propU32("harbor,max", 0x1f);
    try b.endNode();

    try b.beginNode("knob@3");
    try b.propString("harbor,knob", "bitslip");
    try b.propU32("harbor,reg", 0x18);
    try b.propString("harbor,scope", "per-lane");
    try b.propString("harbor,feedback", "pattern");
    try b.propU32("harbor,min", 0);
    try b.propU32("harbor,max", 0x7);
    try b.endNode();

    try b.endNode(); // training
    try b.endNode(); // sdram-controller
    try b.endNode(); // root

    const blob = try b.finish();
    defer gpa.free(blob);

    const out = if (std.fs.path.isAbsolute(out_path))
        try std.Io.Dir.createFileAbsolute(io, out_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, blob);
}
