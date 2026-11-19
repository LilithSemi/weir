# Netboot

Weir can read one disk image from an HTTP server and boot from it. The link is
an ESP32 with the AT command firmware on a UART. Use it for a board that has no
other boot source.

The netboot is in the image only when the two conditions that follow are true:

- The device tree has a node with the compatible `espressif,esp-at`. See
  [device-tree.md](device-tree.md#netboot-modem).
- The build has a URL (`-Dnetboot-url`).

The netboot has no authentication and no encryption. Each machine on the
network can give Weir an image. Do not use it in a build for a secure boot.

The netboot gives the OS no network device.

## Build options

| Option | Meaning |
| --- | --- |
| `-Dnetboot-url=URL` | The disk image, as `http://host[:port]/path`. The host is an address or a name that the module can resolve. |
| `-Dnetboot-baud=RATE` | The baud rate to the module while Weir reads the image. The default is 115200. |
| `-Dnetboot-first` | Do the netboot before Weir looks at the block devices of the board. |

The UART sends at its clock divided by 16 and by a divisor, so use a rate that
this gives, such as 781250 for a clock of 50 MHz.

## The WiFi network

Weir has no WiFi name and no password. The module joins the network that is in
its flash. Store it one time with a terminal on the module:

```
AT+CWMODE_DEF=1
AT+CWJAP_DEF="name","password"
```

## The image

The image is a disk: a GPT with an EFI system partition, as on an SD card. Weir
keeps it in RAM and the boot manager uses it as a block device. See
[boot-flow.md](boot-flow.md).

The image is at the top of RAM. It must fit between the end of the buffer that
the boot manager reads files into and the end of RAM. A board with less than
128 MiB of RAM has no netboot.

The memory map gives the image as boot services data, so the OS gets that
memory. An OS that boots from the image must have its root file system in an
initrd.

## The server

The server must accept range requests and answer with status 206. Weir reads
the image in pieces of 64 KiB, one request for each piece. The first request is
for one byte, to get the size of the image.

## Flow

1. Weir holds the module in reset for 350 ms, then waits 5 seconds for the
   `ready` line.
2. Weir turns off the echo, selects one connection and sets the baud rate.
3. Weir opens a TCP connection to the server. It tries for 30 seconds, because
   the module needs time to join the network.
4. Weir reads the image. A line shows each megabyte.
5. Weir puts the module in reset again.

Without `-Dnetboot-first`, these steps occur only when no block device has a
bootable image. When a step fails, Weir prints the cause and the boot continues
with the next boot source.

## Lost bytes

The UART has no flow control. Weir reads the overrun bit of the UART with each
byte and counts the bytes of each piece. When a piece is not complete, Weir
closes the connection and asks for the piece again, 6 times at most. The line
`[net] N pieces came again` shows the number. A high number means that the
baud rate is too high.
