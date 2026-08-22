# Devices

The targets Weir runs on, and their status. QEMU emulates a generic RISC-V
machine for development. The others are River SoCs on a Digilent Arty S7-50. See
[testing.md](testing.md) for the setup.

| Target | Status | OS | Storage |
| --- | --- | --- | --- |
| QEMU virt | Tested | A PE bootloader or the Linux EFI stub | virtio-blk |
| Creek V1 | Tested | Boots the Ferrite kernel | SD card, tested |
| Delta V1 | Tested | Boots, no OS yet | SD card, detected |

## QEMU

The `qemu-system-riscv64 -machine virt` target. Its DRAM works at reset, so it
needs no FSBL. It boots a PE bootloader or the Linux EFI stub when you provide
one. Its storage is virtio-blk, and it has no SPI, so the SD-in-SPI path does not
run there. It carries a goldfish RTC, so the wall clock works.

## Creek V1

Tested on the Arty S7. It boots the Ferrite kernel. The SD card over SPI is
tested.

## Delta V1

Tested on the Arty S7. It boots, but it runs no OS yet. The SD card over SPI is
detected.
