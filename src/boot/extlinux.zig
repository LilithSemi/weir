//! Parser for extlinux.conf, the boot menu format of syslinux and U-Boot.
//!
//! Only the keys a direct kernel boot needs are read. The result points into
//! the input text or into a caller buffer, so the parser does not allocate.

const std = @import("std");

pub const max_file = 16 * 1024;
pub const max_line = 1024;
/// An `append` value is shorter than its line, so `max_line` also limits it.
pub const max_append = max_line;
pub const max_path = 256;

pub const Error = error{
    FileTooLarge,
    LineTooLong,
    PathTooLong,
    BadPath,
    MissingValue,
    NoLabel,
    NoKernel,
};

/// Buffers for the converted paths of an entry.
pub const Paths = struct {
    kernel: [max_path]u8 = undefined,
    initrd: [max_path]u8 = undefined,
};

pub const Entry = struct {
    label: []const u8,
    /// FAT path with `\` separators and a leading `\`.
    kernel: []const u8,
    initrd: ?[]const u8 = null,
    append: ?[]const u8 = null,
    /// The entry names more than one initrd. Only the first is used.
    extra_initrds: bool = false,
    /// The entry has `fdt`, `fdtdir`, `devicetree` or `fdtoverlays`.
    fdt: bool = false,
    /// The file has an `include` line, which is not supported.
    include: bool = false,
};

/// Parse `text`, the contents of the file at `config_path` (a FAT path such as
/// `\extlinux\extlinux.conf`), and return the entry that `default` selects, or
/// the first label.
pub fn parse(text: []const u8, config_path: []const u8, paths: *Paths) Error!Entry {
    if (text.len > max_file) return error.FileTooLarge;

    var default: ?[]const u8 = null;
    var first: ?[]const u8 = null;
    var include = false;
    var lines: Lines = .init(text);
    while (try lines.next()) |l| {
        if (is(l.key, "default")) {
            default = l.value;
        } else if (is(l.key, "label")) {
            if (l.value.len == 0) return error.MissingValue;
            if (first == null) first = l.value;
        } else if (is(l.key, "include")) {
            include = true;
        }
    }
    var chosen = first orelse return error.NoLabel;
    if (default) |name| {
        if (try hasLabel(text, name)) chosen = name;
    }

    var entry: Entry = .{ .label = chosen, .kernel = "", .include = include };
    var kernel: ?[]const u8 = null;
    var initrd: ?[]const u8 = null;
    var in_block = false;
    lines = .init(text);
    while (try lines.next()) |l| {
        if (is(l.key, "label")) {
            if (in_block) break;
            in_block = std.mem.eql(u8, l.value, chosen);
        } else if (!in_block) {
            continue;
        } else if (is(l.key, "kernel") or is(l.key, "linux")) {
            if (l.value.len == 0) return error.MissingValue;
            kernel = l.value;
        } else if (is(l.key, "initrd")) {
            if (l.value.len == 0) return error.MissingValue;
            if (initrd != null) {
                entry.extra_initrds = true;
                continue;
            }
            var parts = std.mem.splitScalar(u8, l.value, ',');
            const first_initrd = std.mem.trim(u8, parts.first(), blank);
            if (first_initrd.len == 0) return error.MissingValue;
            initrd = first_initrd;
            if (parts.rest().len != 0) entry.extra_initrds = true;
        } else if (is(l.key, "append")) {
            if (l.value.len != 0) entry.append = l.value;
        } else if (is(l.key, "fdt") or is(l.key, "fdtdir") or
            is(l.key, "devicetree") or is(l.key, "fdtoverlays"))
        {
            entry.fdt = true;
        }
    }

    entry.kernel = try fatPath(kernel orelse return error.NoKernel, config_path, &paths.kernel);
    if (initrd) |p| entry.initrd = try fatPath(p, config_path, &paths.initrd);
    return entry;
}

const blank = " \t";

const Line = struct { key: []const u8, value: []const u8 };

/// The non-blank lines of a file that are not comments, each split into a
/// keyword and its value.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    fn init(text: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(self: *Lines) Error!?Line {
        while (self.it.next()) |raw| {
            const unix = std.mem.trimEnd(u8, raw, "\r");
            if (unix.len > max_line) return error.LineTooLong;
            const line = std.mem.trim(u8, unix, blank);
            if (line.len == 0 or line[0] == '#') continue;
            const end = std.mem.findAny(u8, line, blank) orelse line.len;
            return .{ .key = line[0..end], .value = std.mem.trimStart(u8, line[end..], blank) };
        }
        return null;
    }
};

fn is(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

fn hasLabel(text: []const u8, name: []const u8) Error!bool {
    var lines: Lines = .init(text);
    while (try lines.next()) |l| {
        if (is(l.key, "label") and std.mem.eql(u8, l.value, name)) return true;
    }
    return false;
}

/// Convert an extlinux path to a FAT path in `out`. A relative path starts at
/// the directory of `config_path`. A `..` that goes above the root is an error.
fn fatPath(path: []const u8, config_path: []const u8, out: []u8) Error![]const u8 {
    var n: usize = 0;
    if (path[0] != '/') {
        const dir_end = std.mem.findLastAny(u8, config_path, "\\/") orelse 0;
        n = try addComponents(config_path[0..dir_end], out, n);
    }
    n = try addComponents(path, out, n);
    if (n == 0) return error.BadPath;
    return out[0..n];
}

fn addComponents(path: []const u8, out: []u8, start: usize) Error!usize {
    var n = start;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (n == 0) return error.BadPath;
            n = std.mem.findLastAny(u8, out[0..n], "\\").?;
            continue;
        }
        if (n + 1 + c.len > out.len) return error.PathTooLong;
        out[n] = '\\';
        @memcpy(out[n + 1 ..][0..c.len], c);
        n += 1 + c.len;
    }
    return n;
}

const testing = std.testing;
const conf = "\\extlinux\\extlinux.conf";

fn fill(comptime n: usize, comptime c: u8) [n]u8 {
    return @splat(c);
}

fn expectEntry(text: []const u8) !Entry {
    var paths: Paths = .{};
    const e = try parse(text, conf, &paths);
    // The paths point into `paths`, so copy them out for the caller.
    return .{
        .label = e.label,
        .kernel = try testing.allocator.dupe(u8, e.kernel),
        .initrd = if (e.initrd) |p| try testing.allocator.dupe(u8, p) else null,
        .append = e.append,
        .extra_initrds = e.extra_initrds,
        .fdt = e.fdt,
        .include = e.include,
    };
}

fn freeEntry(e: Entry) void {
    testing.allocator.free(e.kernel);
    if (e.initrd) |p| testing.allocator.free(p);
}

test "a NixOS file selects the default label" {
    const text =
        \\# Generated file, all changes will be lost on nixos-rebuild!
        \\
        \\# Change this to e.g. nixos-42 to temporarily boot to an older configuration.
        \\DEFAULT nixos-default
        \\
        \\MENU TITLE ------------------------------------------------------------
        \\TIMEOUT 50
        \\
        \\LABEL nixos-default
        \\  MENU LABEL NixOS - Default
        \\  LINUX ../nixos/abc-linux-6.18.62-Image
        \\  INITRD ../nixos/def-initrd-linux-6.18.62-initrd
        \\  APPEND init=/nix/store/xyz-nixos-system/init console=ttyS0 loglevel=4
        \\  FDTDIR ../nixos/abc-linux-6.18.62-dtbs
        \\
        \\LABEL nixos-41
        \\  MENU LABEL NixOS - Configuration 41
        \\  LINUX ../nixos/old-Image
        \\
    ;
    const e = try expectEntry(text);
    defer freeEntry(e);
    try testing.expectEqualStrings("nixos-default", e.label);
    try testing.expectEqualStrings("\\nixos\\abc-linux-6.18.62-Image", e.kernel);
    try testing.expectEqualStrings("\\nixos\\def-initrd-linux-6.18.62-initrd", e.initrd.?);
    try testing.expectEqualStrings("init=/nix/store/xyz-nixos-system/init console=ttyS0 loglevel=4", e.append.?);
    try testing.expect(e.fdt);
    try testing.expect(!e.extra_initrds);
    try testing.expect(!e.include);
}

test "a Debian file with menu keys selects the default label" {
    const text =
        \\## /boot/extlinux/extlinux.conf
        \\default l0
        \\menu title U-Boot menu
        \\prompt 0
        \\timeout 50
        \\
        \\label l0
        \\    menu label Debian GNU/Linux trixie 6.12.0-riscv64
        \\    linux /boot/vmlinuz-6.12.0-riscv64
        \\    initrd /boot/initrd.img-6.12.0-riscv64
        \\    fdtdir /usr/lib/linux-image-6.12.0-riscv64/
        \\    append root=UUID=1234-abcd ro quiet
        \\
        \\label l0r
        \\    menu label Debian GNU/Linux trixie 6.12.0-riscv64 (rescue target)
        \\    linux /boot/vmlinuz-6.12.0-riscv64
        \\    initrd /boot/initrd.img-6.12.0-riscv64
        \\    append root=UUID=1234-abcd ro single
        \\
    ;
    const e = try expectEntry(text);
    defer freeEntry(e);
    try testing.expectEqualStrings("l0", e.label);
    try testing.expectEqualStrings("\\boot\\vmlinuz-6.12.0-riscv64", e.kernel);
    try testing.expectEqualStrings("\\boot\\initrd.img-6.12.0-riscv64", e.initrd.?);
    try testing.expectEqualStrings("root=UUID=1234-abcd ro quiet", e.append.?);
    try testing.expect(e.fdt);
}

test "default selects the second label" {
    const text =
        \\default two
        \\label one
        \\kernel /one
        \\label two
        \\kernel /two
        \\append b=2
    ;
    const e = try expectEntry(text);
    defer freeEntry(e);
    try testing.expectEqualStrings("two", e.label);
    try testing.expectEqualStrings("\\two", e.kernel);
    try testing.expectEqualStrings("b=2", e.append.?);
}

test "default after the labels still selects" {
    const e = try expectEntry("label one\nkernel /one\nlabel two\nkernel /two\ndefault two\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("two", e.label);
}

test "no default selects the first label" {
    const e = try expectEntry("label one\nkernel /one\nlabel two\nkernel /two\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("one", e.label);
    try testing.expectEqualStrings("\\one", e.kernel);
    try testing.expect(e.initrd == null);
    try testing.expect(e.append == null);
    try testing.expect(!e.fdt);
}

test "a default that names no label selects the first label" {
    const e = try expectEntry("default three\nlabel one\nkernel /one\nlabel two\nkernel /two\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("one", e.label);
}

test "comments, blank lines and leading white space are ignored" {
    const text =
        \\
        \\   # a comment
        \\#label hidden
        \\#kernel /hidden
        \\
        \\   label   a
        \\
        \\      # kernel /wrong
        \\      kernel   /right
        \\
    ;
    const e = try expectEntry(text);
    defer freeEntry(e);
    try testing.expectEqualStrings("a", e.label);
    try testing.expectEqualStrings("\\right", e.kernel);
}

test "tabs separate keywords from values" {
    const e = try expectEntry("label\ta\n\tkernel\t\t/k\n\tappend\tx=1\ty=2\t\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("a", e.label);
    try testing.expectEqualStrings("\\k", e.kernel);
    try testing.expectEqualStrings("x=1\ty=2", e.append.?);
}

test "CR LF line ends work" {
    const e = try expectEntry("default b\r\nlabel a\r\nkernel /a\r\nlabel b\r\nkernel /b\r\ninitrd /i\r\nappend q=1\r\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("b", e.label);
    try testing.expectEqualStrings("\\b", e.kernel);
    try testing.expectEqualStrings("\\i", e.initrd.?);
    try testing.expectEqualStrings("q=1", e.append.?);
}

test "upper case keywords work" {
    const e = try expectEntry("DEFAULT x\nLABEL x\nKERNEL /k\nINITRD /i\nAPPEND A=B\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("x", e.label);
    try testing.expectEqualStrings("\\k", e.kernel);
    try testing.expectEqualStrings("\\i", e.initrd.?);
    try testing.expectEqualStrings("A=B", e.append.?);
}

test "linux works in place of kernel" {
    const e = try expectEntry("label a\nlinux /vmlinuz\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("\\vmlinuz", e.kernel);
}

test "a chosen label with no kernel is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.NoKernel, parse("default b\nlabel a\nkernel /a\nlabel b\nappend x\n", conf, &paths));
}

test "a kernel key with no value is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.MissingValue, parse("label a\nkernel\n", conf, &paths));
}

test "two initrds on one line use the first" {
    const e = try expectEntry("label a\nkernel /k\ninitrd /one,/two\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("\\one", e.initrd.?);
    try testing.expect(e.extra_initrds);
}

test "two initrd lines use the first" {
    const e = try expectEntry("label a\nkernel /k\ninitrd /one\ninitrd /two\n");
    defer freeEntry(e);
    try testing.expectEqualStrings("\\one", e.initrd.?);
    try testing.expect(e.extra_initrds);
}

test "fdt keys are recorded" {
    inline for (.{ "fdt /a.dtb", "FDTDIR /dtbs", "devicetree /a.dtb", "fdtoverlays /o.dtbo" }) |line| {
        const e = try expectEntry("label a\nkernel /k\n" ++ line ++ "\n");
        defer freeEntry(e);
        try testing.expect(e.fdt);
    }
}

test "fdt keys of another label are not recorded" {
    const e = try expectEntry("label a\nkernel /k\nlabel b\nkernel /k\nfdt /b.dtb\n");
    defer freeEntry(e);
    try testing.expect(!e.fdt);
}

test "an include line is recorded" {
    const e = try expectEntry("include other.conf\nlabel a\nkernel /k\n");
    defer freeEntry(e);
    try testing.expect(e.include);
    try testing.expectEqualStrings("\\k", e.kernel);
}

test "ignored keys do not change the entry" {
    const text =
        \\ui menu.c32
        \\say hello
        \\ontimeout b
        \\totaltimeout 9
        \\implicit 1
        \\something unknown
        \\label a
        \\menu label A
        \\kernel /k
        \\label b
        \\kernel /b
    ;
    const e = try expectEntry(text);
    defer freeEntry(e);
    try testing.expectEqualStrings("a", e.label);
    try testing.expectEqualStrings("\\k", e.kernel);
}

test "a path with .. above the root is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.BadPath, parse("label a\nkernel /..\n", conf, &paths));
    try testing.expectError(error.BadPath, parse("label a\nkernel /boot/../../k\n", conf, &paths));
    try testing.expectError(error.BadPath, parse("label a\nkernel /k\ninitrd ../../i\n", conf, &paths));
}

test "a path with .. inside the file system goes up one directory" {
    var paths: Paths = .{};
    const e = try parse("label a\nkernel /boot/x/../k\ninitrd ../i\n", conf, &paths);
    try testing.expectEqualStrings("\\boot\\k", e.kernel);
    try testing.expectEqualStrings("\\i", e.initrd.?);
}

test "a relative path starts at the directory of the file" {
    var paths: Paths = .{};
    const e = try parse("label a\nkernel Image\ninitrd ./sub/initrd\n", "\\boot\\extlinux\\extlinux.conf", &paths);
    try testing.expectEqualStrings("\\boot\\extlinux\\Image", e.kernel);
    try testing.expectEqualStrings("\\boot\\extlinux\\sub\\initrd", e.initrd.?);
}

test "an absolute path starts at the root" {
    var paths: Paths = .{};
    const e = try parse("label a\nkernel /boot//Image\n", "\\boot\\extlinux\\extlinux.conf", &paths);
    try testing.expectEqualStrings("\\boot\\Image", e.kernel);
}

test "a path with no file name is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.BadPath, parse("label a\nkernel /\n", conf, &paths));
}

test "a path longer than the buffer is an error" {
    var paths: Paths = .{};
    const long = "label a\nkernel /" ++ fill(max_path, 'k') ++ "\n";
    try testing.expectError(error.PathTooLong, parse(long, conf, &paths));
    const fits = "label a\nkernel /" ++ fill(max_path - 1, 'k') ++ "\n";
    const e = try parse(fits, conf, &paths);
    try testing.expectEqual(max_path, e.kernel.len);
}

test "a file larger than the limit is an error" {
    var paths: Paths = .{};
    const head = "label a\nkernel /k\n";
    const big = head ++ fill(max_file - head.len + 1, '\n');
    try testing.expectError(error.FileTooLarge, parse(big, conf, &paths));
    const e = try parse(big[0..max_file], conf, &paths);
    try testing.expectEqualStrings("\\k", e.kernel);
}

test "a line longer than the limit is an error" {
    var paths: Paths = .{};
    const head = "label a\nkernel /k\nappend ";
    const too_long = head ++ fill(max_line - "append ".len + 1, 'x') ++ "\n";
    try testing.expectError(error.LineTooLong, parse(too_long, conf, &paths));
    // A comment line has the same limit.
    try testing.expectError(error.LineTooLong, parse(fill(max_line + 1, '#') ++ "\nlabel a\nkernel /k\n", conf, &paths));
}

test "an append of the longest line is kept in full" {
    var paths: Paths = .{};
    const value = fill(max_line - "append ".len, 'x');
    const e = try parse("label a\nkernel /k\nappend " ++ value ++ "\r\n", conf, &paths);
    try testing.expectEqualStrings(&value, e.append.?);
    try testing.expect(e.append.?.len <= max_append);
}

test "an empty file has no label" {
    var paths: Paths = .{};
    try testing.expectError(error.NoLabel, parse("", conf, &paths));
}

test "a file with no label is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.NoLabel, parse("default a\ntimeout 1\nkernel /k\n", conf, &paths));
}

test "an initrd list that starts with a comma is an error" {
    var paths: Paths = .{};
    try testing.expectError(error.MissingValue, parse("label a\nkernel /k\ninitrd ,/two\n", conf, &paths));
}
