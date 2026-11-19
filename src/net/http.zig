//! The parts of HTTP/1.1 that a download of one file in pieces needs and that
//! the standard library does not give: the URL rules of the netboot, the
//! request for a byte range, and the `Content-Range` header.

const std = @import("std");

pub const Url = struct {
    host: []const u8,
    port: u16,
    /// The path with its query, as the request line has it.
    path: []const u8,

    /// Splits an `http://host[:port]/path` text. Null for other forms.
    pub fn parse(text: []const u8) ?Url {
        const uri = std.Uri.parse(text) catch return null;
        if (!std.mem.eql(u8, uri.scheme, "http")) return null;
        // A name and a password in the URL are not accepted. The URL goes to
        // a variable that is not encrypted.
        if (uri.user != null or uri.password != null) return null;
        const host = textOf(uri.host orelse return null);
        const path = textOf(uri.path);
        if (host.len == 0 or path.len == 0) return null;

        // The text ends with the path, the query and the fragment.
        const fragment_len = if (uri.fragment) |fragment| textOf(fragment).len + 1 else 0;
        const query_len = if (uri.query) |query| textOf(query).len + 1 else 0;
        const end = text.len - fragment_len;
        const start = end - query_len - path.len;
        return .{ .host = host, .port = uri.port orelse 80, .path = text[start..end] };
    }

    fn textOf(component: std.Uri.Component) []const u8 {
        return switch (component) {
            .raw, .percent_encoded => |bytes| bytes,
        };
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

pub const Range = struct {
    /// The first byte of the range in the body.
    first: u64,
    /// The size of the whole file. Null when the server gives `*`.
    total: ?u64,
};

/// Reads the value of a `Content-Range` header, `bytes first-last/total`.
pub fn contentRange(value: []const u8) ?Range {
    const unit = "bytes ";
    if (!std.mem.startsWith(u8, value, unit)) return null;
    const range = value[unit.len..];
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return null;
    const slash = std.mem.indexOfScalar(u8, range, '/') orelse return null;
    return .{
        .first = std.fmt.parseInt(u64, range[0..dash], 10) catch return null,
        .total = std.fmt.parseInt(u64, range[slash + 1 ..], 10) catch null,
    };
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

test "a url with a query and a fragment" {
    const url = Url.parse("http://host/a.img?board=arty#top").?;
    try testing.expectEqualStrings("/a.img?board=arty", url.path);
}

test "a text that is not an http url" {
    try testing.expect(Url.parse("https://host/x") == null);
    try testing.expect(Url.parse("http://host") == null);
    try testing.expect(Url.parse("http://:80/x") == null);
    try testing.expect(Url.parse("http://host:port/x") == null);
    try testing.expect(Url.parse("http://name:word@host/x") == null);
    try testing.expect(Url.parse("http://name@host/x") == null);
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

test "the content range of a reply" {
    const whole = contentRange("bytes 65536-131071/11534336").?;
    try testing.expectEqual(@as(u64, 65536), whole.first);
    try testing.expectEqual(@as(?u64, 11534336), whole.total);
    const star = contentRange("bytes 0-9/*").?;
    try testing.expectEqual(@as(u64, 0), star.first);
    try testing.expectEqual(@as(?u64, null), star.total);
    try testing.expect(contentRange("lines 0-9/20") == null);
    try testing.expect(contentRange("bytes x-9/20") == null);
    try testing.expect(contentRange("bytes 0-9") == null);
}
