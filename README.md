# NVR NBD80S10S-KL Custom Linux Firmware

Custom Linux firmware for the NBD80S10S-KL NVR board based on the
SigmaStar/MStar SSR621Q (Infinity2M) SoC.

## Hardware

- **SoC**: SigmaStar SSR621Q (Dual-core ARM Cortex-A7 @ 1GHz)
- **RAM**: 256MB DDR3
- **Flash**: 16MB NOR SPI (XM25QH128C)
- **Interfaces**: Ethernet, SATA, USB 2.0, UART

## What this builds

- Linux 6.5 kernel (linux-chenxing fork)
- BusyBox 1.36.1 userspace
- Dropbear SSH server
- Two flash images for the NVR board
- A USB rootfs for persistent writable storage

## Prerequisites

```bash
sudo apt install gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
    libncurses-dev bc bison flex libssl-dev u-boot-tools \
    squashfs-tools make gcc git wget
```

## Build

```bash
./build.sh
```

Output files will be in `output/`.

## Flash layout

| Partition | Offset   | Size   | Contents                              |
| --------- | -------- | ------ | ------------------------------------- |
| ipl       | 0x000000 | 64KB   | First stage bootloader (do not touch) |
| boot      | 0x010000 | 256KB  | U-Boot                                |
| kernel    | 0x050000 | 3.9MB  | Linux kernel + DTB                    |
| rootfs    | 0x440000 | 11.8MB | BusyBox rootfs                        |

## Flashing via U-Boot TFTP

```
setenv serverip 192.168.1.X
tftpboot 0x22000000 uImage-chenxing
sf probe 0; sf lock 0
sf erase 0x50000 0x3F0000
sf write 0x22000000 0x50000 ${filesize}

tftpboot 0x22000000 user-x.squashfs.img
sf erase 0x440000 0xBC0000
sf write 0x22000000 0x440000 ${filesize}
```

## Single line command for U-Boot console
```
setenv serverip 192.168.1.X;tftpboot 0x22000000 uImage-chenxing;sf probe 0; sf lock 0;sf erase 0x50000 0x3F0000;sf write 0x22000000 0x50000 ${filesize};tftpboot 0x22000000 user-x.squashfs.img;sf erase 0x440000 0xBC0000;sf write 0x22000000 0x440000 ${filesize};run loadromfs
```

## Boot behaviour

- **No USB drive**: boots from flash (read-only)
- **USB drive with valid rootfs**: automatically pivots to USB (writable)

## Setting up USB boot drive

```bash
sudo mkfs.ext4 -F /dev/sdX1
sudo mount /dev/sdX1 /mnt
sudo cp -a output/usb-rootfs/* /mnt/
sudo chown -R root:root /mnt/root
sudo umount /mnt
```

## SSH access

Dropbear is configured for **password authentication**. The default `root` password
is empty — set one by editing `rootfs-overlay/etc/shadow` before building (replace
the empty hash field with a crypt hash), or run `passwd root` on the device after
first boot.

SSH host keys are generated automatically on first boot and stored in `/tmp/dropbear/`
(lost on reboot — clients will see a new host key each time unless you persist them
to a writable volume).

## Credits

- [linux-chenxing](https://github.com/linux-chenxing/linux) - kernel support
- [Discussion #85](https://github.com/linux-chenxing/linux-chenxing.org/discussions/85) - NVR board research
