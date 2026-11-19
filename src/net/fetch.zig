//! Reads a file from an HTTP server in pieces, on a link that can lose bytes.
//! Each piece is one range request. A piece that does not arrive whole is
//! asked for again on a new connection.
//!
//! The connection type has `connect(host, port, ms)`, `send(bytes)`,
//! `recv(dest, ms) usize` and `close()`, as the client in esp_at.zig has.

const std = @import("std");
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
            const head = try self.piece(0, &one);
            return head.total orelse error.Malformed;
        }

        /// Fills `dest` with the bytes of the file from `offset`.
        pub fn read(self: *Self, offset: u64, dest: []u8) !void {
            _ = try self.piece(offset, dest);
        }

        pub fn drop(self: *Self) void {
            self.conn.close();
            self.open = false;
        }

        fn piece(self: *Self, offset: u64, dest: []u8) !http.Head {
            var tries: u32 = 0;
            while (true) {
                if (self.attempt(offset, dest)) |head| return head else |err| {
                    self.drop();
                    tries += 1;
                    // A server that gives another status gives it each time.
                    if (err == error.BadStatus or tries == piece_tries) return err;
                    self.retries += 1;
                }
            }
        }

        fn attempt(self: *Self, offset: u64, dest: []u8) !http.Head {
            if (!self.open) {
                try self.conn.connect(self.url.host, self.url.port, connect_ms);
                self.open = true;
            }
            var request: [256]u8 = undefined;
            try self.conn.send(try http.rangeRequest(&request, self.url, offset, offset + dest.len - 1));

            var buf: [1024]u8 = undefined;
            var len: usize = 0;
            const head = while (true) {
                if (len == buf.len) return error.Malformed;
                len += try self.conn.recv(buf[len..], reply_ms);
                break http.parseHead(buf[0..len]) catch |err| switch (err) {
                    error.Incomplete => continue,
                    error.Malformed => return err,
                };
            };
            if (head.status != 206) {
                self.status = head.status;
                return error.BadStatus;
            }
            const first = head.first orelse return error.Malformed;
            const length = head.content_length orelse return error.Malformed;
            if (first != offset or length != dest.len) return error.Malformed;

            const body = buf[head.len..len];
            if (body.len > dest.len) return error.Malformed;
            @memcpy(dest[0..body.len], body);
            var got = body.len;
            while (got < dest.len) got += try self.conn.recv(dest[got..], reply_ms);
            return head;
        }
    };
}
