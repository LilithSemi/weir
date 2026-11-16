# Device tree

Weir reads its hardware from a device tree at build time. `src/soc.zig` matches
each node by its `compatible` string and reads its address. `tools/fdt2ld.zig`
reads the same tree to lay out the linker script. This is the reference for the
nodes and properties Weir reads.

Pass the tree with `-Ddtb`. With none, Weir uses the QEMU `virt` addresses. See
[porting.md](porting.md) for the porting flow.

## Peripherals

Weir matches one node per device class. It reads the MMIO base from `reg`, and a
clock rate from `clock-frequency` where it needs one.

| Class | `compatible` | Weir reads |
| --- | --- | --- |
| UART | `ns16550a`, `snps,dw-apb-uart` | console base, clock |
| Timer | `riscv,clint0`, `sifive,clint0` | CLINT base, tick rate |
| Memory | (a node with `device_type = "memory"`) | DRAM base, size |
| Flash | `jedec,spi-nor` | XIP flash base, write port, partitions |
| CFI flash | `cfi-flash` | second bank for the variable store (QEMU) |
| DDR controller | `harbor,sdram-controller` | training window (FSBL) |
| TPM | `tcg,tpm-tis-mmio` | TIS base |
| RTC | `google,goldfish-rtc` | wall clock |
| SD/MMC host | `harbor,sdhci`, `harbor,sdio` | block base, clock |
| SPI master | `harbor,spi`, `midstall,harbor-spi` | SPI base for an SD card |

The console UART, the CLINT, and the memory node are the minimum a board needs.
An absent class turns its feature off or falls back to a default.

## Clocks

The CLINT `mtime` runs at the timer's `clock-frequency`. The software wall clock
uses this rate to count seconds when the board has no RTC. Weir defaults to 10
MHz, the QEMU rate, when the tree omits it. The UART baud divisor comes from the
UART node's `clock-frequency` the same way.

## Flash partitions

The flash node holds a `fixed-partitions` subnode with `partition@NNN` leaves.
Each leaf has a `reg = <offset size>` and a `label`. Weir reads three by label:

- `river-fsbl` - the FSBL runs XIP from here. This offset clears the FPGA
  bitstream slot on an FPGA board.
- `river-firmware` - the main image lives here. Its offset and size set where the
  FSBL looks and how large the image may be.
- `river-vars` - the EFI variable store lives here. See [uefi.md](uefi.md).

With no partition map, Weir uses the legacy defaults (the FSBL at the flash base,
the main image at offset `0x100000`).

Weir reads the flash `reg` entries as CPU addresses. The buses above the flash
node must have identity `ranges`.

## Variable store flash

The EFI variable store needs flash that Weir can write. See
[uefi.md](uefi.md) for how the store works.

On a board with the Harbor SPI flash controller, the `jedec,spi-nor` node has
two `reg` entries. `reg-names = "xip", "ctrl"` names them. The `xip` entry is the
read window and the `ctrl` entry is the write port. The store lives in the
partition with the label `river-vars`. Without the `ctrl` entry or this
partition, the board has no SPI variable store.

The `river-vars` partition has these rules. Each one is a compile error when
broken:

- It is at least 32 KiB.
- Its offset and its size are multiples of 8 KiB.
- It ends within the first 16 MiB of the flash.

Weir uses the first half of the partition as bank 0 and the second half as bank
1. Each bank holds up to 128 KiB. Give the partition the `read-only` property, so
Linux does not write it.

The order of the partition nodes is the lock bit order. The first partition in
the tree is bit 0. See `FlashLock` in [uefi.md](uefi.md#flashlock). A tree can
hold up to 32 partitions.

```
flash@20000000 {
	compatible = "jedec,spi-nor";
	reg = <0x20000000 0x1000000>, <0x10030000 0x1000>;
	reg-names = "xip", "ctrl";
	#address-cells = <1>;
	#size-cells = <1>;

	partitions {
		compatible = "fixed-partitions";
		#address-cells = <1>;
		#size-cells = <1>;

		partition@0 {
			reg = <0x000000 0x400000>;
			label = "fpga-bitstream";
		};
		partition@800000 {
			reg = <0x800000 0x40000>;
			label = "river-vars";
			read-only;
		};
	};
};
```

All addresses in this example are examples. Use the values of the board.

On QEMU `virt`, the `cfi-flash` node has two banks in `reg`. Weir uses the second
bank for the store and needs no partition. Store bank 0 is the first 256 KiB
erase block of that flash bank and store bank 1 is the second. Weir uses 128 KiB
of each block.

## On-chip SRAM

An `mmio-sram` node gives the FSBL a scratch window for its stack and writable
state. Without it, the FSBL uses the DRAM window instead.

## DDR training

A DDR controller that needs runtime training carries a `training` child node. It
describes the knob register window and an ordered list of `knob@N` nodes. Each
knob has a scope (`global`, `per-lane`, or `per-bit`), a feedback mode
(`pattern` or `map`), and a tap range. The FSBL reads this at build time and
sweeps each knob at boot. See [fsbl.md](fsbl.md).
