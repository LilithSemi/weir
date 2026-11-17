# SMBIOS

Weir publishes SMBIOS (DMI) tables so the OS can report the board identity. The
code lives in `src/smbios/`.

Weir builds a small SMBIOS 3.6 structure table behind a 64-bit (SMBIOS 3)
entry point. The OS finds the entry point through the SMBIOS3 GUID in the UEFI configuration table.
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
- OEM strings (type 11), when the board file names an FPGA part.

## Board identity

Weir assembles the structure table at compile time. The board identity comes
from a zon file. Harbor writes this file next to the device tree, and you pass
it with `-Dboard-info`:

```
zig build -Ddtb=board.dtb -Dboard-info=board.board.zon
```

Every field is optional. Without the file, Weir uses its defaults and the
`model` of the device tree root.

| Field | SMBIOS use |
| --- | --- |
| `vendor` | Manufacturer in types 1, 2, 3 and 17. Types 0 and 4 always name Lilith Semiconductor, the maker of the firmware and the core. |
| `product` | Product name in type 1, and in type 2 when `board` is not set. |
| `family`, `version`, `sku` | Type 1. |
| `chassis_type` | Type 3, for example `.desktop` or `.embedded_pc`. |
| `cpu` | Type 4: `model`, `isa`, `harts`, `clock_hz`. An empty `model` uses the `model` of the device tree CPU node. |
| `memory` | One type 17 for each entry: `type`, `form_factor`, `width_bits`, and `size_bytes` or `max_size_bytes`. |
| `board` | `preset` is the type 2 product. `fpga_part` goes in a type 11 OEM string. |

A soldered memory gives `size_bytes`. A socketed memory gives `max_size_bytes`,
and Weir reports the RAM size it finds at boot as the module size. Only one
memory can take its size from boot.

The serial number and the UUID are different for each unit, so they are not in
the file. When the device tree has a `harbor,unit-id` node and the block has a
valid ID, the type 1 serial number is the ID as 16 hexadecimal digits. The UUID
is then `72696557-HHHH-8000-8000-LLLLLLLLLLLL`, where `HHHH` is the high 16
bits of the ID and `LLLLLLLLLLLL` is the low 48 bits. Without an ID, the serial
number is 16 zeros and the UUID is a fixed value.

## RISC-V note

SMBIOS is architecture-neutral, so the DMI core works on RISC-V today without the
RISC-V additions the spec is still ratifying. Weir tags the processor with the
proposed RV64 family code. Recent `dmidecode` reads it, and older tools ignore
it.
