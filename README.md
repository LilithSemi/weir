# Weir

Weir is UEFI firmware for RISC-V. It runs in M-mode, provides an SBI to the
supervisor, publishes ACPI and SMBIOS tables, and boots an EFI application or
the Linux EFI stub.

Weir targets both QEMU's `virt` machine and Lilith Semiconductor's River SoC on an FPGA. It
reads its hardware addresses from a device tree at build time, so one source
tree serves several boards.

## Why

Zig suits bare-metal and firmware work well. It is freestanding, it needs no
libc, and it builds with one tool. Weir is a firmware written in Zig, and
`zig build` is all it needs.

The established RISC-V firmware, EDK II, U-Boot, and coreboot, are large and
complex codebases. Weir stays minimal, yet complete enough to boot an operating
system on RISC-V. It provides the SBI to the supervisor and a UEFI environment to
the boot loader in one image. It reads the platform from a device tree, so the
same source boots QEMU and real hardware such as Lilith Semiconductor's River SoC.

## Features

- SBI provider for S-mode (Base, TIME, IPI, RFENCE, HSM, DBCN, SRST). See
  [docs/sbi.md](docs/sbi.md).
- UEFI boot services and runtime services, enough to run a PE bootloader or the
  Linux EFI stub. See [docs/uefi.md](docs/uefi.md).
- ACPI (hardware-reduced RISC-V) and SMBIOS tables, plus the device tree, handed
  to the OS through the UEFI configuration table.
- Measured boot into a TPM 2.0 over the TIS interface.
- A first-stage boot loader (FSBL) that trains the DDR and loads the main image,
  for SoCs without built-in DDR calibration.
- Block storage over virtio-blk, an SD/MMC host, or an SD card in SPI mode, with
  a GPT + FAT boot-manager path.

## Documentation

Build with `zig build`. See [docs/](docs/README.md) for how to build Weir and
how it works.

## Contributing

Weir gets its device drivers from `conduit`, Lilith Semiconductor's hardware-abstraction
library. See [CONTRIBUTING.md](CONTRIBUTING.md) for the repository layout and the
coding standards.
