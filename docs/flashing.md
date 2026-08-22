# Flashing

How to run Weir on QEMU, and how to write it to a board's flash.

## QEMU

QEMU needs no flashing. Its DRAM works at reset, so it needs no FSBL. Load the
flat firmware image as the BIOS:

```
zig build qemu
```

That is the same as:

```
qemu-system-riscv64 -machine virt -nographic -bios zig-out/bin/weir-firmware.bin
```

Use the plain `weir-firmware.bin` here. QEMU does not read the FSBL header, so the
packed image is not needed.

## River

River boots from SPI flash. Write two images:

- `weir-fsbl.bin` to the `river-fsbl` partition.
- `weir-firmware-packed.bin` to the `river-firmware` partition. Use the packed
  image, not `weir-firmware.bin`, because the FSBL reads its WEIR header.

Find the two flash offsets in the SoC's documentation, which carries the flash
layout. They are the offsets the board's device tree gives in its
`fixed-partitions` node. Write each image to its offset with your flash tool.

### Combined image (weir.img)

`zig build` also makes `weir.img`. It is one flash-sized image. It holds the
FSBL at the `river-fsbl` offset and the packed firmware at the `river-firmware`
offset. `tools/mkflash.zig` reads these offsets and the flash size from the
device tree you pass with `-Ddtb`. It reads them from the same tree the FSBL
links against, so the image and the FSBL always agree. With no `-Ddtb`, it uses
the QEMU-virt defaults.

`weir.img` holds only the firmware. The `fpga-bitstream` slot below the FSBL is
zero. Do not write the full `weir.img` to a board that already holds its
bitstream. The zero bytes erase the bitstream, and the FPGA does not configure.

Use `weir.img` in one of these ways:

- QEMU's `river` machine needs no bitstream, so the zero slot is safe. Write the
  image to an `mtd` drive:

  ```
  qemu-system-riscv64 -machine river,soc=delta-v1 -nographic \
    -drive if=mtd,format=raw,file=zig-out/bin/weir.img
  ```

- A blank flash. Write the full `weir.img`. Then write the bitstream to offset 0
  with your flash tool, for example `dd`.

For a board that already holds its bitstream, write the two partitions on their
own instead (see above). This keeps offset 0 safe.

### From Linux on the board

If you run Linux on the board with that device tree, you do not need the raw
offsets. The SPI-NOR flash appears as an MTD device under `/dev/mtd`, and the
`fixed-partitions` labels name each partition, so the kernel exposes a per-label
path. Write to the labeled partition with `dd`:

```
dd if=weir-fsbl.bin            of=/dev/disk/by-label/river-fsbl
dd if=weir-firmware-packed.bin of=/dev/disk/by-label/river-firmware
```

The exact path depends on the kernel. Use whatever name the `fixed-partitions`
labels produce. See [device-tree.md](device-tree.md) for the partition labels.
