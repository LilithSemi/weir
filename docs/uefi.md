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
  A CFI NOR flash backs the variable store when the board has one
  (`src/uefi/varstore.zig`).
- `GetTime` and `SetTime`. Time comes from an RTC when the board has one, else
  from a software clock that starts at the UNIX epoch (`src/time.zig`).

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
