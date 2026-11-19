//! Reads a file from an HTTP server in pieces, on a link that can lose bytes.
//! Each piece is one range request, and the standard library reads the head
//! of the reply. A piece that does not arrive whole is asked for again on a
//! new connection.
//!
//! The connection type has `connect(host, port, ms)`, `send(bytes)`,
//! `recv(dest, ms) usize`, `recvSome(dest, ms) usize` and `close()`, as the
//! client in esp_at.zig has.

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
        /// The bytes of the last piece that arrived.
        arrived: usize = 0,
        /// Called for each piece that Weir asks for again.
        report: ?*const fn (offset: u64, arrived: usize, err: anyerror, sample: []const u8) void = null,
        /// The start of a reply whose head was not correct.
        sample: [32]u8 = undefined,
        sample_len: usize = 0,

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
                    if (self.report) |report| report(offset, self.arrived, err, self.sample[0..self.sample_len]);
                }
            }
        }

        fn attempt(self: *Self, offset: u64, dest: []u8) !http.Range {
            self.arrived = 0;
            self.sample_len = 0;
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
                else => {
                    const seen = in.interface.buffered();
                    self.arrived = seen.len;
                    self.sample_len = @min(seen.len, self.sample.len);
                    @memcpy(self.sample[0..self.sample_len], seen[0..self.sample_len]);
                    return err;
                },
            };

            // The body arrives while the head is still in the buffer, and the
            // UART holds only a few bytes. So the body is read first, with no
            // other work, and the head is examined after it.
            const start = in.interface.buffered();
            self.arrived = @min(start.len, dest.len);
            @memcpy(dest[0..self.arrived], start[0..self.arrived]);
            const body: esp_at.Error!void = while (self.arrived < dest.len) {
                self.arrived += self.conn.recv(dest[self.arrived..], reply_ms) catch |err| break err;
            };

            const head = std.http.Client.Response.Head.parse(head_bytes) catch return error.Malformed;
            if (head.status != .partial_content) {
                self.status = @backingInt(head.status);
                return error.BadStatus;
            }
            try body;
            var headers = head.iterateHeaders();
            const range = while (headers.next()) |header| {
                if (!std.ascii.eqlIgnoreCase(header.name, "content-range")) continue;
                break http.contentRange(header.value) orelse return error.Malformed;
            } else return error.Malformed;
            const length = head.content_length orelse return error.Malformed;
            if (range.first != offset or length != dest.len or start.len > dest.len) return error.Malformed;
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
                const count = input.conn.recvSome(dest, reply_ms) catch |err| {
                    input.err = err;
                    return error.ReadFailed;
                };
                writer.advance(count);
                return count;
            }
        };
    };
}
