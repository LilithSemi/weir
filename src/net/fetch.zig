//! Reads a file from an HTTP server in pieces, on a link that can lose bytes.
//! Each piece is one range request, and the standard library reads the head
//! of the reply. A piece that does not arrive whole is asked for again on a
//! new connection.
//!
//! The connection type has `connect(host, port, ms)`, `send(bytes)`,
//! `recv(dest, ms) usize` and `close()`, as the client in esp_at.zig has.

const std = @import("std");
const esp_at = @import("esp_at.zig");
const http = @import("http.zig");

const piece_tries = 6;
const connect_ms = 30_000;
const reply_ms = 10_000;

pub fn Fetcher(comptime Conn: type) type {
    return struct {
        conn: *Conn,
        url: http.Url,
        /// True while the connection can take a request.
        open: bool = false,
        /// The pieces that Weir asked for again.
        retries: u32 = 0,
        /// The status of the last reply that was not a range.
        status: u16 = 0,

        const Self = @This();

        /// The size of the file on the server.
        pub fn size(self: *Self) !u64 {
            var one: [1]u8 = undefined;
            const range = try self.piece(0, &one);
            return range.total orelse error.Malformed;
        }

        /// Fills `dest` with the bytes of the file from `offset`.
        pub fn read(self: *Self, offset: u64, dest: []u8) !void {
            _ = try self.piece(offset, dest);
        }

        pub fn drop(self: *Self) void {
            self.conn.close();
            self.open = false;
        }

        fn piece(self: *Self, offset: u64, dest: []u8) !http.Range {
            var tries: u32 = 0;
            while (true) {
                if (self.attempt(offset, dest)) |range| return range else |err| {
                    self.drop();
                    tries += 1;
                    // A server that gives another status gives it each time.
                    if (err == error.BadStatus or tries == piece_tries) return err;
                    self.retries += 1;
                }
            }
        }

        fn attempt(self: *Self, offset: u64, dest: []u8) !http.Range {
            if (!self.open) {
                try self.conn.connect(self.url.host, self.url.port, connect_ms);
                self.open = true;
            }
            var request: [256]u8 = undefined;
            try self.conn.send(try http.rangeRequest(&request, self.url, offset, offset + dest.len - 1));

            var buf: [1024]u8 = undefined;
            var in: Input = .{ .conn = self.conn, .interface = .{
                .vtable = &.{ .stream = Input.stream },
                .buffer = &buf,
                .seek = 0,
                .end = 0,
            } };
            var reply: std.http.Reader = .{
                .in = &in.interface,
                .interface = undefined,
                .state = .ready,
                .max_head_len = buf.len,
            };
            const head_bytes = reply.receiveHead() catch |err| switch (err) {
                error.ReadFailed => return in.err.?,
                else => return error.Malformed,
            };
            const head = std.http.Client.Response.Head.parse(head_bytes) catch return error.Malformed;
            if (head.status != .partial_content) {
                self.status = @backingInt(head.status);
                return error.BadStatus;
            }
            var headers = head.iterateHeaders();
            const range = while (headers.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "content-range")) continue;
                break http.contentRange(header.value) orelse return error.Malformed;
            } else return error.Malformed;
            const length = head.content_length orelse return error.Malformed;
            if (range.first != offset or length != dest.len) return error.Malformed;

            // The start of the body is in the buffer of the head. The other
            // bytes go from the connection to `dest` with no copy between.
            const body = in.interface.buffered();
            if (body.len > dest.len) return error.Malformed;
            @memcpy(dest[0..body.len], body);
            var got = body.len;
            while (got < dest.len) got += try self.conn.recv(dest[got..], reply_ms);
            return range;
        }

        /// The connection as a reader of the standard library.
        const Input = struct {
            conn: *Conn,
            err: ?esp_at.Error = null,
            interface: std.Io.Reader,

            fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const input: *Input = @alignCast(@fieldParentPtr("interface", reader));
                const dest = limit.slice(try writer.writableSliceGreedy(1));
                const count = input.conn.recv(dest, reply_ms) catch |err| {
                    input.err = err;
                    return error.ReadFailed;
                };
                writer.advance(count);
                return count;
            }
        };
    };
}
