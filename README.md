# NVR NBD80S10S-KL — OpenIPC Ground Station Firmware

Custom firmware that turns a XiongMai NBD80S10S-KL NVR board into a wireless FPV
ground station: it receives video from an OpenIPC air unit, decodes it in
hardware, and puts it on the HDMI output.

**Status: working.** Boots standalone from flash, no PC required.

## Hardware

| | |
| --- | --- |
| SoC | SigmaStar SSR621Q (MStar Infinity2M), dual Cortex-A7 @ 1 GHz |
| RAM | 256 MB DDR3 |
| Flash | 16 MB NOR SPI (XM25QH128C) |
| VPU | Chips&Media Wave511 (H.264 / H.265 decode) |
| Board ID | `INFINITY2M SSC010A-S01A-S` |
| Wi-Fi | RTL8812AU over USB (must use the port that enumerates as `Sstar-ehci-3`) |

## What it does

```
RTL8812AU ──► wpa_supplicant ──► DHCP ──► RTSP client ──► MI_VDEC (Wave511)
                                                              │
                                            HDMI ◄── MI_DISP ◄┴─ MI_DIVP
```

- Associates to the air unit's access point, then pulls its RTSP stream
- Hardware-decodes H.264 or H.265 — codec is taken from the SDP, not guessed
- Composites onto the HDMI video plane at 1080p60
- Fully event-driven: the player starts on the DHCP lease and stops on link
  loss, with a splash screen in between. No polling, no fixed delays.
- Reconnects by itself if the air unit reboots or drifts out of range

## Building

```bash
./fetch-deps.sh     # SDK, toolchain, BusyBox, driver source, and vendor blobs
./build-sdk.sh      # kernel + initramfs + MI stack + players
```

Output is `output/uImage-sdk` — a single ~11 MB uImage with the kernel and an
embedded initramfs. The script prints the exact flashing commands for the image
it just built, and fails if the image would no longer fit in flash.

> **You need a dump of your own board's flash.** The XiongMai kernel modules,
> the `/config` panel timing tables and the stock libraries are proprietary and
> are not redistributed here. `fetch-deps.sh` carves them out of a 16 MB dump
> placed at `NBD80S10S-KL_original.bin` in the repository root (or passed as an
> argument). You want that dump anyway — it is the only route back to stock.
>
> Read one off the board from U-Boot with
> `sf probe 0; sf read 0x21000000 0 0x1000000`, or from a running Linux with the
> whole chip exposed via `mtdparts=NOR_FLASH:16m(whole)` and
> `nc <pc> 1234 < /dev/mtd0`.

If you keep the dump in a private repository, point the build at it once and
`fetch-deps.sh` will clone it for you:

```bash
echo 'git@github.com:you/your-vendor-repo.git' > .vendor-repo   # gitignored
```

Any 16 MB `.bin` at the top of that repo is used, so it can keep a
board-specific name. `VENDOR_REPO=` and `VENDOR_DUMP=` work as one-off
environment overrides.

The modules are not visible in the extracted squashfs trees: they live inside
`usr` as `lib/modules.tar.lzma`, which `fetch-deps.sh` unpacks.

Useful variables:

| | |
| --- | --- |
| `MI_SETS="xm"` | Which MI module sets to ship. Default `xm`, the only set that both decodes and drives HDMI. Use `MI_SETS="xm alkaid"` to bisect driver problems again. |
| `FALLBACK_MAC=` | Pin the fallback MAC instead of generating a random one, for reproducible builds. |

`build-wfb.sh` builds the wfb-ng binaries and `build-apfpv.sh` the Wi-Fi client
pieces; `build-sdk.sh` picks up their output automatically if present.

## Continuous integration

`.github/workflows/build.yml` cross-compiles every source file for ARM against
MI headers sparse-checked-out from the public SDK repository, and syntax-checks
the shell scripts. It deliberately does **not** build an image: that needs the
vendor blobs, and publishing those would mean redistributing XiongMai's
binaries.

## Flashing

The stock layout, read from the vendor dump and confirmed by the stock
`bootargs`:

| Offset | Size | Contents | |
| --- | --- | --- | --- |
| `0x000000` | 64 K | IPL + IPL_CUST | keep |
| `0x010000` | 192 K | U-Boot | keep |
| `0x040000` | 64 K | U-Boot environment | keep — `saveenv` writes here |
| `0x050000` | 15.7 M | stock kernel + rootfs | **replaced by our image** |

> **`sf lock 0` is mandatory.** The flash ships with block protection armed —
> U-Boot prints `lk=>6, 0x800000`, meaning the lower 8 MB is write protected.
> SPI flash silently ignores erase and program to protected sectors, so
> `sf erase` and `sf write` both report `OK` while nothing is written. Despite
> the name, `sf lock 0` sets lock *level 0*, i.e. unlocks everything.

```
tftpboot 0x21000000 uImage-sdk
sf probe 0
sf lock 0
sf erase 0x50000 0xb00000
sf write 0x21000000 0x50000 ${filesize}
```

Verify before making it permanent — this reads back from flash rather than
trusting the copy still in RAM:

```
sf read 0x21000000 0x50000 0xb00000
bootm 0x21000000
```

Then:

```
setenv bootargs 'console=ttyS0,115200 LX_MEM=0xFF00000 mma_heap=mma_heap_name0,miu=0,sz=0x6e00000 mma_memblock_remove=1 ethaddr=${ethaddr} mi_set=xm vdec_test=1 vdec_test_rtsp=1 vdec_test_src=1920x1080'
setenv setargs 'setenv bootargs ${bootargs}'
setenv bootcmd 'run setargs;gpio output 25 1;sf probe 0;sf read 0x21000000 0x50000 0xb00000;bootm 0x21000000'
setenv bootdelay 3
saveenv
```

`run setargs` is what expands `${ethaddr}` — plain `bootm` does not substitute
U-Boot variables, which is why the stock `bootcmd` used the same indirection.
The board's real MAC therefore comes from its own U-Boot environment and no
address is baked into the image; if it is missing, the firmware falls back to a
locally administered address generated at build time.

`gpio output 25 1` is the first thing the stock `bootcmd` does. Its purpose is
undocumented, so it is kept. `bootdelay 3` replaces the stock `0`, which is why
the prompt used to be nearly impossible to catch.

## Kernel command line options

| Option | Meaning |
| --- | --- |
| `mi_set=xm\|sdk\|alkaid` | MI module set. Default `xm`. Sets cannot be swapped at runtime — the modules oops on `rmmod`. |
| `vdec_test=1` | Start the player from init instead of dropping to a shell |
| `vdec_test_rtsp=1` | Pull RTSP from the DHCP gateway using OpenIPC defaults |
| `vdec_test_rtsp=URL` | Explicit `rtsp://user:pass@host:port/path` |
| `vdec_test_file=1` | Decode the bundled clip instead — no network, no RTP |
| `vdec_test_src=WxH` | Source resolution hint (default `1280x720`) |
| `vdec_test_probe=1` | Dump the VPU bitstream buffer and the driver-side ES |
| `vdec_test_log=N` | `mi_vdec` log level |
| `apfpv=off` | Do not start the Wi-Fi client |
| `apfpv_ssid=`, `apfpv_psk=` | Air unit credentials (default `OpenIPC` / `12345678`) |
| `disp=720\|off` | Display mode |

## On the device

| | |
| --- | --- |
| `fpv-start` / `fpv-stop` | Start or stop the player by hand |
| `fpv-probe [ip]` | Identify a camera's stream: port scan plus RTSP `DESCRIBE` |
| `load-mi <set>` | Insert an MI module set |
| `load-wifi` | Load the RTL8812AU driver |
| `apfpv <ssid> <psk>` | Associate to an access point |
| `wfb-nics` | List RTL88xx interfaces |
| `mi-player` | The player; `-h` for options |

**UART RX does not work under Linux** (TX only) — the SigmaStar serial driver
never delivers input. U-Boot's RX is fine. Telnet and SSH are the only
interactive shells.

### Finding the board

`eth0` uses DHCP and sends the hostname `nvr-gs`, so it shows up under that
name in the router's client list. The address is also printed on the serial
console when the lease arrives and displayed on the HDMI overlay. With no DHCP
server on the link it falls back to `192.168.1.10`.

Pass `ipaddr=A.B.C.D` on the kernel command line for a fixed address instead.
If you do, keep it outside the router's DHCP pool — otherwise the pool can
lease that same address to another device while the board is off, and telnet
then reaches the wrong host.

The MAC comes from U-Boot's `ethaddr`, which only reaches the kernel if bootargs
are built *inside* `setargs` (U-Boot expands `${}` one level only). Without it
the board uses the locally administered address cached in `.fallback-mac`.

## Air unit

Tested against OpenIPC/majestic, which answers `DESCRIBE` with
`Server: OpenIPC.org RTSP Server/0.1` and Basic auth, streaming H.265 at
payload type 97. Default credentials are `root` / `12345`.

Majestic sends nothing until a client completes `DESCRIBE` → `SETUP` → `PLAY`,
which is why a bare UDP listener stays silent and `mi-player` implements a small
RTSP client. Alternatively, point majestic's `outgoing.server` at the board and
use `mi-player -u 5600`.

## Gotchas worth knowing

- **Test streams must be 8-bit 4:2:0.** `videotestsrc ! x264enc` with no
  `format=` in the caps negotiates **10-bit 4:4:4** (`profile_idc 244`), which
  no hardware decoder will touch. The decoder reports this as
  `not found sps` — meaning no *usable* SPS, not a missing one. Always pin
  `video/x-raw,format=I420` and a `video/x-h264,profile=main` filter.
- **The VPU firmware is a file**, loaded from `/config/vdec_fw/` at runtime and
  versioned with the driver. `load-mi` installs each set's own copy before
  `insmod`. `fwVersion` in `/proc/mi_modules/mi_vdec/mi_vdec0` confirms which.
- **The OSD sits above the video plane** at constant alpha 255, so the splash
  hides decoded frames until the framebuffer is cleared.
- **`/tmp` is RAM.** It is capped at 8 MB; unbounded writes previously triggered
  the OOM killer and took telnet with them.
- **MI modules cannot be unloaded.** `rmmod` oopses the kernel; choose the set
  at boot instead.

## Repository layout

```
fetch-deps.sh       download the public prerequisites into build/
build-sdk.sh        main build: kernel, initramfs, MI stack, players
build-wfb.sh        wfb-ng binaries
build-apfpv.sh      wpa_supplicant and Wi-Fi client pieces
src/mi-player.c     RTSP/UDP/file -> MI_VDEC -> MI_DIVP -> MI_DISP -> HDMI
src/mi-disp-init.c  display and HDMI bring-up, raw MI_HDMI ioctls
src/fb-splash.c     framebuffer splash and status overlay
src/wifi-monitor.c  monitor mode and sniffing, no external dependencies
assets/test720.h264 720p Baseline 4:2:0 clip for decoding without a network
config/             BusyBox and kernel configuration
patches/            device tree and platform patches
```

Regenerate the test clip with:

```bash
gst-launch-1.0 videotestsrc num-buffers=90 pattern=ball ! \
  video/x-raw,format=I420,width=1280,height=720,framerate=30/1 ! \
  x264enc tune=zerolatency speed-preset=ultrafast key-int-max=15 bitrate=3000 ! \
  video/x-h264,stream-format=byte-stream,alignment=au,profile=main ! \
  filesink location=assets/test720.h264
```

## Recovery

Nothing in the flashing procedure touches `0x0`–`0x50000`, so U-Boot and its
environment survive even a failed write, and TFTP boot always remains available.

Full restore to stock, if you kept the 16 MB dump:

```
tftpboot 0x21000000 NBD80S10S-KL_original.bin
sf probe 0
sf lock 0
sf erase 0 0x1000000
sf write 0x21000000 0 0x1000000
```

The only unrecoverable failure is corrupting the bootloader itself, which needs
a SPI flash programmer.

## Legacy

`build.sh`, `usb-rootfs/`, `rootfs-overlay/` and `.github/workflows/build.yml`
belong to an earlier attempt using the linux-chenxing 6.5 kernel. That track was
abandoned: mainline has no display or VPU support for Infinity2M, so HDMI is
dead there. They are kept for reference only and are not built by
`build-sdk.sh`.

## Credits

- [linux-chenxing](https://github.com/linux-chenxing/linux) — Infinity2M research
- [Discussion #85](https://github.com/linux-chenxing/linux-chenxing.org/discussions/85) — NVR board teardown
- [OpenIPC](https://openipc.org/) — air unit firmware and wfb-ng
- [industio/PurPle-Pi-R1](https://github.com/industio/PurPle-Pi-R1) — Alkaid SDK drop used during driver debugging
