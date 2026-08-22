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

## The linker script follows the tree

The host tool `tools/fdt2ld.zig` reads the same tree and generates the linker
script. The main firmware links at the DRAM `memory` base. The FSBL links for
XIP from the flash window and keeps its writable state in DRAM (or on-chip SRAM
when the tree has an `mmio-sram` node).

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

Weir binds conduit's `ns16550a` driver for the console. River's minimal UART
does not acknowledge writes to the FIFO or modem-control registers, so Weir
binds it with `minimal_init`, which programs only the line-control and baud
registers. QEMU accepts the full init, so the one path serves both.
