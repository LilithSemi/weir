# UEFI

Weir provides a UEFI environment for RISC-V. It aims to become a full UEFI
implementation. For now it implements the services and protocols a PE bootloader
or the Linux EFI stub needs, and it grows from there. The UEFI code lives in
`src/uefi/` and runs in S-mode, next to the loaded application.

## How it works

Weir fills the System Table, then points every Boot Services and Runtime
Services entry at a stub that returns `EFI_UNSUPPORTED`. It then installs the
functions a bootloader actually calls over the stubs. So the table is complete,
and an unimplemented call fails cleanly instead of jumping to an invalid
address.

## Boot Services

Weir implements the memory, protocol, and hand-off calls a loader needs:

- `AllocatePages`, `AllocatePool`, and their frees, from a simple page pool.
- `GetMemoryMap` and `ExitBootServices`.
- `InstallProtocolInterface`, `HandleProtocol`, `OpenProtocol`, `LocateProtocol`,
  and `LocateDevicePath`.
- `InstallConfigurationTable`, `CopyMem`, and `SetMem`.

## Runtime Services

- `ResetSystem` and `SetVirtualAddressMap`.
- `GetVariable`, `SetVariable`, `GetNextVariableName`, and `QueryVariableInfo`.
  A flash store keeps the variables with the non-volatile attribute. See
  [Variable store](#variable-store).
- `GetTime` and `SetTime`. Time comes from an RTC when the board has one, else
  from a software clock that starts at the UNIX epoch (`src/time.zig`).

## Variable store

`src/var/store.zig` backs the variable services. Weir picks the backend at build
time from the device tree:

- SPI: the tree has a `jedec,spi-nor` node with a `ctrl` register block and a
  `river-vars` partition. The store lives in that partition.
- CFI: the tree has a `cfi-flash` node with a second bank, as on QEMU `virt`. The
  store lives in that bank.
- None: the board has neither. A read gives `EFI_NOT_FOUND` and a write gives
  `EFI_DEVICE_ERROR`.

The store uses two banks on the flash. Each bank holds a header and an append
log of records, and every record has a CRC. A write appends a record, and a
delete appends a record with no data. When the active bank is full, Weir copies
the live records to the other bank. It writes the valid mark of the new bank
last, so a bank without the mark is not in use. At boot, Weir reads the valid
bank with the highest sequence number. A power loss during an append can leave an incomplete record at the end of
the log. Weir drops it, keeps the data before it, and prints
`[var] recovered after an incomplete write`. A power loss during a compaction
leaves the old bank active, and Weir prints nothing.

| Item | Limit |
| --- | --- |
| Variable name | 255 characters |
| Variable data | 32 KiB |
| Flash capacity | Up to 128 KiB per bank, less a 16 byte header |
| RAM for volatile variables | 16 KiB |

A variable without `EFI_VARIABLE_NON_VOLATILE` stays in RAM and is gone at
reset. A set with attributes of 0 or a data size of 0 deletes the variable.

The variable services work before `ExitBootServices`. Runtime access to
variables is not available yet.

### FlashLock

On an SPI board, the variable `FlashLock` locks flash partitions until the next
reset. It uses the Weir vendor GUID `53ad00ad-b655-414a-a2ff-058c0db1659d`. It
must have the non-volatile attribute and hold a 4 byte little-endian bit mask.

Bit N locks partition N, counted in the order of the device tree. Weir ignores
the bit of the `river-vars` partition, because it must keep writing its own
store. It also ignores bits above the last partition. Weir reads the variable at
boot, locks the partitions, and prints `[flash] locked partitions:` with their
labels. The lock holds until reset, for Weir and for Linux.
A new value of `FlashLock` takes effect at the next boot.

## Protocols

- `EFI_LOADED_IMAGE_PROTOCOL` and `EFI_DEVICE_PATH_PROTOCOL`.
- `EFI_BLOCK_IO_PROTOCOL` and `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`, so the loaded
  app reads the ESP.
- `EFI_LOAD_FILE2_PROTOCOL`, which serves an initramfs to the Linux EFI stub.
- `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL` and `EFI_SIMPLE_TEXT_INPUT_PROTOCOL` over the
  console UART.
- `RISCV_EFI_BOOT_PROTOCOL`, which reports the boot hart ID.

## Configuration tables

Weir hands the OS its platform description through the configuration table: the
ACPI RSDP, the SMBIOS entry point, and the device tree.

## Boot path

Weir loads a PE image, either an embedded blob or one read off the ESP through
the boot manager, then runs it. The boot manager (`src/boot/manager.zig`) finds
an ESP, mounts FAT, and honours the `BootOrder` and `Boot####` variables, or the
removable-media fallback `\EFI\BOOT\BOOTRISCV64.EFI`.

## Not yet implemented

These are on the way to a full implementation, not out of scope. Weir does not
yet provide a Graphics Output Protocol, an RNG protocol, event or timer services,
`LoadImage` and `StartImage`, Secure Boot, or a network stack. Their table
entries return `EFI_UNSUPPORTED` until Weir fills them in.
