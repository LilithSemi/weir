# Serial update

The serial update mode lets a host write blocks to the boot storage over the
console UART. Use it to replace the contents of an SD card without removing the
card. The mode is off by default. Build with `-Dserial-update=true` to include
it. With the option off, the image has no update code and the boot has no delay.

The mode has no authentication. Do not enable it in a build for a secure boot.

## Entry

Before Weir looks for the block devices, Weir prints this line and polls the
UART for 1 second:

```
[update] send U to start a serial update
```

The byte `U` (0x55) starts the mode. Weir ignores other bytes and bytes that
came before the prompt, so the host can send `U` again and again until it sees
the reply. With no `U` in that second, the boot continues. On entry Weir prints
`[update] ready` and a newline. The two text lines end in CR LF. After the ready
line, Weir sends and receives frames only, with no other console text.

The mode has no idle limit. Weir stays in it until the `boot` command.

The mode starts with no block device, and no command went to a card yet. Send
`rescan` first to find the devices.

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
| 8 | write trace | SD host u8, lba u64, count u8 (1), then 512 data bytes | trace records, see below |
| 9 | read trace | SD host u8, lba u64, count u8 (0 to 8) | trace records, see below |
| 10 | SD command | SD host u8, opcode u8, response type u8 (0 none, 1 short, 2 long, 3 short with busy, 4 short with no CRC and no index), argument u32 | one trace record |
| 11 | SD register | SD host u8, offset u8, write u8 (0 or 1), value u32 | the register value u32 |
| 12 | net open | the URL text, `http://host[:port]/path` | file size u64 |
| 13 | net write | device u8, lba u64, count u8 (1 to 128) | CRC-32 u32 of the data |
| 14 | net close | none | none |

The info reply has the version u8 (1), the maximum blocks for one write u8 (8)
and the device count u8. Then for each device it has:

| Field | Size | Notes |
| --- | --- | --- |
| kind | 1 | 0 virtio, 1 SD host (sdhci), 2 SD card on SPI, 3 disk image in RAM |
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
| outcome | 1 | 0 ok, 1 controller busy before the command, 2 controller busy after it, 3 no response from the card, 4 a response with a bad CRC, end bit or index |
| count | 2 | for commands 55 and 41, the number of tries. Only the last try has records |
| INT_STATUS | 4 | the controller register after the command |
| response | 4 | the first response word (RESP0) |
| STATUS | 4 | the controller register after the command. Bit 0 is card detect |

The steps are commands 0, 8, then 55 and 41 until the card is ready (2000 tries
at most), then 2 and 3. The trace stops at the step that makes the next one
useless.

`write trace` writes one block to the card on one SD host, without the block
driver, and gives the same records. Use it when a write fails or the card stops
after a write. The steps are:

1. The controller state (opcode 0xff).
2. Command 13, the card status before the write.
3. Command 24, the write.
4. Command 13 again and again, 20000 times at most, until the card is in the
   transfer state and ready for data (response bits 12 to 9 equal to 4, and
   bit 8 set). A record follows each change of the answer, and the last poll
   always has one. The count is the number of the poll.
5. Command 17, a read of the same block.
6. Command 13, the card status after the read.
7. A record with opcode 0xfe. Its count is 1 when the data that was read is the
   data that was written. Else the response field has the offset of the first
   byte that differs.

When the card does not become ready, the trace has no read, and the last record
compares the data with zeros.

`read trace` reads blocks from the card on one SD host, without the block
driver. The steps are:

1. The controller state (opcode 0xff).
2. Command 13, the card status before the read.
3. For 1 block, command 17. For 2 to 8 blocks, command 18, then command 12.
4. Command 13, the card status after the read.
5. A record with opcode 0xfd. Its count is the number of blocks, and its
   response field is the CRC-32 of the data.

With a count of 0 the trace sends no read. It sends command 13, command 12 and
command 13. Use it after a failed transfer to see if the card still answers,
before a `rescan` or a `probe`. Those send command 0, and the traces do not.

The two traces use the card address from the last time the storage was found,
so they also work when the card stopped after that.

`SD command` sends one command with no data phase and gives its record. Use
response type 4 for a command whose response has no CRC and no command index,
such as command 41 after command 55. The host checks both for the other
types.

`SD register` reads one register of the SD host, after a write of the value
when the write byte is 1. The offset is a multiple of 8 below 0x98. The
register at 0x90 has the levels of the bus: bit 0 is the CMD line, bit 1 is
set when the host drives CMD, bits 11 to 4 are the DAT lines, and bits 23 to
16 are set for the DAT lines that the host drives.

These two are for tests of the host and the card by hand. They do not go
through the block driver, so send `rescan` before the next `write` or `crc`.

## Writes from a server

The three net commands need a board with the modem of the netboot, see
[netboot.md](netboot.md). On other boards they get status 2. With them the
host sends only a few bytes for each 64 KiB, and the data comes through the
modem.

`net open` resets the modem, connects to the server of the URL and gives the
size of the file. The server must support range requests. Weir does not keep
the URL. The reply can take 70 seconds when the modem has no network.

`net write` reads count blocks of the file through the modem and writes them
to the device at the lba. The data is the part of the file at the byte offset
lba * 512, so the file is an image of the whole device. The reply has the
CRC-32 of the data. Compare it with the CRC of the same part of the file on
the host, and use `crc` to read the blocks back from the device. A piece that
arrives with an error is read again up to 6 times, so the reply can take more
than a minute. A write that Weir does again gives the same result.

`net close` puts the modem in reset. The `boot` command does the same.

Weir prints no text for these commands. A failure gives status 6 with no
cause.

## Status codes

| Code | Meaning |
| --- | --- |
| 0 | ok |
| 1 | bad CRC |
| 2 | unknown command |
| 3 | bad argument (device, lba, count, length or baud) |
| 4 | I/O error from the device |
| 5 | the device is read only |
| 6 | the modem or the server did not give the data |

The status 4 reply to `write` and `net write` can have a payload of 8 bytes: the
interrupt status u32 of the SD host and the card status u32 (R1) after the
failure. A card status of 0xffffffff means that the card did not answer. With
no payload, the device keeps no cause.

## Baud rate

Weir sends the reply to `baud` at the old rate and waits until the transmitter
is empty. Then it changes the rate. The divisor is the UART clock divided by 16
times the baud, to the nearest integer. A divisor of 0 or over 0xffff gets
status 3, and the rate does not change. The real rate is the UART clock divided
by 16 times the divisor, so a baud that is not near such a rate does not work.

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

The Harbor UART has a receive FIFO of 16 bytes. Weir polls for each byte, and
writes to the card only after a frame is complete. The host waits for each reply before it
sends the next request.
