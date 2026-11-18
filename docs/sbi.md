# SBI

Weir provides the RISC-V Supervisor Binary Interface (SBI) to the supervisor. It
runs in M-mode and answers the `ecall`s that S-mode makes. The trap handler in
`src/arch/riscv/trap.zig` routes each `ecall` to `src/sbi/sbi.zig`.

Weir reports SBI specification version 2.0. Its implementation ID is `MWRI`
("Lilith Semiconductor Weir").

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
| Variables | `0x0A575249` | `call` |
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

## Variables

The variables extension (EID `0x0A575249`) has one function, `call` (FID 0). It
runs an EFI variable request on the variable store in M-mode. The UEFI runtime
stubs make this call. See [uefi.md](uefi.md#runtime-access).

The one argument is the address of the request block. M-mode accepts only the
address of Weir's own request block, which lies in the EFI runtime data region.
The call returns one of these SBI values:

| Value | Meaning |
| --- | --- |
| Success | M-mode ran the request. The `status` field holds the result |
| `SBI_ERR_INVALID_ADDRESS` | The address is not the request block |
| `SBI_ERR_NOT_SUPPORTED` | The board has no variable store |
| `SBI_ERR_DENIED` | Another call is running |

`probe_extension` reports the extension only when the board has a store.

The request block is the `Request` struct in `src/var/rt_abi.zig`. S-mode and
M-mode share this layout.

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `op` | 1 get, 2 set, 3 next, 4 query, 5 seal |
| 4 | `status` | The result. 0 success, 1 not found, 2 buffer too small, 3 invalid, 4 out of resources, 5 device error |
| 8 | `attributes` | The variable attributes |
| 16 | `data_size` | The size of `data` in bytes |
| 24 | `name_size` | The size of `name` in bytes, with the terminator |
| 32 | `max_storage` | The query result: the total storage |
| 40 | `remaining` | The query result: the free storage |
| 48 | `max_var` | The query result: the largest variable |
| 56 | `guid` | The vendor GUID, 16 bytes |
| 72 | `name` | The name, 256 UTF-16 units at most |
| 584 | `data` | The variable data, 32 KiB at most |

The `seal` operation applies the store rules for the time after
`ExitBootServices`. `ExitBootServices` makes this request.

## System reset

`system_reset` accepts the types shutdown (0), cold reboot (1) and warm reboot
(2). The two reboot types do the same thing. Another type gives
`SBI_ERR_INVALID_PARAM`. The legacy `shutdown` call does a shutdown. The EFI
`ResetSystem` service makes this call.

Weir prints the type and the reason of each call, for example
`[weir] srst: type=cold reason=0`, and sends the line before the reset.

Weir uses the reset device of the device tree when the tree has one. See
[device-tree.md](device-tree.md#reset-and-power).

For a reboot on a board with no reset device, Weir starts each hart again at the
start of the boot ROM, with interrupts off and `satp` clear. The boot ROM then
loads the firmware again. This does not reset the devices, so the boot code
must set up each device that it uses. A tree with no boot ROM node gives no
reboot: Weir prints a line and stops the harts.

For a shutdown on a board with no power device, Weir prints a line and stops
the harts. The board stays on.

## Not yet implemented

Weir does not yet provide PMU, SUSP, STA, CPPC, or the SBI v3 extensions (SSE,
FWFT, MPXY). The RFENCE hypervisor fences (`hfence.gvma`, `hfence.vvma`) are also
absent. `probe_extension` reports these as unsupported.
