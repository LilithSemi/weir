# Debugging

Weir prints its progress over the UART, and you can attach a debugger over JTAG.
This covers where to test, how to read the console, and how to attach OpenOCD.

## Where to test

Test in QEMU for logic. It is fast, it needs no hardware, and it is the right
choice when the hardware is not available or when it does not model a device,
such as virtio or another gap in the SoC. QEMU is more forgiving than silicon, so
it hides a class of bugs. See [testing.md](testing.md).

Prefer the reference hardware for real behaviour. Use a River Creek V1 or Delta
V1 on the Arty S7. Timing, DDR margins, and SoC quirks show only there. See
[devices.md](devices.md).

## The console

The UART is the first tool. Weir prints tagged progress lines, such as `[weir]`,
`[plat]`, `[acpi]`, `[fsbl]`, and `[sbi]`. When Weir hangs, the last line it
printed shows how far it got. Read the console over the UART.

## Reading a trap

On an unhandled trap, Weir prints:

```
[weir] unhandled trap: mcause={x} mepc={x} mtval={x}
```

- `mcause` is the trap cause. See the table below.
- `mepc` is the address of the faulting instruction. Resolve it against
  `weir-firmware.elf` with `addr2line` or `objdump` to find the source line.
- `mtval` is the faulting address, or the bad instruction word.

Common `mcause` codes:

| Code | Cause |
| --- | --- |
| 0 | instruction address misaligned |
| 1 | instruction access fault |
| 2 | illegal instruction |
| 4 | load address misaligned |
| 5 | load access fault |
| 6 | store or AMO address misaligned |
| 7 | store or AMO access fault |

A misaligned load or store is a common cross-target bug. QEMU emulates the
access, but the SoC traps it, so it appears only on hardware.

## FSBL progress

The FSBL prints a marker at each step: `[fsbl] train:` for the DDR training,
`[fsbl] ddr:` for the read eye, and `[fsbl] flash:` for the image copy. The last
marker before a stall says where it stopped.

## OpenOCD

River ships `openocd.cfg` files. Use them to attach OpenOCD over JTAG, then
connect a debugger to read registers and memory, or to set breakpoints.

Read River's debugging documentation first. The debug path has limitations and
quirks, and River's docs cover them.

## Common failures

- **No console output.** The UART is not up, or the SoC has a UART register
  quirk. Weir binds the console with `minimal_init` for River. See
  [porting.md](porting.md).
- **A hang after ACPI or storage.** Often a DDR issue or a misaligned access.
  Read the trap dump.
- **An FSBL stall.** Read the last `[fsbl]` marker to see whether the DDR training
  or the image copy stopped.
