# Measured boot

Weir measures the boot chain into a TPM 2.0. Each stage hashes the next into a
Platform Configuration Register (PCR) before it runs it, and it records the hash
in an event log. The operating system reads the PCRs and the log, so it can
attest to what ran before it. The code lives in `src/tpm/`.

## PCR layout

| PCR | Contents |
| --- | --- |
| 0 | the firmware, and the FSBL stage |
| 4 | the boot loader, its image, and the initramfs |
| 5 | the boot configuration, such as the boot path |
| 16 | a resettable debug PCR, used by the self-test |

## The chain

1. **Firmware into PCR 0.** If the FSBL already measured the main firmware, it
   passes the digest forward, and Weir records that digest in the log. If not,
   Weir hashes itself into PCR 0.
2. **Boot loader into PCR 4.** The boot manager hashes the boot path into PCR 5,
   then the loaded PE image, and the initramfs, into PCR 4.
3. **The loaded boot loader continues the chain.** It measures what it loads next
   through the UEFI TCG2 protocol, which Weir provides.

Each measurement extends its PCR and appends an event to the log. An extend
folds the new hash into the PCR, so a PCR value depends on every measurement in
order. A change anywhere in the chain changes the final PCR value.

## The TPM interface

Weir talks to the TPM 2.0 over the TIS (TPM Interface Specification) MMIO
interface (`src/tpm/tis.zig`), through a small TPM 2.0 command layer
(`src/tpm/tpm2.zig`). The device tree gives the TIS base address with a
`tcg,tpm-tis-mmio` node.

## The event log

The log is a TCG event log in the SHA-256 bank. A Spec ID Event opens it, then
each measurement adds a `TCG_PCR_EVENT2` entry. The operating system finds the
log through the ACPI TPM2 table, so a change of address needs no OS change.

QEMU's RISC-V ACPI omits the TPM2 table, so Weir synthesizes one when a TPM is
present.

## No TPM

When the platform description has no TPM, Weir disables measured boot and reports
it on the console. The boot continues without a measurement chain.
