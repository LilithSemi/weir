# Testing

Weir runs on two very different targets: QEMU and real hardware. They catch
different bugs, so use both. QEMU is fast and proves the firmware logic. Hardware
proves the timing, the analog margins, and the SoC quirks that QEMU does not
model.

## Host tests

Conduit, the driver library, has host unit tests for the pure driver logic. Run
them from the conduit tree:

```
zig build test
```

These run on the build machine. They cover the driver protocol logic, such as
the SD-SPI identification sequence and the console writer, without any hardware.

## QEMU

```
zig build qemu
```

This boots `weir-firmware.bin` under `qemu-system-riscv64 -machine virt`. QEMU
tests the firmware end to end: the SBI calls, the UEFI services, the ACPI and
SMBIOS tables, and the boot path.

QEMU does not model the River SoC. It provides a generic 16550 UART, a goldfish
RTC, and virtio-blk storage. Build with `-Ddtb` to embed a board's device tree,
but the machine QEMU runs is still `virt`.

## Hardware

The reference hardware is a River Creek V1 or Delta V1 SoC on a Digilent Arty
S7-50 FPGA board. An SD card sits in a Digilent Pmod SD on the JA connector,
wired to the SoC's SPI master. The FSBL brings up DDR, then loads and runs the
main firmware. See [devices.md](devices.md) for the tested devices and their
status.

Flash `weir-fsbl.bin` at the boot address and `weir-firmware-packed.bin` at the
`river-firmware` partition. Read the console over the UART.

## What only hardware catches

QEMU is more forgiving than silicon, so it hides a class of bugs. Test these on
hardware before you trust them.

| Class | On QEMU | On hardware |
| --- | --- | --- |
| Misaligned access | Emulated | Traps (mcause 4 or 6) |
| DDR write margin | Every write sticks | A marginal word can drop |
| Flash access width | Any width reads | The controller may need a fixed width |
| UART register quirks | Accepts the full init | River stalls on FCR/MCR writes |
| SPI and SD timing | Not modeled | Real clock and turnaround |

A change that passes QEMU can still fault or hang on the SoC. Two real cases: the
console writer walked off an empty vector as a misaligned load, and the flash
copy path hit the marginal DDR write. Both passed QEMU and showed only on River.
See [debugging.md](debugging.md) for how to chase such a failure on hardware.

## Before you trust a change

- `zig build test` in conduit is green.
- `zig build qemu` boots the firmware.
- A change to the FSBL, the DDR path, the flash copy, the console, or any MMIO
  access gets a boot on the reference hardware.
