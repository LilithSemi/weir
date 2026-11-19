//! Tests of the AT client and the piece download with a model of the module.

const std = @import("std");
const esp_at = @import("esp_at.zig");
const fetch = @import("fetch.zig");
const http = @import("http.zig");

const testing = std.testing;

/// A model of the module with an HTTP server behind it.
const Modem = struct {
    file: []const u8,
    out: []u8,
    head: usize = 0,
    tail: usize = 0,
    clock: u64 = 0,
    overrun: bool = false,
    connected: bool = false,
    baud: u32 = 115200,
    command: [512]u8 = undefined,
    command_len: usize = 0,
    /// The bytes of a send that did not arrive yet.
    data_left: usize = 0,
    replies: u32 = 0,
    connects: u32 = 0,

    /// The connect commands that fail first, as with no network yet.
    refuse_connects: u32 = 0,
    /// The number of the reply that loses bytes on the UART.
    lose_in_reply: ?u32 = null,
    /// The number of the reply that stops in the middle.
    stall_in_reply: ?u32 = null,
    close_after_reply: bool = false,
    ignore_range: bool = false,

    fn init(file: []const u8) !Modem {
        return .{ .file = file, .out = try testing.allocator.alloc(u8, 2 << 20) };
    }

    fn deinit(self: *Modem) void {
        testing.allocator.free(self.out);
    }

    fn put(self: *Modem, bytes: []const u8) void {
        @memcpy(self.out[self.tail..][0..bytes.len], bytes);
        self.tail += bytes.len;
    }

    fn print(self: *Modem, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(self.out[self.tail..], format, args) catch unreachable;
        self.tail += text.len;
    }

    pub fn now(self: *Modem) u64 {
        self.clock += 1;
        return self.clock;
    }

    pub fn takeOverrun(self: *Modem) bool {
        defer self.overrun = false;
        return self.overrun;
    }

    pub fn setBaud(self: *Modem, baud: u32) bool {
        return self.baud == baud;
    }

    pub fn read(self: *Modem, buf: []u8) usize {
        const count = @min(buf.len, self.tail - self.head, 16);
        @memcpy(buf[0..count], self.out[self.head..][0..count]);
        self.head += count;
        if (self.head == self.tail) {
            self.head = 0;
            self.tail = 0;
        }
        return count;
    }

    pub fn write(self: *Modem, bytes: []const u8) void {
        for (bytes) |byte| {
            self.command[self.command_len] = byte;
            self.command_len += 1;
            if (self.data_left != 0) {
                self.data_left -= 1;
                if (self.data_left == 0) self.request();
            } else if (byte == '\n') {
                self.run(std.mem.trim(u8, self.command[0..self.command_len], "\r\n"));
                self.command_len = 0;
            }
        }
    }

    fn run(self: *Modem, text: []const u8) void {
        if (std.mem.startsWith(u8, text, "AT+UART_CUR=")) {
            const comma = std.mem.indexOfScalar(u8, text, ',').?;
            self.baud = std.fmt.parseInt(u32, text["AT+UART_CUR=".len..comma], 10) catch unreachable;
            self.put("\r\nOK\r\n");
        } else if (std.mem.startsWith(u8, text, "AT+CIPSTART=")) {
            self.connects += 1;
            if (self.refuse_connects != 0) {
                self.refuse_connects -= 1;
                self.put("\r\nERROR\r\n");
            } else if (self.connected) {
                self.put("ALREADY CONNECTED\r\n\r\nERROR\r\n");
            } else {
                self.connected = true;
                // The module prints the state of the network at any moment.
                self.put("WIFI CONNECTED\r\nCONNECT\r\n\r\nOK\r\n");
            }
        } else if (std.mem.startsWith(u8, text, "AT+CIPSEND=")) {
            if (!self.connected) return self.put("link is not valid\r\n\r\nERROR\r\n");
            self.data_left = std.fmt.parseInt(usize, text["AT+CIPSEND=".len..], 10) catch unreachable;
            self.put("\r\nOK\r\n\r\n>");
        } else if (std.mem.eql(u8, text, "AT+CIPCLOSE")) {
            self.put(if (self.connected) "CLOSED\r\n\r\nOK\r\n" else "\r\nERROR\r\n");
            self.connected = false;
        } else {
            self.put("\r\nOK\r\n");
        }
    }

    /// Answers the HTTP request in the command buffer.
    fn request(self: *Modem) void {
        const text = self.command[0..self.command_len];
        self.command_len = 0;
        self.print("\r\nRecv {d} bytes\r\n\r\nSEND OK\r\nWIFI GOT IP\r\n", .{text.len});

        const key = "Range: bytes=";
        const range = text[std.mem.indexOf(u8, text, key).? + key.len ..];
        const dash = std.mem.indexOfScalar(u8, range, '-').?;
        const line_end = std.mem.indexOfScalar(u8, range, '\r').?;
        const first = std.fmt.parseInt(usize, range[0..dash], 10) catch unreachable;
        const last = std.fmt.parseInt(usize, range[dash + 1 .. line_end], 10) catch unreachable;

        var reply: [256]u8 = undefined;
        const head = if (self.ignore_range)
            std.fmt.bufPrint(&reply, "HTTP/1.0 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.file.len}) catch unreachable
        else
            std.fmt.bufPrint(
                &reply,
                "HTTP/1.1 206 Partial Content\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\n\r\n",
                .{ last - first + 1, first, last, self.file.len },
            ) catch unreachable;
        const body = if (self.ignore_range) self.file else self.file[first .. last + 1];

        const start = self.tail;
        self.blocks(head, body);
        if (self.lose_in_reply == self.replies) {
            // Three bytes in the middle of the reply do not arrive.
            const at = start + (self.tail - start) / 2;
            std.mem.copyForwards(u8, self.out[at .. self.tail - 3], self.out[at + 3 .. self.tail]);
            self.tail -= 3;
            self.overrun = true;
        }
        if (self.stall_in_reply == self.replies) self.tail = start + (self.tail - start) / 2;
        if (self.close_after_reply) {
            self.put("CLOSED\r\n");
            self.connected = false;
        }
        self.replies += 1;
    }

    /// Sends the head and the body as the module does, in blocks of 1460 bytes.
    fn blocks(self: *Modem, head: []const u8, body: []const u8) void {
        const block = 1460;
        const total = head.len + body.len;
        var sent: usize = 0;
        while (sent < total) {
            const count = @min(block, total - sent);
            self.print("\r\n+IPD,{d}:", .{count});
            for (sent..sent + count) |i| {
                self.out[self.tail] = if (i < head.len) head[i] else body[i - head.len];
                self.tail += 1;
            }
            sent += count;
        }
    }
};

const Client = esp_at.Client(*Modem);
const url = http.Url.parse("http://192.168.1.111:8000/arty.img").?;
const piece = 64 * 1024;

fn pattern(len: usize) ![]u8 {
    const file = try testing.allocator.alloc(u8, len);
    var random: std.Random.DefaultPrng = .init(len);
    random.random().bytes(file);
    return file;
}

/// Downloads the file of the modem in pieces and compares it.
fn download(modem: *Modem) !u32 {
    var client: Client = .{ .port = modem };
    var fetcher: fetch.Fetcher(Client) = .{ .conn = &client, .url = url };
    const size = try fetcher.size();
    try testing.expectEqual(@as(u64, modem.file.len), size);
    const copy = try testing.allocator.alloc(u8, modem.file.len);
    defer testing.allocator.free(copy);
    var offset: usize = 0;
    while (offset < copy.len) {
        const count = @min(piece, copy.len - offset);
        try fetcher.read(offset, copy[offset..][0..count]);
        offset += count;
    }
    try testing.expectEqualSlices(u8, modem.file, copy);
    return fetcher.retries;
}

test "the commands after a reset" {
    var modem = try Modem.init("");
    defer modem.deinit();
    modem.put("\x00garbage\r\n\r\nready\r\n");
    var client: Client = .{ .port = &modem };
    try client.waitReady(5000);
    try client.setup();
    try client.setBaud(781250);
    try testing.expectEqual(@as(u32, 781250), modem.baud);
    var quiet: Client = .{ .port = &modem };
    try testing.expectError(error.Timeout, quiet.waitReady(100));
}

test "a file comes whole in pieces on one connection" {
    const file = try pattern(200 * 1024 + 77);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    try testing.expectEqual(@as(u32, 0), try download(&modem));
    try testing.expectEqual(@as(u32, 1), modem.connects);
    try testing.expectEqual(@as(u32, 5), modem.replies);
}

test "a piece with lost bytes is read again" {
    const file = try pattern(200 * 1024);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    modem.lose_in_reply = 2;
    try testing.expectEqual(@as(u32, 1), try download(&modem));
    try testing.expectEqual(@as(u32, 2), modem.connects);
}

test "a piece that stops in the middle is read again" {
    const file = try pattern(200 * 1024);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    modem.stall_in_reply = 3;
    try testing.expectEqual(@as(u32, 1), try download(&modem));
}

test "a server that closes the connection after each reply" {
    const file = try pattern(150 * 1024);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    modem.close_after_reply = true;
    _ = try download(&modem);
    try testing.expect(modem.connects >= 4);
}

test "a connect that fails at first" {
    const file = try pattern(1000);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    modem.refuse_connects = 2;
    try testing.expectEqual(@as(u32, 2), try download(&modem));
    modem.connected = false;
    modem.refuse_connects = 100;
    var client: Client = .{ .port = &modem };
    var fetcher: fetch.Fetcher(Client) = .{ .conn = &client, .url = url };
    try testing.expectError(error.Rejected, fetcher.size());
}

test "a server without ranges gives its status" {
    const file = try pattern(1000);
    defer testing.allocator.free(file);
    var modem = try Modem.init(file);
    defer modem.deinit();
    modem.ignore_range = true;
    var client: Client = .{ .port = &modem };
    var fetcher: fetch.Fetcher(Client) = .{ .conn = &client, .url = url };
    try testing.expectError(error.BadStatus, fetcher.size());
    try testing.expectEqual(@as(u16, 200), fetcher.status);
    try testing.expectEqual(@as(u32, 1), modem.replies);
}
