# Porting to the OpenIPC buildroot tree

Notes for a possible move from `build-sdk.sh` to OpenIPC's buildroot external
tree. Nothing here has been attempted — this is the research, written down so it
does not have to be repeated.

**Status: not started.** Video now works end to end (wfb-ng, H.265, HDMI), so the
original precondition is met. Read "What actually ports" below before starting:
the part of OpenIPC's ground station that we would most want is the part that
cannot come across.

## There are two OpenIPC ground stations

They lead to opposite conclusions, and confusing them wasted an afternoon.

- <https://github.com/OpenIPC/sbc-groundstations> — "A unified OpenIPC ground
  station image builder using Buildroot". Rockchip SBCs. Carries pixelpilot,
  alink, msposd, gsmenu. Looks like the obvious upstream and mostly is not.
- **The NVR one** — `hi3536dv100_fpv_defconfig` in `OpenIPC/sandbox-fpv` and
  `OpenIPC/builder`, with packages in `OpenIPC/firmware`. A Cortex-A7 NVR SoC on
  NOR flash with vendor blobs. This is the one that matches this board.

`OpenIPC/firmware` is otherwise the camera tree, but it holds the packages the
NVR target uses — `vdec-openipc`, `hisilicon-osdrv-*`, `wifibroadcast`,
`datalink`.

Also relevant: `OpenIPC/sandbox-fpv` carries notes specifically about running an
NVR as a ground station — `nvr_gpio.md`, `rcjoystick.md`, `note_nvr_wdt.md`,
`usb-eth-modem.md`.

## What actually ports

There are two different OpenIPC ground stations, and they lead to opposite
conclusions. The distinction matters more than anything else in this document.

**The SBC one does not apply.** Every board `sbc-groundstations` supports is
Rockchip — RK3566 Radxa Zero3, RunCam Wifilink, Emax Wyvern-Link — with mainline
DRM/KMS, `rkmpp` hardware decode and eMMC. Its video player, `pixelpilot`, is
meaningless without rkmpp and DRM, and its images assume storage two orders of
magnitude larger than 11,456 KB of NOR.

**The NVR one does apply, closely.** `hi3536dv100_fpv_defconfig` (in
`OpenIPC/sandbox-fpv` and `OpenIPC/builder`) is a Cortex-A7 NVR SoC on NOR flash
with vendor blobs, and it is nearly this board's shape:

```
BR2_cortex_a7=y                              BR2_DEFAULT_KERNEL_VERSION="4.9.37"
BR2_LINUX_KERNEL_UIMAGE=y                    LOADADDR="0x80008000"
BR2_TARGET_ROOTFS_SQUASHFS=y (XZ)            # squashfs on NOR, not initramfs
BR2_PACKAGE_HISILICON_OSDRV_HI3536DV100=y    # vendor blobs as a package
BR2_PACKAGE_RTL8812AU_OPENIPC=y              # the same driver
BR2_PACKAGE_WIFIBROADCAST=y  BR2_PACKAGE_DATALINK=y
BR2_PACKAGE_MAVLINK_ROUTER=y BR2_PACKAGE_FFMPEG_OPENIPC=y
BR2_GCC_VERSION_8_X=y                        # vs our pinned 7.3
BR2_LINUX_KERNEL_EXT_HISI_PATCHER_LIST="...kernel/patches/ ...kernel/overlay"
```

Cortex-A7, a 4.9 kernel, a uImage with an explicit load address, squashfs on NOR,
vendor blobs packaged, our Wi-Fi driver, wifibroadcast. Everything structural we
would need, already solved for a comparable SoC.

### The decoder is the one piece that does not exist

`vdec-openipc` builds `vdec` from `OpenIPC/research` against HiSilicon's MPP:

```make
VDEC_OPENIPC_SITE = $(call github,openipc,silicon_research,$(VDEC_OPENIPC_VERSION))
$(MAKE) CC=$(TARGET_CC) DRV=$(HISILICON_OSDRV_HI3536DV100_PKGDIR)/files/lib -C $(@D)/vdec
```

`OpenIPC/research` contains `vdec` (HiMPP, decode) and `star` (SigmaStar, but the
*camera-side encoder* for Infinity6). **There is no SigmaStar decoder anywhere in
their tree.** `src/mi-player.c` has no upstream counterpart and comes with us
whatever we do — arguably it is this repository's one novel piece.

### Reusable regardless of whether we port

`OpenIPC/research/osd` is a framebuffer OSD built on `svpcom/wfb-ng-osd` and
`fbg`, MIT, plain C, with elements for RSSI, RX packets, rate, battery, altitude,
heading. It draws to a framebuffer, and `/dev/fb0` already works here. This does
not need buildroot and would be useful tomorrow.

## Why this is worth considering

`build-sdk.sh` is ~2000 lines of shell that assembles a kernel, an initramfs and
a dozen generated on-target scripts. It works and is verified on hardware, but:

- everything lives in a RAM initramfs, so the whole rootfs costs RAM and nothing
  written at runtime survives except `/mnt/cfg`
- adding a package means hand-writing cross-compile lines
- the generated on-target scripts are heredocs inside heredocs, checked by
  extracting them in CI and running `dash -n` over each

Buildroot would give a package system, a squashfs rootfs with a writable
overlay, and the OpenIPC package set (`ipctool`, `yaml-cli`, `vtund`, web UI).

## There is precedent: OpenIPC already ships an NVR groundstation

<https://github.com/OpenIPC/wiki/blob/master/en/fpv-nvr.md> — for **HiSilicon
Hi3536DV100**, built in the camera tree as
`br-ext-chip-hisilicon/configs/hi3536dv100_lite_defconfig`.

This is the closest precedent for a NOR-flash NVR SoC as a ground station, which
is why the camera tree is still worth reading even though the ground station
software lives elsewhere.

The page is not linked from the wiki table of contents; it is found only by
direct URL.

Their flashing procedure erases the **entire 16 MB including U-Boot**:

```
sf erase 0x0 0x1000000; sf write 0x82000000 0x0 0x1000000
```

We deliberately do not do this. Our images start at `0x50000` and leave the stock
XiongMai U-Boot intact, which is the only reason TFTP recovery has been available
every time a build went wrong. Keep that property if porting.

**Their image will not run on this board.** Different vendor, different SoC,
different video pipeline. Flashing it removes the bootloader and leaves only a
SPI programmer as recovery.

## How their build is structured

From `hi3536dv100_lite_defconfig`:

```
BR2_arm=y
BR2_cortex_a7=y
BR2_TOOLCHAIN_EXTERNAL_DOWNLOAD=y
BR2_TOOLCHAIN_EXTERNAL_URL=".../openipc/firmware/releases/download/$(OPENIPC_TOOLCHAIN).tgz"
BR2_TOOLCHAIN_EXTERNAL_HEADERS_4_9=y
BR2_LINUX_KERNEL_CUSTOM_TARBALL=y
BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION=".../openipc/linux/archive/$(OPENIPC_KERNEL).tar.gz"
BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="$(EXTERNAL_VENDOR)/board/$(OPENIPC_SOC_FAMILY)/hi3536dv100.generic.config"
BR2_LINUX_KERNEL_UIMAGE=y
BR2_LINUX_KERNEL_UIMAGE_LOADADDR="0x80008000"
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_SQUASHFS=y
BR2_OPENIPC_SOC_VENDOR="hisilicon"
BR2_OPENIPC_SOC_MODEL="hi3536dv100"
BR2_OPENIPC_FLASH_SIZE="8"
```

Three hosted inputs: a prebuilt toolchain, a kernel fork, and a board config.
`br-ext-chip-hisilicon/` itself contains only `board/` and `configs/`; the vendor
driver packages live in the shared package tree.

Note `cortex_a7` and a uImage with an explicit load address — structurally the
same shape as ours, and the same CPU family as the SSR621Q.

## What this board would need

| Piece | Our equivalent today |
| --- | --- |
| `br-ext-chip-sigmastar/configs/ssr621q_fpv_defconfig` | the variables at the top of `build-sdk.sh` |
| `board/ssr621q/` kernel config + post-image script | `config/kernel.config`, the flash-layout section |
| kernel tarball | `build/sdk/sigmastar/kernel/4.9.84`, a dirty vendor tree |
| package: MI blobs + `/config` tables | `vendor/`, staged by `build-sdk.sh` |
| package: RTL8812AU driver | built in-tree against the configured kernel |
| package: wfb-ng, apfpv, dropbear | `build-wfb.sh`, `build-apfpv.sh`, `build-dropbear.sh` |
| package: our `src/*.c` | cross-compiled directly |
| on-target scripts | heredocs generated into the initramfs by `init` |

## The hard parts

**Toolchain.** We pin gcc 7.3.0 (Bootlin) because a modern gcc cannot build a 4.9
kernel. OpenIPC instead *patches* their kernel fork to build with a current
toolchain. Two options:

- point buildroot at our Bootlin 7.3 toolchain as an external toolchain — easy,
  but diverges from how OpenIPC does it
- patch the SigmaStar kernel for modern gcc — real work. This tree is heavily
  vendor-modified; it already needed fixes to three separate python2 scripts
  before it would build at all.

Resolve this first. Everything else is mechanical by comparison.

**The kernel tree is not clean.** `build/sdk` is a dirty checkout with hand
edits. Before packaging it, diff against pristine upstream and turn every local
change into a patch file. The same trap already cost time twice: `build/sdk` and
`build/rtl8812au` both carried uncommitted edits that CI could not see.

**The uImage wrapper.** `arch/arm/boot/Makefile` has two rules that write
`uImage`. SigmaStar's hangs off the **zImage** recipe and wraps the raw
uncompressed `Image` with a bundled `scripts/mkimage`; the stock rule wraps
zImage and needs host mkimage. Buildroot's `BR2_LINUX_KERNEL_UIMAGE` would invoke
the stock rule and silently produce the wrong kind of image. The zImage recipe
also runs `ms_builtin_dtb_update.py`, which patches the board DTB into `Image` —
skipping it produces a kernel that will not boot. See `build-sdk.sh` for the
detail; this cost real debugging time.

**Blob provenance.** OpenIPC does redistribute vendor blobs, so this is not the
hard blocker it first appears. But theirs come from vendor-published SDK
tarballs, while ours were extracted from a device's own flash — murkier, and
worth agreeing with upstream before assuming a port could be merged. See
`vendor/README.md` for the provenance and licensing position.

## Things to keep

Whatever the build system, these were all learned the hard way and are verified
on hardware:

- images start at `0x50000`; the stock U-Boot is never overwritten
- `/mnt/cfg` JFFS2 at `0xf80000` holds settings and SSH host keys, and survives
  reflashing
- firmware is signed (ed25519 over the SHA-256 digest) and `sysupgrade` refuses
  unsigned images — BusyBox wget does not validate TLS certificates
- telnet is off by default
- required artifacts are hard build errors, never silent skips

## The plan

Ordered so that each phase ends somewhere usable and the riskiest assumption is
tested first. Do not start phase 2 until phase 1 answers its question.

### Phase 0 — things worth having either way

Neither depends on the port, and both survive it.

- `OpenIPC/research/osd` on `/dev/fb0` for on-screen telemetry.
- `alink_gs`: we already compute rssi/snr into `/tmp/wfb.status`; the scoring is
  normalisation to 1000–2000. The real work is transmitting — see "Transmitting"
  below.

### Phase 1 — answer the toolchain question, alone

Everything else rests on this and it is testable without committing to anything:

**Does the SigmaStar 4.9.84 kernel build with a modern gcc?**

We pin gcc 7.3 because a modern gcc could not build it. OpenIPC's NVR target uses
buildroot's own gcc 8 and carries a kernel patch list to make old trees build. So
either:

- point buildroot at our Bootlin 7.3 toolchain as an external toolchain — works,
  diverges from how they do it; or
- patch the kernel for a newer gcc, as their `EXT_HISI_PATCHER` list does.

Test it standalone: build the current kernel with gcc 8 and collect the errors.
If the list is short, the port is straightforward. If it is not, use the external
toolchain and move on — do not let this become the project.

### Phase 2 — make the vendor tree reproducible

Before anything can be packaged, `build/sdk` has to stop being a dirty checkout.
Diff against pristine upstream and turn every local edit into a patch file. The
same trap has already cost time twice (`build/sdk`, `build/rtl8812au`).

### Phase 3 — squashfs + overlay, still without buildroot

The biggest structural change, and independently valuable: it frees the RAM the
initramfs occupies and removes the `/mnt/cfg` special case. Doing it here means
phase 4 is a packaging exercise rather than a redesign.

### Phase 4 — the external tree

Copy `hi3536dv100_fpv_defconfig` as the template and substitute:

| theirs | ours |
| --- | --- |
| `hisilicon-osdrv-hi3536dv100` | a `sigmastar-mi-ssr621q` package wrapping `vendor/` |
| `vdec-openipc` (HiMPP) | `mi-player` |
| `wifibroadcast`, `datalink`, `rtl8812au`, `mavlink-router` | unchanged |
| `board/hi3536dv100/` | `board/ssr621q/` — kernel config, patches, post-image |

Keep the image starting at `0x50000`. Their flashing procedure erases all 16 MB
including U-Boot; ours must not.

### Phase 5 — the FPV package set

Once the tree builds, `alink_gs`, `msposd`, `wfb_tun` and the rest are
configuration rather than porting. This is the payoff, and it is worth noting
that phase 0 already delivers the two most valuable ones without any of this.

## Transmitting

`alink_gs` and telemetry both require the board to transmit, which it never has.
That is a real change in kind, not degree:

- regulatory power limits apply, and the adaptive-link docs warn about damaging
  adapters with aggressive `txpower`;
- a bug affects the aircraft's behaviour, not just our display — `alink_drone`
  falls back to its lowest-rate profile when it stops hearing the ground station,
  so a half-working uplink is worse than none.

Prove reception-only features first.

## Replacing U-Boot

Short answer: **possible in principle, not worth it, and the risk is asymmetric.**

`OpenIPC/u-boot-sigmastar` exists and is U-Boot 2015.01 — the same base as the
stock XiongMai one here (`U-Boot 2015.01 (Feb 15 2022)`). But it is described as
"U-Boot for Infinity6xx SoCs" and its topics are ssc30kq, ssc335, ssc337,
ssc338q, ssc377: all Infinity6 cameras. **No Infinity2M, no SSR621Q.** Adding it
would mean porting DDR init and board configuration for this SoC, which is the
least forgiving part of any bring-up.

Against that, weigh what would be lost. Every recovery this project has needed so
far has gone through the stock U-Boot's TFTP. Our images start at `0x50000`
precisely so that `0x0`–`0x50000` — IPL, IPL_CUST, U-Boot, and its environment —
is never touched. Overwrite that and a bad write is unrecoverable without a SPI
programmer. Their tree also ships `ipl/`, so a real switch would replace the
SigmaStar boot ROM stage as well.

And the gain is small: the stock U-Boot already does `tftpboot`, `sf
read/write/erase/lock`, `bootm` and `saveenv`, which is everything the build and
recovery flows use. What OpenIPC's adds is a boot splash, a GPIO boot menu and
nicer environment handling — pleasant, not necessary.

If it is ever attempted: load the new U-Boot into RAM and chainload it from the
running one first, so it can be tested without writing to flash, and have a
CH341A programmer and a full backup of the first 320 KB on hand before writing
anything below `0x50000`.
