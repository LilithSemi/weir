//! A line of text that a person types on a serial console.

const std = @import("std");

pub const Line = struct {
    buf: []u8,
    len: usize = 0,

    pub const Step = union(enum) {
        /// The text to send back to the console.
        echo: []const u8,
        done,
    };

    /// Takes one byte from the console.
    pub fn feed(self: *Line, byte: u8) Step {
        switch (byte) {
            '\r', '\n' => return .done,
            0x08, 0x7f => {
                if (self.len == 0) return .{ .echo = "" };
                self.len -= 1;
                return .{ .echo = "\x08 \x08" };
            },
            0x20...0x7e => {
                if (self.len == self.buf.len) return .{ .echo = "" };
                self.buf[self.len] = byte;
                self.len += 1;
                return .{ .echo = self.buf[self.len - 1 ..][0..1] };
            },
            else => return .{ .echo = "" },
        }
    }

    pub fn text(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
};

const testing = std.testing;

test "a line with a correction" {
    var buf: [8]u8 = undefined;
    var line: Line = .{ .buf = &buf };
    for ("htx") |byte| try testing.expectEqualStrings(&.{byte}, line.feed(byte).echo);
    try testing.expectEqualStrings("\x08 \x08", line.feed(0x7f).echo);
    try testing.expectEqualStrings("t", line.feed('t').echo);
    try testing.expectEqualStrings("", line.feed(0x1b).echo);
    try testing.expectEqual(Line.Step.done, line.feed('\r'));
    try testing.expectEqualStrings("htt", line.text());
}

test "a full line and an empty line" {
    var buf: [2]u8 = undefined;
    var line: Line = .{ .buf = &buf };
    try testing.expectEqualStrings("", line.feed(0x08).echo);
    _ = line.feed('a');
    _ = line.feed('b');
    try testing.expectEqualStrings("", line.feed('c').echo);
    try testing.expectEqualStrings("ab", line.text());
}
