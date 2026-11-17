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

- `AllocatePages`, `AllocatePool`, and their frees, from one page pool. The
  pool frees and reuses memory, a page allocation of 2 MiB or more is 2 MiB
  aligned, and a request for conventional, persistent, unaccepted or an
  undefined memory type returns `EFI_INVALID_PARAMETER`.
- `GetMemoryMap` and `ExitBootServices`. The memory map gives each allocated
  range with its memory type, and free pool memory as conventional memory. A
  pool block under 32 KiB of loader data or boot services memory can show as
  loader data, and a reserved, unusable, MMIO or vendor type shows as reserved.
  `ExitBootServices` returns `EFI_INVALID_PARAMETER` when the map key is not
  the key of the current map.
- `InstallProtocolInterface`, `HandleProtocol`, `OpenProtocol`, `LocateProtocol`,
  and `LocateDevicePath`.
- `InstallConfigurationTable`, `CopyMem`, and `SetMem`.

## Runtime Services

- `ResetSystem`.
- `GetVariable`, `SetVariable`, `GetNextVariableName`, and `QueryVariableInfo`.
  A flash store keeps the variables with the non-volatile attribute. See
  [Variable store](#variable-store).
- `GetTime` and `SetTime`. Time comes from an RTC when the board has one, else
  from a software clock that starts at the UNIX epoch (`src/time.zig`).

After `ExitBootServices`, the four variable services keep working when the board
has a variable store. See [Runtime access](#runtime-access). Every other runtime
service returns `EFI_UNSUPPORTED`.

## Variable store

`src/var/store.zig` backs the variable services. Weir picks the backend at build
time from the device tree:

- SPI: the tree has a `jedec,spi-nor` node with a `ctrl` register block and a
  `river-vars` partition. The store lives in that partition.
- CFI: the tree has a `cfi-flash` node with a second bank, as on QEMU `virt`. The
  store lives in that bank.
- None: the board has neither. A read gives `EFI_NOT_FOUND` and a write gives
  `EFI_UNSUPPORTED`.

The store uses two banks on the flash. Each bank holds a header and an append
log of records, and every record has a CRC. A write appends a record, and a
delete appends a record with no data. When the active bank is full, Weir copies
the live records to the other bank. It writes the valid mark of the new bank
last, so a bank without the mark is not in use. At boot, Weir reads the valid
bank with the highest sequence number. A power loss during an append can leave an incomplete record at the end of
the log. Weir drops it, keeps the data before it, and prints
`[var] recovered after an incomplete write`. A power loss during a compaction
leaves the old bank active, and Weir prints nothing.

Weir reads back each record after it writes it, and it reads back each new bank
before it writes the valid mark. When the bytes on the flash are different, the
write gives `EFI_DEVICE_ERROR` and the running system keeps the old value. After
a reset the variable can have the old value or the new value. The next write
copies the live records to the other bank first.

| Item | Limit |
| --- | --- |
| Variable name | 255 characters |
| Variable data | 32 KiB |
| Flash capacity | Up to 128 KiB per bank, less a 16 byte header |
| RAM for volatile variables | 16 KiB |

A variable without `EFI_VARIABLE_NON_VOLATILE` stays in RAM and is gone at
reset. A set with attributes of 0 or a data size of 0 deletes the variable.

### Runtime access

The code of the four variable services is in the runtime region, so an OS can
call it after `ExitBootServices`. The region has two memory map entries, both
with the `EFI_MEMORY_RUNTIME` attribute:

- `EfiRuntimeServicesCode` holds the stubs.
- `EfiRuntimeServicesData` holds the Runtime Services table and the request
  block.

The stubs use nothing else of the firmware, and the build checks this. See
[building.md](building.md).

A stub copies its arguments into the request block and makes one SBI call.
M-mode owns the variable store and the flash, and runs the request. See
[sbi.md](sbi.md#variables).

`EFI_RT_PROPERTIES_TABLE` has the value `0x2070` when the board has a store and
the runtime region is in place.
This value lists the four variable services. With no store, the value is 0 and the
services return `EFI_NOT_FOUND` for a read and `EFI_UNSUPPORTED` for a write or
`QueryVariableInfo`. Weir does not support `SetVirtualAddressMap`. It expects the
OS to map each memory map entry that has the runtime attribute at its physical
address.

After `ExitBootServices`, these rules apply:

| Request | Result |
| --- | --- |
| Read a variable that has no runtime access | `EFI_NOT_FOUND`. The variable is hidden, and `GetNextVariableName` skips it |
| Write without both the non-volatile and the runtime access attribute | `EFI_INVALID_PARAMETER` |
| Write or delete of a variable that has no runtime access | `EFI_INVALID_PARAMETER` |
| Delete of a visible variable | `EFI_SUCCESS` |
| Delete of a variable that does not exist | `EFI_NOT_FOUND` |
| `GetNextVariableName` with a previous name that is hidden or does not exist | `EFI_INVALID_PARAMETER` |

A write of a volatile variable fails after `ExitBootServices`.

The callers must serialise their runtime calls, because the request block is
shared. M-mode cannot protect the block. A second caller that arrives while a
request runs gets `EFI_DEVICE_ERROR`.

A write can take a long time when the store compacts, because Weir erases many
sectors. The hart that makes the call stays in M-mode for that time. While it is in a
long flash operation, another hart that sends it an SBI remote fence or an IPI
waits until it returns.

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
- `EFI_GRAPHICS_OUTPUT_PROTOCOL`, one for each display that has a framebuffer.
  Each has one mode, the mode of the display. The framebuffer of an r5g6b5
  display has the bit mask pixel format. The 32 bit formats are blue, green,
  red, reserved. All four block transfer operations work. See
  [device-tree.md](device-tree.md#displays).

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
