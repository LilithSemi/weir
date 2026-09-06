# ACPI

Weir gives the OS ACPI tables so it can enumerate the platform without a device
tree. The OS finds the tables through the ACPI RSDP in the UEFI configuration
table. The code lives in `src/acpi/`, and it builds the tables with `almanac`,
conduit's ACPI table builder.

Weir uses the hardware-reduced ACPI model, which fits a RISC-V platform.

## Two sources

Weir builds ACPI tables one of two ways, depending on the platform.

**On QEMU**, Weir reads the tables QEMU already prepared. It runs QEMU's fw_cfg
table-loader (`src/acpi/qemu.zig`), which lays QEMU's DSDT, FADT, MADT, and RHCT
into memory and links them. These match the emulated machine exactly.

**On real hardware**, Weir builds the tables itself (`src/acpi/acpi.zig`). It
lays a minimum set into a static buffer and stamps every checksum:

- RSDP, which points at the XSDT.
- XSDT, which lists the FADT, the MADT, the RHCT and the SPCR.
- FADT, hardware-reduced, whose `X_DSDT` points at the DSDT. It claims ACPI 6.6,
  the first revision that defines the RISC-V MADT structures below.
- MADT, one RINTC per hart plus the PLIC structure.
- RHCT, the hart timebase, ISA string and MMU type.
- SPCR, the 16550 console.

## Interrupts

On the ACPI path the OS gets the PLIC's GSI base, source count, register window
and context map from the MADT, not from the DSDT. So the MADT must agree with
the hardware. Weir reads the values from the device tree (`src/soc.zig`): the
PLIC node's `reg` and `riscv,ndev`, and its `interrupts-extended`, which lists
the PLIC contexts in context order.

Each hart gets exactly one RINTC. Its external interrupt controller ID names the
PLIC context that drives that hart's **supervisor** external interrupt, because
the OS runs in S-mode. Weir keeps the machine context of the same hart for
itself. A second RINTC for one hart would make the OS see a CPU that does not
exist.

The PLIC's GSI base in the MADT must equal the `_GSB` of the PLIC device in the
DSDT. The OS matches the two to attach the MADT record to the DSDT device. A
DSDT whose PLIC device has no `_GSB` breaks that link, and then the OS never
probes the PLIC.

The CLINT has no ACPI interrupt binding on purpose. Weir owns it in M-mode and
gives the OS its timer through SBI.

The DSDT is the raw AML blob the board supplies with `-Daml`. Weir references it
in place. It does not generate AML.

## TPM

When the platform has a TPM and the ACPI table set has no TPM2 table, Weir
synthesizes one and points it at the TCG event log. So the OS finds the log and
can extend the measured-boot chain Weir started.

## Identity

Weir stamps the tables with the OEM ID `MIDSTL` and the OEM table ID `WEIR`.
