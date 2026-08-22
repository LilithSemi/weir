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
- XSDT, which lists the FADT.
- FADT, hardware-reduced, whose `X_DSDT` points at the DSDT.

The DSDT is the raw AML blob the board supplies with `-Daml`. Weir references it
in place. It does not generate AML.

## TPM

When the platform has a TPM and the ACPI table set has no TPM2 table, Weir
synthesizes one and points it at the TCG event log. So the OS finds the log and
can extend the measured-boot chain Weir started.

## Identity

Weir stamps the tables with the OEM ID `MIDSTL` and the OEM table ID `WEIR`.
