# SBI

Weir provides the RISC-V Supervisor Binary Interface (SBI) to the supervisor. It
runs in M-mode and answers the `ecall`s that S-mode makes. The trap handler in
`src/arch/riscv/trap.zig` routes each `ecall` to `src/sbi/sbi.zig`.

Weir reports SBI specification version 2.0. Its implementation ID is `MWRI`
("Midstall Weir").

## Extensions

| Extension | EID | Functions |
| --- | --- | --- |
| Base | `0x10` | spec version, impl ID, impl version, probe, mvendorid, marchid, mimpid |
| Timer (TIME) | `0x54494D45` | `set_timer` |
| IPI | `0x735049` | `send_ipi` |
| RFENCE | `0x52464E43` | `remote_fence_i`, `remote_sfence_vma`, `remote_sfence_vma_asid` |
| HSM | `0x48534D` | `hart_start`, `hart_stop`, `hart_get_status` |
| Debug console (DBCN) | `0x4442434E` | `console_write`, `console_read`, `console_write_byte` |
| System reset (SRST) | `0x53525354` | `system_reset` |
| Legacy | `0x01`, `0x02`, `0x08` | `console_putchar`, `console_getchar`, `shutdown` |

The Base extension reads `mvendorid`, `marchid`, and `mimpid` from the machine
CSRs, so it reports the real part identity.

## Timer

`set_timer` uses the Sstc extension when the core has it: it writes `stimecmp`
to arm the supervisor timer directly. On a minimal core without Sstc (such as
River's creek), it programs the machine timer through the CLINT and re-arms the
machine timer interrupt. The M-mode timer handler then relays the event to
S-mode as a supervisor timer interrupt.

## Console

The debug console and the legacy console share the platform UART through
`src/console/console.zig`. `console_read` and `console_getchar` are
non-blocking: they return the bytes the UART holds now, or none. This gives a
booted OS an interactive console.

## Inter-hart operations

`send_ipi` and the RFENCE functions target a set of harts through a CLINT
software-interrupt mailbox (`src/sbi/ipi.zig`). A hart fences itself directly
and never sends itself an IPI. HSM parks secondary harts in M-mode until a
`hart_start` wakes one at the entry point the caller gave.

## Not yet implemented

Weir does not yet provide PMU, SUSP, STA, CPPC, or the SBI v3 extensions (SSE,
FWFT, MPXY). The RFENCE hypervisor fences (`hfence.gvma`, `hfence.vvma`) are also
absent. `probe_extension` reports these as unsupported.
