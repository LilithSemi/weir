# SMBIOS

Weir publishes SMBIOS (DMI) tables so the OS can report the board identity. The
code lives in `src/uefi/smbios.zig`.

Weir builds a small SMBIOS 3.0 structure table and a 64-bit entry point. The OS
finds the entry point through the SMBIOS3 GUID in the UEFI configuration table.
Linux's DMI scanner reads it and fills `/sys/class/dmi/id`, so `dmidecode` and
the kernel see real board information.

## Structures

Weir builds the structures the DMI core needs:

- BIOS information (type 0).
- System information (type 1).
- Baseboard.
- Chassis.
- Processor.
- Memory.

## RISC-V note

SMBIOS is architecture-neutral, so the DMI core works on RISC-V today without the
RISC-V additions the spec is still ratifying. Weir tags the processor with the
proposed RV64 family code. Recent `dmidecode` reads it, and older tools ignore
it.
