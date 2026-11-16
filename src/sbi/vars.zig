//! The firmware specific SBI call for EFI variables. S-mode fills the one request
//! block and passes its address. M-mode runs the request on the variable store.

const rt_abi = @import("../var/rt_abi.zig");
const store = @import("../var/store.zig");
const rt = @import("../uefi/rt.zig");
const sbi = @import("sbi.zig");

var busy: u8 = 0;

fn blockAddress() usize {
    return @intFromPtr(&rt.block);
}

pub fn supported() bool {
    return store.available();
}

pub fn call(addr: usize) sbi.Ret {
    if (!store.available()) return .{ .err = sbi.SBI_ERR_NOT_SUPPORTED };
    if (addr != blockAddress()) return .{ .err = sbi.SBI_ERR_INVALID_ADDRESS };
    if (@cmpxchgStrong(u8, &busy, 0, 1, .acquire, .monotonic) != null) {
        return .{ .err = sbi.SBI_ERR_DENIED };
    }
    defer @atomicStore(u8, &busy, 0, .release);
    rt_abi.execute(store, &rt.block);
    return .{};
}
