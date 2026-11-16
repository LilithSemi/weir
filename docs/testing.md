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

### Variable store on QEMU

The QEMU `virt` machine has a CFI flash that holds the variable store. Build with
a device tree that has the `cfi-flash` node, and turn on the self-test:

```
zig build -Ddtb=riscv-virt.dtb -Dvar-selftest=true
```

QEMU writes `riscv-virt.dtb` with
`qemu-system-riscv64 -machine virt,dumpdtb=riscv-virt.dtb`.

Make a pflash file of 32 MiB of 0xFF bytes. Then boot with it as the second
pflash unit:

```
tr '\000' '\377' < /dev/zero | head -c 33554432 > vars.img
qemu-system-riscv64 -machine virt -nographic \
  -bios zig-out/bin/weir-firmware.bin \
  -drive if=pflash,unit=1,format=raw,file=vars.img
```

The first boot prints these lines:

```
[flash] cfi NOR @ 22000000, 32 MiB, 256 KiB blocks
[var] cfi flash store @ 22000000, 0 variable(s)
[var] self-test: boot 1, set and get ok
```

The self-test counts its boots in a non-volatile variable. On the second boot,
with the same file, the store holds that variable:

```
[var] cfi flash store @ 22000000, 1 variable(s)
[var] self-test: boot 2, set and get ok
```

A line `[var] self-test: failed at` with a step name means a variable call failed.
A line `[var] recovered after an incomplete write` means the last boot ended in the
middle of a write. Weir kept the data before it.

A pflash file that an older Weir wrote (the `WVS1` format) counts as empty. The
first write overwrites it.

The SPI backend needs hardware, because QEMU does not model the Harbor flash
write port.

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
