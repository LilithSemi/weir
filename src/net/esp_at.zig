//! A client for the AT command firmware of an ESP32, on a UART without flow
//! control. It holds one TCP connection, in the mode where the module sends
//! each block of data as `+IPD,<length>:<data>`.
//!
//! The port type has `write(bytes)`, `read(buf) usize` that does not wait,
//! `takeOverrun() bool`, `now() u64` in milliseconds and `setBaud(baud) bool`.

const std = @import("std");

pub const Error = error{
    Timeout,
    /// The module refused the command.
    Rejected,
    /// The other end closed the connection.
    Closed,
    /// The UART lost bytes. The position in the data is not known after this.
    Overrun,
};

const polls_per_clock_read = 64;
const command_ms = 2000;
const send_ms = 10_000;
const quiet_ms = 300;
const flush_limit_ms = 5000;

pub fn Client(comptime Port: type) type {
    return struct {
        port: Port,
        /// The bytes of the current data block that the caller did not read.
        pending: usize = 0,
        line: [96]u8 = undefined,
        line_len: usize = 0,

        const Self = @This();

        /// Waits for the line that the module prints after a reset.
        pub fn waitReady(self: *Self, ms: u32) Error!void {
            _ = try self.waitFor(&.{"ready"}, ms);
        }

        /// Turns off the command echo and selects the mode with one connection.
        pub fn setup(self: *Self) Error!void {
            try self.command("ATE0");
            try self.command("AT+CIPMUX=0");
        }

        /// Changes the baud rate of the module and of the port. The module
        /// goes back to its stored rate at the next reset.
        pub fn setBaud(self: *Self, baud: u32) Error!void {
            var buf: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "AT+UART_CUR={d},8,1,0,0", .{baud}) catch unreachable;
            try self.command(text);
            if (!self.port.setBaud(baud)) return error.Rejected;
            self.flush();
            try self.command("AT");
        }

        pub fn connect(self: *Self, host: []const u8, tcp_port: u16, ms: u32) Error!void {
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "AT+CIPSTART=\"TCP\",\"{s}\",{d}\r\n", .{ host, tcp_port }) catch
                return error.Rejected;
            self.pending = 0;
            self.port.write(text);
            if (try self.waitFor(&.{ "OK", "ERROR", "FAIL" }, ms) != 0) return error.Rejected;
        }

        pub fn send(self: *Self, bytes: []const u8) Error!void {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "AT+CIPSEND={d}\r\n", .{bytes.len}) catch unreachable;
            self.port.write(text);
            if (try self.waitFor(&.{ ">", "ERROR", "CLOSED" }, command_ms) != 0) return error.Rejected;
            self.port.write(bytes);
            if (try self.waitFor(&.{ "SEND OK", "SEND FAIL", "ERROR", "CLOSED" }, send_ms) != 0) return error.Rejected;
        }

        /// Reads data from the connection into `dest`, to the end of `dest` or
        /// of the current block. It gives the number of bytes, 1 or more. It
        /// waits `ms` milliseconds for each byte.
        pub fn recv(self: *Self, dest: []u8, ms: u32) Error!usize {
            return self.fill(dest, ms, .whole);
        }

        /// Reads the data that is in the UART now, and waits only for the
        /// first byte. The caller can work between two short reads, while
        /// the UART holds the bytes that arrive.
        pub fn recvSome(self: *Self, dest: []u8, ms: u32) Error!usize {
            return self.fill(dest, ms, .some);
        }

        fn fill(self: *Self, dest: []u8, ms: u32, amount: enum { whole, some }) Error!usize {
            if (self.pending == 0) try self.blockHeader(ms);
            const want = @min(dest.len, self.pending);
            var got: usize = 0;
            var idle: u32 = 0;
            var end: u64 = 0;
            // A clock read is slow, so the loop reads the clock only when the
            // UART is empty.
            while (got < want) {
                const count = self.port.read(dest[got..want]);
                if (count != 0) {
                    got += count;
                    idle = 0;
                    continue;
                }
                if (got != 0 and amount == .some) break;
                idle += 1;
                if (idle % polls_per_clock_read != 0) continue;
                const time = self.port.now();
                if (idle == polls_per_clock_read) {
                    end = time + ms;
                } else if (time >= end) {
                    return if (self.port.takeOverrun()) error.Overrun else error.Timeout;
                }
            }
            if (self.port.takeOverrun()) return error.Overrun;
            self.pending -= got;
            return got;
        }

        /// Closes the connection. Data that is on its way is lost.
        pub fn close(self: *Self) void {
            self.flush();
            self.port.write("AT+CIPCLOSE\r\n");
            _ = self.waitFor(&.{ "OK", "ERROR" }, command_ms) catch {};
            self.flush();
        }

        fn command(self: *Self, text: []const u8) Error!void {
            self.port.write(text);
            self.port.write("\r\n");
            if (try self.waitFor(&.{ "OK", "ERROR", "FAIL" }, command_ms) != 0) return error.Rejected;
        }

        /// Reads lines until one is equal to an entry of `wanted`, and gives
        /// the index of that entry. The entry `>` is the prompt for data,
        /// which has no line end.
        fn waitFor(self: *Self, wanted: []const []const u8, ms: u32) Error!usize {
            const end = self.port.now() + ms;
            self.line_len = 0;
            while (true) {
                const byte = try self.readByte(end);
                if (byte == '\n') {
                    const text = std.mem.trim(u8, self.line[0..self.line_len], "\r ");
                    for (wanted, 0..) |entry, i| {
                        if (std.mem.eql(u8, text, entry)) return i;
                    }
                    self.line_len = 0;
                    continue;
                }
                self.append(byte);
                if (byte == '>' and self.line_len == 1) {
                    for (wanted, 0..) |entry, i| {
                        if (std.mem.eql(u8, entry, ">")) return i;
                    }
                }
            }
        }

        /// Reads up to the `:` of the next `+IPD` header.
        fn blockHeader(self: *Self, ms: u32) Error!void {
            const end = self.port.now() + ms;
            self.line_len = 0;
            while (true) {
                const byte = try self.readByte(end);
                const text = self.line[0..self.line_len];
                if (byte == '\n') {
                    if (std.mem.eql(u8, std.mem.trim(u8, text, "\r "), "CLOSED")) return error.Closed;
                    self.line_len = 0;
                } else if (byte == ':' and std.mem.startsWith(u8, text, "+IPD,")) {
                    // With more than one connection the header has the link
                    // number first. The length is the last number.
                    const comma = std.mem.lastIndexOfScalar(u8, text, ',').?;
                    self.line_len = 0;
                    self.pending = std.fmt.parseInt(usize, text[comma + 1 ..], 10) catch continue;
                    if (self.pending != 0) return;
                } else {
                    self.append(byte);
                }
            }
        }

        fn append(self: *Self, byte: u8) void {
            if (self.line_len == self.line.len) return;
            self.line[self.line_len] = byte;
            self.line_len += 1;
        }

        fn readByte(self: *Self, end: u64) Error!u8 {
            var one: [1]u8 = undefined;
            var idle: u32 = 0;
            while (self.port.read(&one) == 0) {
                idle += 1;
                if (idle % polls_per_clock_read != 0) continue;
                if (self.port.now() >= end) return error.Timeout;
            }
            if (self.port.takeOverrun()) return error.Overrun;
            return one[0];
        }

        /// Drops the input until the line is quiet.
        fn flush(self: *Self) void {
            var scratch: [64]u8 = undefined;
            const start = self.port.now();
            var last = start;
            while (true) {
                const time = self.port.now();
                if (self.port.read(&scratch) != 0) {
                    last = time;
                } else if (time - last >= quiet_ms) {
                    break;
                }
                if (time - start >= flush_limit_ms) break;
            }
            _ = self.port.takeOverrun();
            self.pending = 0;
            self.line_len = 0;
        }
    };
}
