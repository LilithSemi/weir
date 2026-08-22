# Contributing to Weir

Thank you for working on Weir. This guide covers the repository layout, where
the drivers live, the coding standards, and how to check your work.

## Code of conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By taking part, you
agree to uphold it.

## Repository layout

- `src/` - the firmware. `main.zig` orchestrates the M-mode bring-up.
- `src/fsbl/` - the first-stage boot loader (DDR bring-up and image load).
- `src/sbi/`, `src/uefi/`, `src/acpi/` - the SBI, UEFI, and ACPI providers.
- `src/arch/riscv/` - the reset vector, the trap handler, and CSR access.
- `src/console/`, `src/block/`, `src/tpm/`, ... - the firmware subsystems.
- `tools/` - build-time host tools (the linker-script generator and the image
  packer).
- `docs/` - the documentation. Start at [docs/README.md](docs/README.md).

## Drivers live in Conduit

Weir gets its device drivers from `conduit`, Midstall's hardware-abstraction
library. Weir itself holds almost no register-level driver code. It discovers
the platform from a device tree and binds conduit's drivers to the addresses it
finds.

- To add or change a device driver, work in conduit, not in Weir.
- To wire a new peripheral into Weir, add a matcher in `src/soc.zig` and bind the
  conduit driver. [docs/porting.md](docs/porting.md) walks through this.

Keep the split clean: conduit owns the register access, Weir owns the firmware
policy that uses it.

## Coding standards

### Zig style: IronStyle

Weir follows Midstall's IronStyle. The backbone rule is:

> Assert on programmer errors. Recover from runtime faults. Never assume I/O
> succeeds.

In short:

- Assert broken invariants and impossible states. Return errors for malformed
  input, protocol faults, and I/O.
- Bound every loop and allocation. Prefer no allocation on the boot path.
- Use exhaustive switches. Do not reach for `else` where the compiler could catch
  a missed case.
- Sanitize untrusted input. Use checked arithmetic and `std.enums.fromInt` for
  untrusted enum values.
- Reach for the standard library before hand-rolling. Reinvent only with a
  measured reason.

See the `ironstyle` repository for the full guide and the rationale.

### Documentation and comments: ASD-STE100

Write comments, doc comments, and documentation in ASD-STE100, the aerospace and
defence industry's Simplified Technical English standard:

- One meaning per word. Active voice. Simple present tense.
- Short sentences. One instruction per sentence.
- No em-dashes. No semicolons in prose. Plain words.
- Comment the why, not the what. A name like `openFile` needs no comment. Spend
  comments on a datasheet source, a hardware ordering, a unit, or an invariant
  the types do not capture.

### Linting: zippy

Weir lints with `zippy`, Midstall's linter for Zig. Run it in the repository
before you submit:

```
zippy
```

zippy builds the project and lints the source that actually compiles. The repo
ships a `zippy.zon` config. The `correctness` and `memory` lint groups fail the
run, so fix those before you submit. Silence a false positive at a single site
with a `// zippy:ignore <lint>` comment and a short reason, not by disabling the
lint everywhere.

## Before you submit

- `zig build` succeeds for the firmware and the FSBL.
- `zig fmt` leaves the source unchanged.
- `zippy` reports no errors.
- `zig build qemu` still boots the firmware.
- A bug fix comes with a test that fails before the fix and passes after.

## Commits

Weir uses short, imperative commit subjects with a type prefix, such as
`feat: boot on river` or `fix: uart on river`. Keep each commit focused and the
tree building.
