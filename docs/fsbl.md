# First-stage boot loader

Weir's first-stage boot loader (FSBL) is a thin entrypoint. It loads the main
Weir firmware from system storage, usually flash, into memory, then runs it. The
main firmware runs from DRAM, so something has to place it there first.

At that early point DRAM is not ready, so the FSBL runs before it. On hardware
that maps flash into the address space, the FSBL executes in place from that
flash. On hardware that does not, it executes from cache configured as RAM. It
keeps its writable state in on-chip SRAM, in cache-as-RAM, or in the DRAM window
once that is up.

Some SoCs also need the FSBL to train the DDR. A DDR PHY needs its delays
calibrated before the DRAM is reliable. Some SoCs calibrate in hardware and boot
the firmware directly. Others leave it to the CPU, so the FSBL trains the DDR
before it copies Weir into DRAM. Some River SoCs need this training, and some do
not. QEMU is a virtual machine, so it models no DDR PHY and needs no FSBL.

The code lives in `src/fsbl/`.

## Boot sequence

`src/fsbl/start.zig` holds the reset vector. `src/fsbl/main.zig` holds the flow.

1. **Reset.** `_start` points `mtvec` at the FSBL trap handler, sets the global
   and stack pointers, then tail-calls `fsblMain`. Only the boot hart runs the
   FSBL. The other harts wait for the main firmware's HSM.
2. **XIP setup.** The FSBL runs in place from read-only flash, so its writable
   globals do not exist yet. `fsblMain` copies the initialized `.data` from its
   flash load image into the DRAM window, then zeroes `.bss`.
3. **Console.** It binds the UART and prints its progress, so a hang shows how
   far the boot got.
4. **Memory.** It brings up the memory controller, and trains it when the tree
   has a DDR3 training window or a `training` node. A failure halts the boot.
5. **Load.** It copies the main image out of flash into DRAM and verifies it.
6. **Measure.** It measures the loaded image into the TPM before it runs, as the
   root of the measured-boot chain.
7. **Jump.** It enters the main firmware at the DRAM base with the hart ID and
   the device-tree pointer, exactly as the platform would enter Weir directly.

## Memory bring-up

`src/fsbl/ddr.zig` brings up the memory controller, and a memtest checks the
array before the boot continues. It gets the memory type from the compatible
ids of the controller node, and its log lines start with that type:

| Compatible | Prefix | Line when the FSBL does no training |
| --- | --- | --- |
| `harbor,ddr3-sdram` | `[fsbl] ddr3:` | `[fsbl] ddr3: hardware-calibrated` |
| `harbor,sdr-sdram` | `[fsbl] sdr:` | `[fsbl] sdr: no calibration needed` |
| neither | `[fsbl] ram:` | `[fsbl] ram: ready` |

A DDR3 controller with no training window calibrates itself and holds the
first access until it is ready. An SDR controller has no calibration.

### DDR3 training window

A Harbor DDR3 controller built for runtime training has a training window. The
controller node gives its address in `harbor,training-base`. The window and the
SPD registers take the top 4 KiB of the DRAM, so the `reg` of the node is
already 4 KiB smaller.

This controller does not train until firmware starts it, and each DRAM access
waits with no error until training ends. The FSBL keeps its state in SRAM, so
the tree must have an `mmio-sram` node, or the FSBL build fails.
`src/fsbl/ddr3_window.zig` waits until the controller is ready, starts the
hardware sequence, and waits for the result. Then the FSBL prints the delays of
each lane and runs the memtest:

```
[fsbl] ddr3: training window at 8ffff000
[fsbl] ddr3: trained, 1 attempt(s)
[fsbl] ddr3: rank 0 lane 0: pass wdqs 0 gate 41 rdqs 15 wdq 10 wlat 0
```

When training fails, the FSBL prints the fail code, the rank and the lane, and
halts.

### Knob window

`src/fsbl/ddr_train.zig` is a generic training engine for earlier controllers that do the
JEDEC init in hardware but leave the PHY delay knobs open for the CPU to centre
at boot. It reads a `training` node from the device tree at compile time, the
same way `soc.zig` reads the SoC addresses. For each knob it sweeps the tap
range, checks a known pattern through the main DRAM path, and parks the tap at
the centre of the widest passing window.

## Loading the main image

The main image sits in flash at the `river-firmware` partition, behind an
8-byte header: a 4-byte magic `WEIR` and a 4-byte little-endian length.
`tools/pack-fw.zig` writes this header, and `zig build` produces the packed
image as `weir-firmware-packed.bin`.

`src/fsbl/flash.zig` reads the header, then copies the image into DRAM in chunks.
It block-copies each chunk and re-copies it until it compares equal, because the
DDR write path can drop a marginal word.

## Memory layout

`tools/fdt2ld.zig` generates the FSBL linker script from the device tree. The
FSBL links its `.text` and `.rodata` for XIP from the flash window. It keeps its
writable state, its `.data`, `.bss`, and stack, in the DRAM window, or in on-chip
SRAM when the tree has an `mmio-sram` node. The `.data` load image stays in
flash, and step 2 above copies it to its runtime address.

## Building

```
zig build            # produces weir-fsbl.bin alongside the firmware
zig build -Ddtb=board.dtb
```

Build with the board's device tree, so the FSBL reads its SoC addresses and its
`training` node at compile time. Flash `weir-fsbl.bin` at the board's boot
address. See [testing.md](testing.md) for the reference hardware and
[porting.md](porting.md) for the device-tree bindings.
