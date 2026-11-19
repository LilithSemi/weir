//! The parts of HTTP/1.1 that a download of one file in pieces needs: the
//! request for a byte range, and the status line and headers of the reply.

const std = @import("std");

pub const Url = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    /// Splits an `http://host[:port]/path` text. Null for other forms.
    pub fn parse(text: []const u8) ?Url {
        const scheme = "http://";
        if (!std.mem.startsWith(u8, text, scheme)) return null;
        const rest = text[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const authority = rest[0..slash];
        var url: Url = .{ .host = authority, .port = 80, .path = rest[slash..] };
        if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
            url.host = authority[0..colon];
            url.port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
        }
        // A name and a password in the URL are not accepted. The URL goes to
        // a variable that is not encrypted.
        if (url.host.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;
        return url;
    }
};

/// Writes a GET request for the bytes `first` to `last` of the file, both
/// included. Gives the request text in `buf`.
pub fn rangeRequest(buf: []u8, url: Url, first: u64, last: u64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nRange: bytes={d}-{d}\r\n\r\n",
        .{ url.path, url.host, url.port, first, last },
    );
}

pub const Head = struct {
    status: u16,
    /// The number of body bytes that follow the head.
    content_length: ?u64 = null,
    /// The first byte of the range in the body, from `Content-Range`.
    first: ?u64 = null,
    /// The size of the whole file, from `Content-Range`.
    total: ?u64 = null,
    /// The number of bytes of the head, with its empty line.
    len: usize,
};

pub const HeadError = error{
    /// The empty line at the end of the head did not arrive yet.
    Incomplete,
    Malformed,
};

/// Reads the status line and the headers at the start of `bytes`.
pub fn parseHead(bytes: []const u8) HeadError!Head {
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.Incomplete;
    var lines = std.mem.splitSequence(u8, bytes[0..end], "\r\n");

    const status_line = lines.first();
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.Malformed;
    var words = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = words.next();
    const code = words.next() orelse return error.Malformed;
    var head: Head = .{
        .status = std.fmt.parseInt(u16, code, 10) catch return error.Malformed,
        .len = end + 4,
    };

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            head.content_length = std.fmt.parseInt(u64, value, 10) catch return error.Malformed;
        } else if (std.ascii.eqlIgnoreCase(name, "content-range")) {
            // The form is `bytes first-last/total`. The total can be `*`.
            const unit = "bytes ";
            if (!std.mem.startsWith(u8, value, unit)) return error.Malformed;
            const range = value[unit.len..];
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.Malformed;
            const slash = std.mem.indexOfScalar(u8, range, '/') orelse return error.Malformed;
            head.first = std.fmt.parseInt(u64, range[0..dash], 10) catch return error.Malformed;
            head.total = std.fmt.parseInt(u64, range[slash + 1 ..], 10) catch null;
        }
    }
    return head;
}

const testing = std.testing;

test "a url with and without a port" {
    const plain = Url.parse("http://192.168.1.111/boot/arty.img").?;
    try testing.expectEqualStrings("192.168.1.111", plain.host);
    try testing.expectEqual(@as(u16, 80), plain.port);
    try testing.expectEqualStrings("/boot/arty.img", plain.path);
    const port = Url.parse("http://host:8080/").?;
    try testing.expectEqualStrings("host", port.host);
    try testing.expectEqual(@as(u16, 8080), port.port);
    try testing.expectEqualStrings("/", port.path);
}

test "a text that is not an http url" {
    try testing.expect(Url.parse("https://host/x") == null);
    try testing.expect(Url.parse("http://host") == null);
    try testing.expect(Url.parse("http://:80/x") == null);
    try testing.expect(Url.parse("http://host:port/x") == null);
    try testing.expect(Url.parse("http://name:word@host/x") == null);
}

test "the request for a range" {
    var buf: [128]u8 = undefined;
    const text = try rangeRequest(&buf, Url.parse("http://10.0.0.1:8000/a.img").?, 65536, 131071);
    try testing.expectEqualStrings(
        "GET /a.img HTTP/1.1\r\nHost: 10.0.0.1:8000\r\nRange: bytes=65536-131071\r\n\r\n",
        text,
    );
    var small: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, rangeRequest(&small, Url.parse("http://h/a").?, 0, 1));
}

test "the head of a reply with a range" {
    const reply = "HTTP/1.1 206 Partial Content\r\nServer: nginx\r\n" ++
        "content-length: 65536\r\nContent-Range: bytes 65536-131071/11534336\r\n\r\nbody";
    const head = try parseHead(reply);
    try testing.expectEqual(@as(u16, 206), head.status);
    try testing.expectEqual(@as(?u64, 65536), head.content_length);
    try testing.expectEqual(@as(?u64, 65536), head.first);
    try testing.expectEqual(@as(?u64, 11534336), head.total);
    try testing.expectEqualStrings("body", reply[head.len..]);
}

test "a reply without a range and a total that is not known" {
    const whole = try parseHead("HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 200), whole.status);
    try testing.expectEqual(@as(?u64, null), whole.first);
    const star = try parseHead("HTTP/1.1 206 x\r\nContent-Range: bytes 0-9/*\r\n\r\n");
    try testing.expectEqual(@as(?u64, 0), star.first);
    try testing.expectEqual(@as(?u64, null), star.total);
}

test "a head that is not complete or not correct" {
    try testing.expectError(error.Incomplete, parseHead("HTTP/1.1 200 OK\r\nContent-Le"));
    try testing.expectError(error.Malformed, parseHead("ICY 200 OK\r\n\r\n"));
    try testing.expectError(error.Malformed, parseHead("HTTP/1.1 abc\r\n\r\n"));
    try testing.expectError(error.Malformed, parseHead("HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n"));
    try testing.expectError(error.Malformed, parseHead("HTTP/1.1 200 OK\r\nno colon\r\n\r\n"));
}
