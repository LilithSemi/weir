# Porting

Weir reads its hardware addresses from a device tree at build time. It holds no
hardcoded addresses, so a port to a new board is mostly a matter of supplying a
device tree.

## The device tree drives the build

`src/soc.zig` reads the embedded device tree at compile time. It matches each
node's `compatible` string to a device class and lowers the node's `reg` into an
address. Build for a board by passing its tree:

```
zig build -Ddtb=board.dtb
```

With no `-Ddtb`, Weir falls back to the QEMU `virt` addresses.
[device-tree.md](device-tree.md) is the full reference for the nodes and
properties Weir reads.

The `conduit` library does the matching and the driver work. `soc.zig` bakes one
matcher per class Weir needs:

| Class | Purpose | Example `compatible` |
| --- | --- | --- |
| `uart` | console | `ns16550a`, `snps,dw-apb-uart` |
| `timer` | CLINT / machine timer | `riscv,clint0` |
| `memory` | main DRAM | `memory` |
| `flash` | XIP boot flash | `jedec,spi-nor` |
| `sdram` | DDR controller (for the FSBL) | `harbor,sdram-controller` |
| `tpm` | measured boot | `tcg,tpm-tis-mmio` |
| `rtc` | wall clock | `google,goldfish-rtc` |
| `block` | SD/MMC host | `harbor,sdhci` |
| `spi` | SPI master (SD in SPI mode) | `harbor,spi` |

A device is optional. When the tree has no node for a class, Weir uses a default
or turns the feature off. The console UART, the CLINT, and the memory node are
the minimum a board needs.

## Variable store

The EFI variable store needs flash that Weir can write. The board supplies one of
these:

- SPI flash: a `jedec,spi-nor` node with `reg-names = "xip", "ctrl"` for the
  Harbor write port, and a `river-vars` partition of at least 32 KiB. The
  partition offset and size are multiples of 8 KiB.
- CFI flash: a `cfi-flash` node with a second bank, as on QEMU `virt`.

With neither, the variable services have no store. See
[device-tree.md](device-tree.md) for the rules and an example, and
[uefi.md](uefi.md) for the store.

## The linker script follows the tree

The host tool `tools/fdt2ld.zig` reads the same tree and generates the linker
script. The main firmware links at the DRAM `memory` base. The FSBL links for
XIP from the flash window and keeps its writable state in DRAM (or on-chip SRAM
when the tree has an `mmio-sram` node).

## Memory layout

The size of the `memory` node selects the layout. `src/layout.zig` holds it, and
the firmware and `tools/fdt2ld.zig` both use it. All offsets are from the RAM base.

| Area | 128 MiB of RAM or more | Less than 128 MiB |
| --- | --- | --- |
| Firmware window | 0 to 32 MiB | 0 to 2 MiB with one hart, 0 to 4 MiB with more |
| ACPI tables | 63 MiB, 1 MiB long | top 64 KiB of the firmware window |
| First EFI image | loads at 32 MiB | loads at the end of the firmware window |
| EFI page pool | 64 MiB to the end of RAM | after the first image (2 MiB aligned) to the end of RAM |
| File staging buffer | 96 MiB, 64 MiB long | top half of RAM, at most 64 MiB |
| `\EFI\BOOT\initrd` buffer | 512 MiB, 512 MiB long | none |
| S-mode payload stacks | 8 of 1 MiB | 1 MiB for each hart in the tree |
| M-mode boot stacks | 8 of 64 KiB | 64 KiB for each hart ID up to the largest in the tree |

The first image must fit below the ACPI tables, or below the staging buffer when
RAM is less than 128 MiB. The boot manager does not use the part of a staging
buffer that is past the end of RAM.

Weir needs at least 16 MiB of RAM. A smaller `memory` node stops the build.

The firmware, with its stacks, must end inside the firmware window. The linker
script checks this and stops the link when it does not fit. With less than
128 MiB the window is 2 MiB or 4 MiB, and a Debug build or a tree with many harts
can be too large. Use `-Doptimize=ReleaseFast` or `-Doptimize=ReleaseSmall` then.

## DRAM training

When the SoC calibrates its DDR in hardware, load `weir-firmware.bin` directly
and skip the FSBL.

When the SoC leaves the DDR training to the CPU, such as some River SoCs, use the
FSBL. It runs from flash or SRAM, trains and brings up the DDR controller, copies
the main image into DRAM, and jumps to it. Flash `weir-fsbl.bin` at the boot
address and `weir-firmware-packed.bin` at the `river-firmware` partition. The
packed image carries the header the FSBL reads. See [fsbl.md](fsbl.md).

## Adding a peripheral driver

Weir gets its drivers from `conduit`. To support a new device:

1. Add the driver to conduit, or reuse one it already has.
2. Give the board's device tree a node with a `compatible` string the conduit
   driver matches.
3. If the device is a new class Weir must discover, add a matcher to the
   `matchers` table in `src/soc.zig`.

## Console notes

Weir binds conduit's `ns16550a` driver for the console. The main firmware uses
the full init, which also turns on the FIFOs. The FSBL only sends, so it binds
with `minimal_init`, which programs only the line-control and baud registers.
A UART that does not acknowledge a write to the FIFO or modem-control register
stops the main firmware at its first line.
