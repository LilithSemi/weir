//! ACPI table construction. The platform supplies the DSDT (raw AML) via `-Daml`;
//! we wrap it in the minimum HW-reduced RISC-V table set (RSDP -> XSDT -> FADT,
//! FADT.X_DSDT pointing at the AML in place). almanac's Builder lays the tables
//! into a static buffer and stamps every checksum.

const std = @import("std");
const almanac = @import("conduit").almanac;
const console = @import("../console/console.zig");

// Scratch for the built tables. The DSDT stays in rodata; we only reference it.
var table_buf: [4096]u8 align(16) = undefined;

/// Build the table set referencing `dsdt` (raw AML) and report a summary. No
/// paging here, so virtual == physical and `base_phys` is just `&table_buf`.
pub fn setup(dsdt: ?[]const u8) void {
    build(dsdt) catch {
        console.writeStr("[acpi] table construction failed (buffer too small)\n");
    };
}

fn build(dsdt: ?[]const u8) !void {
    const base = @intFromPtr(&table_buf);
    var b = almanac.Builder.init(&table_buf, base);
    b.oem_id = "MIDSTL".*;
    b.oem_table_id = "WEIR    ".*;
    b.creator_id = "WEIR".*;

    // Point both DSDT (32-bit) and X_DSDT (64-bit) at the embedded AML in place.
    const dsdt_phys: u64 = if (dsdt) |d| @intFromPtr(d.ptr) else 0;

    const fadt_phys = try b.fadt(.{ .dsdt_phys = dsdt_phys, .hw_reduced = true });
    const xsdt_phys = try b.xsdt(&.{fadt_phys});
    const rsdp_phys = try b.rsdp(xsdt_phys);

    console.printf("[acpi] RSDP @ {x}\n", .{rsdp_phys});
    console.printf("[acpi] XSDT @ {x}, FADT @ {x}\n", .{ xsdt_phys, fadt_phys });

    if (dsdt) |d| {
        // The AML blob is itself an SDT: signature[4], length at offset 4.
        const sig = d[0..4];
        const len = std.mem.readInt(u32, d[4..8], .little);
        console.printf("[acpi] DSDT @ {x}: '{s}', {d} bytes (provided AML)\n", .{ dsdt_phys, sig, len });
    } else {
        console.writeStr("[acpi] no AML provided (-Daml=PATH); DSDT omitted\n");
    }

    reportChecksums(rsdp_phys, xsdt_phys, fadt_phys);
}

fn reportChecksums(rsdp_phys: u64, xsdt_phys: u64, fadt_phys: u64) void {
    const rsdp_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(rsdp_phys)));
    const xsdt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(xsdt_phys)));
    const fadt_b: [*]const u8 = @ptrFromInt(@as(usize, @intCast(fadt_phys)));
    const ok_rsdp = almanac.checksum.valid(rsdp_b[0..36]);
    const ok_xsdt = almanac.checksum.valid(xsdt_b[0..44]); // header + one 64-bit entry
    const ok_fadt = almanac.checksum.valid(fadt_b[0..276]); // ACPI 6.x FADT
    console.printf(
        "[acpi] checksums: RSDP={s} XSDT={s} FADT={s}\n",
        .{ okStr(ok_rsdp), okStr(ok_xsdt), okStr(ok_fadt) },
    );
}

fn okStr(ok: bool) []const u8 {
    return if (ok) "ok" else "FAIL";
}
