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
| SD/MMC host | `harbor,sdhci`, `harbor,sdio` | block base, clock, `bus-width`, `cap-sd-highspeed`, `max-frequency` |
| SPI master | `harbor,spi`, `midstall,harbor-spi` | SPI base for an SD card |
| Display | `harbor,display` | register base, fixed framebuffer |

An SD/MMC host with `bus-width = <1>` runs its card at 1 bit. Other values and
no property give 4 bits. A card that refuses the change to 4 bits stays at 1 bit.
With `cap-sd-highspeed`, Weir switches a card that supports it to High Speed
with CMD6 and runs the SD clock at up to 50 MHz. The host divides its
`clock-frequency` by 2 or more, so 50 MHz needs a 100 MHz host clock.
`max-frequency` is the highest SD clock for the board wiring.

The console UART, the CLINT, and the memory node are the minimum a board needs.
An absent class turns its feature off or falls back to a default.

## Clocks

The CLINT `mtime` runs at the timer's `clock-frequency`. The software wall clock
uses this rate to count seconds when the board has no RTC. Weir defaults to 10
MHz, the QEMU rate, when the tree omits it. The UART baud divisor comes from the
UART node's `clock-frequency` the same way. The UART is a 16550, so the divisor
is the clock divided by 16 times the baud.

Weir also reads `reg-shift` and `reg-io-width` from the UART node. A register
is at its number shifted left by `reg-shift`, and each access has
`reg-io-width` bytes, 1 or 4. Without them the registers are 1 byte apart and
take byte accesses.

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

## Reset and power

Weir reads the `syscon-reboot` and `syscon-poweroff` nodes. Each has an `offset` and a `value`. The registers are in the node that the
`regmap` phandle names. Without a `regmap`, they are in the parent node. Weir
writes the value as a 32-bit word to the register at that offset. Weir does not use the `mask`
property.

A tree without these nodes is correct for a board with no such device. Then
Weir uses the first `reg` address of the `harbor,maskrom` node as the address
where a hart starts after a reset. See [sbi.md](sbi.md#system-reset).

## Netboot modem

A node with the compatible `espressif,esp-at` is an ESP32 with the AT command
firmware. Its parent is the 16550 UART of the module, with `clock-frequency`,
`reg-shift` and `reg-io-width` as the console UART has. The console UART must
be the first UART node of the tree.

| Property | Meaning |
| --- | --- |
| `enable-gpios` | The pin that lets the module run. Necessary. |
| `select-gpios` | The pin that connects the module to the UART. Optional. |
| `current-speed` | The baud rate of the module after a reset. The default is 115200. |
| `max-speed` | The baud rate for the data. Weir changes to it after the reset. The default is `current-speed`. |

Each of the two pin properties has a phandle to a `harbor,gpio` node, the pin number and a flags
cell. Bit 0 of the flags is set for a pin that is active when low. Only the
first node is used. See [netboot.md](netboot.md).

## Displays

Weir uses each node with the compatible `harbor,display`, in the order of the
tree. It reads the screen size, the stride and the pixel format from the
registers of the display, so the node needs only its `reg`.

A display node with no `memory-region` gets its framebuffer from Weir. Weir
takes the memory from the top of RAM early in the boot, before the storage
and the netboot, writes zeros to it, gives the address to the display and
turns the display on. The boot does not use the RAM above the lowest
framebuffer. The EFI memory map reports the framebuffer as reserved memory, so it stays in use
after the OS starts. Each display has its own framebuffer.

The property `harbor,scanout-memory` on a display node gives the memory that
the display can show, as one address and size pair. Weir puts the framebuffer
in that memory. When that memory is not in the `/memory` node, the framebuffer
is at its start. Without the property, the framebuffer comes from the RAM of
the `/memory` node.

A display node with a `memory-region` has a fixed framebuffer: the first `reg`
entry of the node that the phandle names. Weir uses that memory and allocates
none. Keep a fixed framebuffer out of the `/memory` node. Weir does not read
`/reserved-memory` for other purposes, so memory in `/memory` is used by the
firmware and given to the OS.

Weir draws the formats r5g6b5, x8r8g8b8 and a8r8g8b8. A display with another
format gets no framebuffer. Each display with a framebuffer has a graphics
output protocol, see [uefi.md](uefi.md#protocols). Weir prints one line for
each:

```
[display] 640x480 r5g6b5, framebuffer at 81f10000
```

### Boot splash

Weir draws a BMP at the center of each display when it turns the display on.
The image is `assets/boot-splash.bmp`, or the file of `-Dboot-splash`. It must
be an uncompressed BMP with 24 or 32 bits for each pixel, else the build fails.
An image larger than a screen is not drawn on that screen, and Weir prints:

```
[display] the splash of 320x200 is larger than the screen
```

The image is in the firmware only when the tree has a display node. The ACPI
BGRT table tells the OS where the image is, see [acpi.md](acpi.md).

When the tree has a `simple-framebuffer` node, the FSBL writes zeros to the
memory of its first `reg` entry after the memory bring-up and prints
`[fsbl] framebuffer: cleared`. A display that shows this memory from reset is
then black until Weir or an OS draws on it.

## On-chip SRAM

An `mmio-sram` node gives the FSBL a scratch window for its stack and writable
state. Without it, the FSBL uses the DRAM window instead.

## DDR training

A DDR controller that needs runtime training carries a `training` child node. It
describes the knob register window and an ordered list of `knob@N` nodes. Each
knob has a scope (`global`, `per-lane`, or `per-bit`), a feedback mode
(`pattern` or `map`), and a tap range. The FSBL reads this at build time and
sweeps each knob at boot. See [fsbl.md](fsbl.md).
