# Building

Weir builds with Zig 0.16 and needs no other build tools. The `qemu` target also
needs qemu-system-riscv64. The repository is a Nix flake, so `nix develop` gives
you a shell with both.

```
nix develop          # optional: a shell with Zig and QEMU
zig build            # build the firmware and the FSBL
zig build qemu       # boot under qemu-system-riscv64 -machine virt
```

`zig build` installs to `zig-out/bin`:

- `weir-firmware.elf` - the linked firmware, for debugging.
- `weir-firmware.bin` - the flat image for QEMU `-bios`.
- `weir-firmware-packed.bin` - the flat image with the header the FSBL reads.
- `weir-fsbl.bin` - the first-stage boot loader.

To run these on QEMU or write them to a board, see [flashing.md](flashing.md).

## Build options

Pass a board's device tree with `-Ddtb` to build for real hardware:

```
zig build -Ddtb=board.dtb
```

| Option | Meaning |
| --- | --- |
| `-Ddtb=PATH` | Device tree. Weir reads its SoC addresses from it at compile time. |
| `-Daml=PATH` | ACPI DSDT AML blob to embed. |
| `-Dpayload=PATH` | An S-mode ELF payload to embed and jump to. |
| `-Dpe-app=PATH` | A PE32+ EFI application to embed and load. |
| `-Ddisk-boot` | Read the boot PE off a disk, not an embedded blob. |
| `-Dboot-manager` | Boot through the ESP boot manager (GPT, FAT, BootOrder). |
| `-Dinitrd=PATH` | An initramfs to serve the kernel through LoadFile2. |
