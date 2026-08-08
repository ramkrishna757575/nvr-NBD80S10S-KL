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
./fetch-deps.sh         # SDK, toolchain, driver source, and vendor blobs
./build-buildroot.sh    # kernel + rootfs + MI stack + players
```

Output is `output/uImage` — a single ~9 MB uImage with the kernel and an
embedded initramfs, plus `output/uImage.sig` beside it. The build fails if the
image would no longer fit in the `system` partition.

The rootfs is [buildroot](https://buildroot.org/) 2025.02.x, pinned by
`BUILDROOT_REF` and cloned into `build/buildroot` on first run. Everything the
image contains is described by
[`buildroot-ext/configs/ssr621q_fpv_defconfig`](buildroot-ext/configs/ssr621q_fpv_defconfig)
and the packages under [`buildroot-ext/package/`](buildroot-ext/package). The
kernel is still the vendor SigmaStar 4.9.84 tree, handed to buildroot through
`LINUX_OVERRIDE_SRCDIR` so it is only ever read from, never modified in place.

> **The proprietary bits are in `vendor/`.** The XiongMai MI kernel modules, the
> stock `/config` panel timing tables and the uClibc runtime `config_tool` needs
> are committed there, so a plain clone builds a working image — the same
> approach [OpenIPC](https://github.com/OpenIPC/firmware) takes with its
> SigmaStar blobs. See [vendor/README.md](vendor/README.md) for provenance.
>
> They are read off a retail board's read-only factory partitions and contain
> nothing unit-specific: no MAC, no serial, no keys. If you would rather trust
> your own board, put a 16 MB dump at `NBD80S10S-KL_original.bin` (or pass it as
> an argument, or point `.vendor-repo` at a private repo holding it) and
> `fetch-deps.sh` will extract them instead. You want that dump anyway — it is
> the only route back to stock.
>
> Read one off the board from U-Boot with
> `sf probe 0; sf read 0x21000000 0 0x1000000`, or from a running Linux with the
> whole chip exposed via `mtdparts=NOR_FLASH:16m(whole)` and
> `nc <pc> 1234 < /dev/mtd0`.

### Prebuilt images

The **Full image** workflow builds a flashable `uImage` and attaches it to
the run as an artifact, on every push to `master` and on demand from the Actions
tab. Artifacts are kept 30 days.

No private key is baked into a published image — SSH host keys are generated on
the board's first boot and kept in flash. Root's password is the documented
default, set by `BR2_TARGET_GENERIC_ROOT_PASSWD` in the defconfig.

The modules are not visible in the extracted squashfs trees: they live inside
`usr` as `lib/modules.tar.lzma`, which `fetch-deps.sh` unpacks.

Useful variables:

| | |
| --- | --- |
| `JOBS=` | Parallel build jobs. Defaults to the host CPU count. |
| `BUILDROOT_REF=` | Buildroot branch or tag to clone. Default `2025.02.x`. |
| `NVR_SIGNING_KEY=` | Ed25519 private key to sign with. Default `~/.config/nvr-signing/signing.key`; signing is skipped if it is absent. |

## Continuous integration

`.github/workflows/build.yml` runs two jobs.

`validate` cross-compiles every source file for ARM against MI headers
sparse-checked-out from the public SDK repository, and syntax-checks the shell
scripts — including every script in the rootfs overlay, which is checked under
both `dash` and `busybox sh` because that is what runs them on the board.

`firmware` builds a complete flashable image and publishes it to the `latest`
release, on every push to `master` and on demand. It runs the vendor blobs from
`vendor/`, the same approach OpenIPC takes with its SigmaStar binaries, so no
flash dump is needed. Only the newest run per branch survives — every run
recreates the `latest` tag, so concurrent runs would otherwise race and the
slower one would win.

There is no nightly cron. Every dependency is pinned to a commit or a version,
so rebuilding unchanged inputs produces the same image; this repository changing
is the only thing that can change the output.

## Flashing

The stock layout, read from the vendor dump and confirmed by the stock
`bootargs`:

| Offset | Size | Contents | |
| --- | --- | --- | --- |
| `0x000000` | 64 K | IPL + IPL_CUST | keep |
| `0x010000` | 192 K | U-Boot | keep |
| `0x040000` | 64 K | U-Boot environment | keep — `saveenv` writes here |
| `0x050000` | 11.2 M | stock kernel + rootfs | **replaced by our image** |
| `0xf80000` | 512 K | `cfg`, JFFS2 | settings and SSH host keys — survives reflash |

> **`sf lock 0` is mandatory.** The flash ships with block protection armed —
> U-Boot prints `lk=>6, 0x800000`, meaning the lower 8 MB is write protected.
> SPI flash silently ignores erase and program to protected sectors, so
> `sf erase` and `sf write` both report `OK` while nothing is written. Despite
> the name, `sf lock 0` sets lock *level 0*, i.e. unlocks everything.

```
tftpboot 0x21000000 uImage
sf probe 0
sf lock 0
sf erase 0x50000 0x8e0000
sf write 0x21000000 0x50000 ${filesize}
```

The erase length must cover the image and be a whole number of 64 K sectors;
`0x8e0000` is enough for a ~9 MB image. Erasing the whole `0xb30000` partition
also works and only costs time.

Verify before making it permanent — this reads back from flash rather than
trusting the copy still in RAM:

```
sf read 0x21000000 0x50000 0xb30000
bootm 0x21000000
```

Then:

```
setenv setargs 'setenv bootargs console=ttyS0,115200 LX_MEM=0xFF00000 mma_heap=mma_heap_name0,miu=0,sz=0x6e00000 mma_memblock_remove=1 mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg) ethaddr=${ethaddr}'
setenv bootcmd 'run setargs;gpio output 25 1;sf probe 0;sf read 0x21000000 0x50000 0xb30000;bootm 0x21000000'
setenv bootdelay 3
saveenv
```

`mtdparts` is what gives the kernel the `cfg` partition; without it there is no
`/dev/mtd1` to hold settings or SSH host keys, and `S05cfg` silently skips.

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
| `vdec_debug=N` | `mi_vdec` log level |
| `link=` | Link mode. Default is wfb-ng; anything else selects the `apfpv` Wi-Fi client. |
| `apfpv=off` | Do not start the Wi-Fi client |
| `disp=720\|off` | Display mode |

## On the device

| | |
| --- | --- |
| `fpv-start` / `fpv-stop` | Start or stop the player by hand |
| `fpv-probe [ip]` | Identify a camera's stream: port scan plus RTSP `DESCRIBE` |
| `load-mi <set>` | Insert an MI module set |
| `load-wifi` | Load the Wi-Fi driver matching the adapter |
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

### Settings

The rootfs is a RAM initramfs, so nothing written at runtime survives a reboot.
A JFFS2 filesystem on the spare NOR at the top of the chip provides the one
place that does — mounted at `/mnt/cfg`, formatted automatically on first boot,
and untouched by reflashing, since the image only covers `0x50000`–`0xb80000`.
It needs one kernel argument:

```
mtdparts=NOR_FLASH:11456k@0x50000(system),512k@0xf80000(cfg)
```

Everything is configured in `/mnt/cfg/wfb.conf` (symlinked to `/etc/wfb.conf`),
edited over SSH the same way OpenIPC's overlay works:

```bash
ssh root@<board>
vi /mnt/cfg/wfb.conf
reboot
```

| | |
| --- | --- |
| `mode` | `apfpv` — join the air unit's AP and pull RTSP. `wfb` — wfb-ng monitor mode with FEC |
| `channel`, `link_id`, `radio_port`, `udp_port` | wfb mode; every one must match the air unit |
| `key` | wfb key pair, generated on first use if absent |
| `codec`, `video_size` | wfb mode; what the air unit transmits. Nothing announces it over wfb, so it has to be stated |
| `ssid`, `psk` | apfpv mode |
| `region` | regulatory domain, two-letter country code |
| `telnet` | `1` enables the telnet console. Off by default — see below |

Precedence is built-in default, then this file, then the kernel command line —
so `link=`, `apfpv_ssid=`, `apfpv_psk=` and `wifi_cc=` still override it. That
matters when a bad edit leaves the board unable to see the drone: the command
line needs no working filesystem.

`apfpv` and `wfb` are mutually exclusive — one needs the adapter in managed
mode, the other in monitor mode — so exactly one runs, and switching means a
reboot.

### Pairing with a wfb-ng air unit

Tested against OpenIPC's `wifibroadcast-ng`, which despite the name is
`svpcom/wfb-ng` built from a pinned commit — the same upstream this repository
uses, so the two interoperate. The air unit's settings live in `/etc/wfb.yaml`.

These must agree on both ends:

| `/etc/wfb.yaml` (air) | `/mnt/cfg/wfb.conf` (ground) | OpenIPC default |
| --- | --- | --- |
| `wireless.channel` | `channel` | 165 (5825 MHz) |
| `broadcast.link_id` | `link_id` | 7669206 |
| — | `radio_port` | 0 |
| `/etc/drone.key` | `key` | pair, see below |

`radio_port` is not in `wfb.yaml` because their video transmitter does not pass
`-p` and so takes the default, 0. Ports 144/16 carry telemetry and 160/32 the
tunnel; neither is needed for video.

FEC (`fec_k`, `fec_n`) and `mcs_index` are transmit-side only — the receiver
learns them from the session header, so they do not need configuring here.

**Copy the key before switching the air unit out of AP mode**, or you will have
no route to it:

```bash
# ground station: make the pair without touching the radio
mkdir -p /mnt/cfg/wfb && cd /mnt/cfg/wfb && wfb_keygen

# from a PC, while the air unit is still an access point
scp root@<board>:/mnt/cfg/wfb/drone.key .
scp drone.key root@192.168.0.1:/etc/drone.key
```

`gs.key` stays on the ground station; they are halves of one pair and the link
will not decrypt with a mismatch.

Then set `mode = wfb` and reboot, or run `wfb-start` — it stops `wpa_supplicant`
and the Wi-Fi DHCP client itself, so no reboot is needed to try it.

### What the screen tells you

The player only starts once packets are actually decrypting, so the display
distinguishes the three states rather than showing an empty video plane:

| Screen | Meaning |
| --- | --- |
| picture | video decoding |
| `AIR UNIT HEARD, WRONG KEY` | frames arriving, none decrypt — key mismatch |
| `WAITING FOR AIR UNIT` | nothing on this channel, or `link_id`/`radio_port` differ |

The distinction is exact rather than a guess. `wfb_rx` filters on
`(link_id << 8) | radio_port`, written into each frame's source MAC, using a
capture filter — so a mismatch there is dropped before any counter moves and is
indistinguishable from silence. Anything that gets past the filter and still
fails is the key. And RSSI is recorded only for packets that decrypted, which is
why a wrong key reports traffic with no signal strength at all.

For wfb, `wfb-start` generates a key pair on first use if `key` is missing and
writes both halves next to it; copy `drone.key` to the air unit as
`/etc/drone.key`, or `scp` an existing `gs.key` over the top.

Either half works on either end -- both sides derive the same shared secret from
a `gs.key`/`drone.key` pair, which is why OpenIPC can ship one `drone.key` and
have its ground station use a copy of it. What matters is that both ends use
files from the *same* `wfb_keygen` run; halves from two different runs will not
decrypt. `wfb-keyinfo` prints the public halves of a key file if you need to
check two ends against each other.

`wfb-cli` shows the live link:

```
rssi -54dBm  snr 28dB   1240 pkt/s  624 kbit/s   fec 3 lost 0 decerr 0   5805MHz mcs3 bw20
```

`wfb-cli -1` prints once instead of refreshing. With several antennas it reports
the strongest. `fec` is packets the forward error correction rebuilt — non-zero
is normal and is the link working; `lost` is what it could not rebuild, and is
what to watch when the picture breaks up.

This is not wfb-ng's own `wfb-cli`, which is a Python/twisted ncurses client
talking to the aggregator service. None of that exists here, and none of it is
needed: `wfb_rx` prints the same numbers on stdout once a second.

For the real thing, `wfb_rx -f` forwards raw packets to a PC running the full
wfb-ng stack. That needs a PC attached, so it is a bench tool rather than how you
would fly, but nothing is reimplemented.

### Adaptive link

`alink = 1` scores the downlink and reports it to `alink_drone` on the air unit,
which raises or lowers its MCS and bitrate to match. On by default: on the bench
it took the air unit from MCS 2 to MCS 4, 12.6 to 23.9 Mbit/s, with nothing lost
and no decrypt errors. Set it to `0` if this ground station must never transmit.

It costs nothing when the air unit is not listening. The failure it used to
invite -- `alink_drone` falling back to MCS 0 and its lowest bitrate about a
second after the reports stop -- is why the sender runs supervised.

The reports ride the same tunnel pair OpenIPC already uses, mirrored — this
board transmits on `alink_tx_radio_port` (160) and listens on
`alink_rx_radio_port` (32), the opposite of the air unit. `wfb_tun` puts a
`wfb-gs` interface at `alink_tun_addr` so the air unit's `10.5.0.10:9999` is
directly reachable. The uplink `wfb_tx` runs `-k 1 -n 1`: reports are sparse, and
the default 8/12 FEC block would sit half-empty waiting for traffic that never
comes.

`alink-gs` runs under a supervisor that restarts it if it exits, because losing
the sender silently pins the aircraft at its slowest rate for the rest of the
flight. `wfb-stop` tears down the supervisor, the sender, both radio ends and the
tunnel, in that order.

Requires `CONFIG_TUN` and `/dev/net/tun`, both of which this image builds in. If
any piece is missing `wfb-start` says so and carries on without it — video does
not depend on any of this.

`/mnt/cfg/wfb.conf` survives a `sysupgrade`, so a board flashed from an older
image keeps its old config and none of the `alink_*` keys appear in it. Add them
by hand, or reinstall with `sysupgrade -c` to start from the current defaults.

### No picture

Three different faults produce a green screen, and they look identical:

**The decoder is set up for the wrong format.** There is no SDP over wfb, so
`codec` and `video_size` in `wfb.conf` are the only thing telling it what is
arriving. Confirm with:

```bash
grep -A3 'CHN STATE' /proc/mi_modules/mi_vdec/mi_vdec0
```

`SendCnt` climbing while `decPicCnt` stays 0 and `initSeqCnt` spins means data is
reaching the decoder but it cannot find a sequence header — the codec is wrong.
`video_size` must be the stream's own size, not the display's: the decoder cannot
scale up, and DIVP does the scaling afterwards.

**An old player still holds the channel.** `killall mi-player` does not work —
`fpv-start` runs a supervisor that restarts it a few seconds later with the
previous arguments. Use `fpv-stop`, which kills the supervisor first. If you see
`Chn(0) Already Create` or `Already Start`, a second player attached to the
existing channel and its settings were silently ignored.

**The OSD is covering it.** `fb-splash` draws on a layer above the video plane at
constant alpha, so it hides the picture rather than compositing with it.
`fpv-start` zeroes the framebuffer before starting the player; running `mi-player`
by hand does not:

```bash
fpv-stop
killall fb-splash mi-disp-init
dd if=/dev/zero of=/dev/fb0 bs=64k     # alpha 0 is transparent
mi-player -u 5600 -s 1920x1080 -h265
```

`MI_VDEC_SetChnParam FAILED (0xa0082008)` appears on both the RTSP and wfb paths
and video works regardless; it is not the cause.

### SSH

Log in as `root` with the password `12345678`, or build with
`ROOT_PASSWORD='...'` to change it. `SSH_PUBKEY=/path/to/key.pub` adds a key for
public-key auth; without it the build is password-only.

No private key ships in the image. A baked-in host key would be shared by every
board flashed from the same image, and would leak the moment the image did. The
board generates its own on first boot and keeps them on `/mnt/cfg`, so the
fingerprint is stable per board and survives reflashing. Without the `cfg`
partition SSH still works, but the fingerprint changes every reboot and clients
will complain. The keys are `ed25519` and `ecdsa`; RSA is skipped because
generating it on this SoC is slow and no current client needs it.

`BAKE_HOST_KEYS=1` embeds the build-time keys instead, for a private build on a
board with no `cfg` partition.

### Telnet

Off by default. It used to run as `telnetd -l /bin/sh`, which is a root shell for
anyone who can reach port 23, with no password and nothing encrypted. That was
defensible while UART RX was dead and SSH unproven; now that SSH works and keeps
its host key across reflashes, it is only exposure.

Turn it on when SSH itself is what broke:

```
telnet = 1        # in /mnt/cfg/wfb.conf
telnet=1          # or on the kernel command line, if the config is unreadable
```

It runs `/bin/login` when enabled, so it asks for the root password rather than
handing out a shell. The password still crosses the network in the clear — use
it to repair the board, then turn it back off.

### Signing images

`sysupgrade` fetches over HTTPS, but BusyBox says plainly what it does not do:

```
wget: note: TLS certificate validation not implemented
```

The connection is encrypted and unauthenticated, so anyone able to intercept it
could serve their own firmware. Checking the uImage header does not help — it
only proves the file is shaped like a kernel for this board, which is easy to
fake. The signature is what makes the transport irrelevant.

Every image carries a detached Ed25519 signature over its SHA-256 digest, and
the board refuses to install one that does not verify against the public key
built into the running firmware. Trust chains from the firmware already
installed, so the first image still has to arrive by a route you trust — TFTP
from U-Boot, or a build of your own.

To publish signed images from your own fork:

```bash
mkdir -p ~/.config/nvr-signing && chmod 700 ~/.config/nvr-signing
openssl genpkey -algorithm ed25519 -out ~/.config/nvr-signing/signing.key
chmod 600 ~/.config/nvr-signing/signing.key

# public half -> committed, compiled into the image
openssl pkey -in ~/.config/nvr-signing/signing.key -pubout -outform DER \
  | tail -c 32 > signing-key.pub

# private half -> CI secret, never in the repo
gh secret set FIRMWARE_SIGNING_KEY < ~/.config/nvr-signing/signing.key
```

Keep the private key off the build machine if you can, and back it up: losing it
means no board running the matching public key can be updated remotely again.
Rotating it needs one `-k` upgrade per board to install the new key.

Without the secret set, CI still publishes — unsigned. `sysupgrade` refuses
unsigned images unless given `-k`, which is also how you install one you built
yourself:

```bash
sysupgrade -k http://192.168.1.9:8000/uImage
```

To sign a local build so `-k` is not needed:

```bash
sha256sum output/uImage | cut -c1-64 | tr -d '\n' | xxd -r -p > /tmp/d.bin
openssl pkeyutl -sign -rawin -inkey ~/.config/nvr-signing/signing.key \
  -in /tmp/d.bin -out output/uImage.sig
```

`sysupgrade` looks for `<image>.sig` next to the image, at the same URL or path.
This is what `build-buildroot.sh` already does at the end of a build, so a
locally built image is normally signed before you ever see it.

### Building U-Boot

`build-uboot.sh` is a separate build path for the IPL_CUST-loaded bootloader;
`build-buildroot.sh` and `sysupgrade` never write it. It builds the patched
Infinity2M source with the bundled ARM 8.2 toolchain, omitting vendor display
and SD/MMC boot UI drivers that do not build for this SoC and are not needed to
load the Linux image from SPI NOR. Its compiled fallback environment is the
groundstation boot path: GPIO 25 enabled, the 11.2 MiB image read from
`0x50000`, and the same persistent `cfg` and protected U-Boot partitions. It
therefore boots the groundstation even if the saved environment is blank.

```bash
./build-uboot.sh
```

The resulting files are in `output/uboot/`:

- `u-boot.xz.img.bin`: the IPL_CUST-compatible U-Boot uImage.
- `u-boot-slot.bin`: that image padded to the complete 192 KiB `uboot` flash
  partition, suitable for `flashcp` after deliberately making the partition
  writable.
- `SHA256SUMS`: checksums for both images and the raw `u-boot.bin`.

The build validates the uImage CRCs, XZ round trip, and 192 KiB flash limit.
It does not flash anything. Treat a U-Boot write as a separate recovery-aware
operation: unlike a normal firmware update, a failed bootloader write requires
the SPI programmer.

## Air unit in apfpv mode

For wfb mode see [Pairing with a wfb-ng air unit](#pairing-with-a-wfb-ng-air-unit)
above. This section is the RTSP path.

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
build-buildroot.sh  main build: kernel, rootfs, MI stack, players
build-uboot.sh      isolated Infinity2M U-Boot build; produces no flash writes
buildroot-ext/      buildroot external tree: defconfig, packages, rootfs overlay
src/mi-player.c     RTSP/UDP/file -> MI_VDEC -> MI_DIVP -> MI_DISP -> HDMI
src/mi-disp-init.c  display and HDMI bring-up, raw MI_HDMI ioctls
src/fb-splash.c     framebuffer splash and status overlay
src/wifi-monitor.c  monitor mode and sniffing, no external dependencies
assets/test720.h264 720p Baseline 4:2:0 clip for `mi-player -f`, no network
vendor/             XiongMai MI blobs and stock /config, see vendor/README.md
patches/            vendor kernel, U-Boot and driver patches
docs/               design notes not needed to build or flash
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

## Credits

- [linux-chenxing](https://github.com/linux-chenxing/linux) — Infinity2M research
- [Discussion #85](https://github.com/linux-chenxing/linux-chenxing.org/discussions/85) — NVR board teardown
- [OpenIPC](https://openipc.org/) — air unit firmware and wfb-ng
- [industio/PurPle-Pi-R1](https://github.com/industio/PurPle-Pi-R1) — Alkaid SDK drop used during driver debugging
