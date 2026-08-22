# Status

What Weir does today, and what is planned. This is a snapshot, not a promise.

## Working

- **Boot.** Runs on QEMU and on River Creek V1, where it boots the Ferrite
  kernel. See [devices.md](devices.md).
- **SBI.** Base, TIME, IPI, RFENCE, HSM, DBCN, and SRST, plus the legacy console
  and shutdown. Console input and the real machine CSR IDs. See [sbi.md](sbi.md).
- **UEFI.** The boot and runtime services a PE bootloader or the Linux EFI stub
  needs: memory, protocols, ExitBootServices, the variable services, and
  GetTime/SetTime. Block, filesystem, LoadFile2, and RISC-V boot protocols. See
  [uefi.md](uefi.md).
- **Platform tables.** ACPI (hardware-reduced), SMBIOS, and the device tree,
  handed to the OS through the configuration table.
- **Measured boot.** TPM 2.0 over TIS, with a PCR chain and an event log. See
  [measured-boot.md](measured-boot.md).
- **First-stage boot loader.** DDR training and image load, for SoCs that need
  it. See [fsbl.md](fsbl.md).
- **Storage.** virtio-blk, an SD/MMC host, and an SD card over SPI, with a GPT
  and FAT boot manager.

## Planned

- **Secure boot.** Authenticate each image against a key before it runs. This is
  the next security step after measured boot.
- **More OS support.** Delta V1 boots the firmware but runs no OS yet.
- **Graphics Output Protocol.** A framebuffer for the OS and for graphical
  bootloaders. Conduit already carries a virtio-gpu driver.
- **Netboot.** A network stack, to boot over PXE or HTTP.

## In Progress

- **Smaller UEFI and SBI gaps.** An RNG protocol, event and timer services,
  `LoadImage` and `StartImage`, and the SBI PMU extension.
