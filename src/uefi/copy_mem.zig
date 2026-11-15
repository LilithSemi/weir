//! Overlap-safe UEFI CopyMem implementation.

pub fn copyMem(dest: [*]u8, src: [*]const u8, len: usize) void {
    if (len == 0) return;

    const dst_addr = @intFromPtr(dest);
    const src_addr = @intFromPtr(src);
    const backwards = dst_addr > src_addr and dst_addr - src_addr < len;

    if ((dst_addr & 7) != 0 or (src_addr & 7) != 0) {
        const dst: [*]volatile u8 = @ptrCast(dest);
        const source: [*]const volatile u8 = @ptrCast(src);
        if (backwards) {
            var i = len;
            while (i > 0) {
                i -= 1;
                dst[i] = source[i];
            }
        } else {
            for (0..len) |i| dst[i] = source[i];
        }
        return;
    }

    // Volatile word accesses keep LLVM from folding this back into the generic
    // byte-assembling memmove runtime routine. River supports aligned 64-bit
    // memory operations, which are substantially cheaper than per-byte loads.
    const dst_words: [*]volatile u64 = @ptrFromInt(dst_addr);
    const src_words: [*]const volatile u64 = @ptrFromInt(src_addr);
    if (backwards) {
        var i = len;
        while (i & 7 != 0) {
            i -= 1;
            dest[i] = src[i];
        }
        while (i >= 8) {
            i -= 8;
            dst_words[i / 8] = src_words[i / 8];
        }
    } else {
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) dst_words[i / 8] = src_words[i / 8];
        while (i < len) : (i += 1) dest[i] = src[i];
    }
}

test "aligned copy uses word path and preserves bytes outside range" {
    var source: [64]u8 align(8) = undefined;
    var actual: [64]u8 align(8) = @splat(0xcc);
    for (&source, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);

    copyMem(actual[8..].ptr, source[8..].ptr, 19);
    try @import("std").testing.expectEqualSlices(u8, source[8..27], actual[8..27]);
    try @import("std").testing.expectEqual(@as(u8, 0xcc), actual[7]);
    try @import("std").testing.expectEqual(@as(u8, 0xcc), actual[27]);
}

test "aligned overlapping copies match memmove in both directions with tails" {
    var backward: [64]u8 align(8) = undefined;
    for (&backward, 0..) |*byte, i| byte.* = @truncate(i * 11 + 1);
    var expected_backward = backward;
    @memmove(expected_backward[8..39], expected_backward[0..31]);
    copyMem(backward[8..].ptr, backward[0..].ptr, 31);
    try @import("std").testing.expectEqualSlices(u8, &expected_backward, &backward);

    var forward: [64]u8 align(8) = undefined;
    for (&forward, 0..) |*byte, i| byte.* = @truncate(i * 13 + 5);
    var expected_forward = forward;
    @memmove(expected_forward[0..31], expected_forward[8..39]);
    copyMem(forward[0..].ptr, forward[8..].ptr, 31);
    try @import("std").testing.expectEqualSlices(u8, &expected_forward, &forward);
}

test "unaligned copies preserve overlap direction and sentinels" {
    var backward: [48]u8 = undefined;
    for (&backward, 0..) |*byte, i| byte.* = @truncate(i * 5 + 9);
    var expected_backward = backward;
    @memmove(expected_backward[5..32], expected_backward[1..28]);
    copyMem(backward[5..].ptr, backward[1..].ptr, 27);
    try @import("std").testing.expectEqualSlices(u8, &expected_backward, &backward);

    var forward: [48]u8 = undefined;
    for (&forward, 0..) |*byte, i| byte.* = @truncate(i * 3 + 7);
    var expected_forward = forward;
    @memmove(expected_forward[1..28], expected_forward[5..32]);
    copyMem(forward[1..].ptr, forward[5..].ptr, 27);
    try @import("std").testing.expectEqualSlices(u8, &expected_forward, &forward);
}

test "empty copy is a no-op" {
    var bytes = [_]u8{ 0x12, 0x34 };
    copyMem(bytes[1..].ptr, bytes[0..].ptr, 0);
    try @import("std").testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &bytes);
}
