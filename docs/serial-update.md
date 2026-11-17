# Serial update

The serial update mode lets a host write blocks to the boot storage over the
console UART. Use it to replace the contents of an SD card without removing the
card. The mode is off by default. Build with `-Dserial-update=true` to include
it. With the option off, the image has no update code and the boot has no delay.

The mode has no authentication. Do not enable it in a build for a secure boot.

## Entry

After Weir finds the block devices and before the boot manager starts, Weir
prints this line and polls the UART for 1 second:

```
[update] send U to start a serial update
```

The byte `U` (0x55) starts the mode. Weir ignores other bytes and bytes that
came before the prompt, so the host can send `U` again and again until it sees
the reply. With no `U` in that second, the boot continues. On entry Weir prints
`[update] ready` and a newline. The two text lines end in CR LF. After the ready
line, Weir sends and receives frames only, with no other console text.

The mode has no idle limit. Weir stays in it until the `boot` command.

## Frames

Requests and replies use the same layout. All integers are little-endian.

| Field | Size | Notes |
| --- | --- | --- |
| magic | 2 | request `57 55` ("WU"), reply `77 75` ("wu") |
| code | 1 | request: the command. reply: the status |
| seq | 1 | the reply copies the value from the request |
| len | 2 | payload bytes, 4112 at most |
| payload | len | |
| crc | 4 | CRC-32 (IEEE, the same as zlib) of code, seq, len and payload |

Weir drops a frame when a gap between two bytes is over 500 ms, when len is over
4112, or when the CRC is wrong. For a wrong CRC, Weir replies with status 1 and
the seq from the frame. For the other cases Weir sends no reply and looks for the
magic again.

The host sends one request and waits for its reply. A write that Weir does again
gives the same result, so the host can send a request again after a timeout.

Two rules keep the host and Weir in step after an error:

- The host drops a reply whose seq is not the seq of its request.
- After a timeout, the host sends nothing for more than 500 ms, then sends the
  request again. Weir then looks for the magic from a clean start.

## Commands

| Code | Name | Request payload | Reply payload |
| --- | --- | --- | --- |
| 0 | ping | none | none |
| 1 | info | none | see below |
| 2 | write | device u8, lba u64, count u8 (1 to 8), then count * 512 data bytes | none |
| 3 | crc | device u8, lba u64, count u32 (1 to 2048) | CRC-32 u32 of the blocks |
| 4 | baud | baud u32 | none, sent at the old rate |
| 5 | boot | none | none |
| 6 | rescan | none | device count u8 |
| 7 | probe | SD host u8 | trace records, see below |

The info reply has the version u8 (1), the maximum blocks for one write u8 (8)
and the device count u8. Then for each device it has:

| Field | Size | Notes |
| --- | --- | --- |
| kind | 1 | 0 virtio, 1 SD host (sdhci), 2 SD card on SPI |
| writable | 1 | 1 when the device accepts writes |
| block size | 4 | bytes |
| block count | 8 | |

The device number in write and crc is the index in the info list. The list has
the same order as the boot manager uses. Write and crc accept only devices with
512 byte blocks.

After the reply to `boot`, Weir leaves the mode and starts the boot manager. The
boot then uses the new contents of the card. No reset command exists.

`rescan` finds the block devices again, as at boot. Send `info` after it,
because the device list can change.

`probe` sends the SD identification commands to one SD host (the index is the
order of the hosts in the device tree) and gives one 16 byte record for each
step. Use it when the card is not found. The card is in the identification
state after a probe, so send `rescan` before the next `write` or `crc`.

| Field | Size | Notes |
| --- | --- | --- |
| opcode | 1 | the SD command index. 0xff is the first record, the controller state before the first command |
| outcome | 1 | 0 ok, 1 controller busy before the command, 2 controller busy after it, 3 no response from the card |
| count | 2 | for commands 55 and 41, the number of tries. Only the last try has records |
| INT_STATUS | 4 | the controller register after the command |
| response | 4 | the first response word (RESP0) |
| STATUS | 4 | the controller register after the command. Bit 0 is card detect |

The steps are commands 0, 8, then 55 and 41 until the card is ready (2000 tries
at most), then 2 and 3. The trace stops at the step that makes the next one
useless.

## Status codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | bad CRC |
| 2 | unknown command |
| 3 | bad argument (device, lba, count, length or baud) |
| 4 | I/O error from the device |
| 5 | the device is read only |

## Baud rate

Weir sends the reply to `baud` at the old rate and waits until the transmitter
is empty. Then it changes the rate. The divisor is the UART clock divided by the
baud. A divisor of 0 or over 0xffff gets status 3, and the rate does not change.

After the change, the host must send a ping at the new rate within 2 seconds and
receive the reply. If no ping arrives in that time, Weir goes back to 115200.
Other frames in that time get no reply.

Weir sends the reply to `boot` at the current rate, then goes back to 115200 for
the rest of the boot.

Each write of a block must be checked. After the writes, read the CRC of the
same blocks with `crc` and compare it with the CRC of the data on the host.

## Limits

The virtio-blk driver has no write path, so on QEMU a write gets status 5. The
crc command works on QEMU.

The Harbor UART has no receive FIFO. Weir polls for each byte, and writes to the
card only after a frame is complete. The host waits for each reply before it
sends the next request.
