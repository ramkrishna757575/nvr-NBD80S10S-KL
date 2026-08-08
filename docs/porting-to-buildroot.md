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

**Toolchain — answered 2026-08-08, and the answer is good.** The premise below
was wrong: **gcc 8.2 builds this kernel cleanly.** Zero errors, zero warnings,
`zImage is ready`, both for the plain `infinity2m_ssc010a_s01a_defconfig` and for
our production config with USB, CFG80211, NET_CORE and TUN added. gcc 8 is
exactly what OpenIPC's NVR target uses (`BR2_GCC_VERSION_8_X=y`), so buildroot's
own toolchain should work with no kernel patch list at all.

Method, if it needs repeating: copy the kernel tree, `mrproper`, then build with
`build/toolchain/gcc-arm-8.2-2018.08-x86_64-arm-linux-gnueabihf` (already present
for U-Boot). Host tools need `HOSTCFLAGS='-O2 -fcommon -w'` under a current host
gcc; that is a host-side concern, unrelated to the target compiler.

Not tested: gcc 13/15, the two Wi-Fi drivers under gcc 8, and booting a gcc-8
kernel on hardware. The pin to 7.3 stays until those are done -- this experiment
removes the blocker, it does not by itself justify changing the shipped build.

> We pin gcc 7.3.0 (Bootlin) because a modern gcc cannot build a 4.9
> kernel. OpenIPC instead *patches* their kernel fork to build with a current
> toolchain.

**Out-of-tree builds do not work.** `make O=...` dies in
`arch/arm/mach-sstar/Kconfig` with "recursive inclusion detected" and a tell-tale
`mach-sstar//Kconfig` double slash -- a path variable that is empty unless the
build runs in the source tree. Anything that assumes `O=` needs this fixed first.

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

*Solvable, checked 2026-08-08.* Buildroot separates the target it invokes from
the file it collects:

```
BR2_LINUX_KERNEL_IMAGE_TARGET_CUSTOM=y
BR2_LINUX_KERNEL_IMAGE_TARGET_NAME="zImage"   # runs SigmaStar's rule + BNDTB
BR2_LINUX_KERNEL_IMAGE_NAME="uImage"          # collects what that rule wrote
```

So do not select `BR2_LINUX_KERNEL_UIMAGE`. Verify the result the same way
`build-sdk.sh` does: the uImage payload size must equal `arch/arm/boot/Image`,
which is what distinguishes it from a zImage wrapper.

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

**Done, 2026-08-08. gcc 8.2 builds the kernel with zero errors** — defconfig and
our production config alike. See "The hard parts" above for the method and for
what was *not* tested. Buildroot can use its own gcc 8 rather than being pointed
at our Bootlin 7.3, and no `EXT_HISI_PATCHER`-style patch list appears to be
needed for the compiler.

The question this was gating — is the port a week or a month — now leans towards
the former, at least for the kernel.

### Phase 2 — make the vendor tree reproducible

Before anything can be packaged, `build/sdk` has to stop being a dirty checkout.
Diff against pristine upstream and turn every local edit into a patch file. The
same trap has already cost time twice (`build/sdk`, `build/rtl8812au`).

### Phase 3 — squashfs + overlay, still without buildroot

**Reassessed 2026-08-08: worth doing eventually, but not for the reason given
here, and not urgently.**

The flash-space argument does not survive measurement. For the same rootfs:

| | bytes |
| --- | --- |
| gzip cpio (what the build used to ship) | 7,363,969 |
| **xz cpio** (what it ships now) | **5,076,380** |
| squashfs, xz, 256K block | 5,779,456 |

squashfs is *worse* than simply compressing the initramfs properly — it
compresses in blocks so it can be demand-paged, where a cpio is one solid
stream. Switching to xz recovered 2.29MB and took the spare room on the system
partition from 188KB to 2.47MB, with no change to how the board boots or
upgrades. The RAM argument is weak too: the board sits at 89MB free of 134.

What is left, and still genuine:

- writes that survive a reboot without the `/mnt/cfg` special case
- phase 4 becoming a packaging exercise rather than a redesign

Both are real, neither is pressing, and both collide with `sysupgrade`, which
erases the partition it is running from -- safe only because the root is in RAM.
Redesigning that belongs with the buildroot port, where it has to happen anyway,
not as a standalone change to a working ground station.

The biggest structural change, and independently valuable: it frees the RAM the
initramfs occupies and removes the `/mnt/cfg` special case. Doing it here means
phase 4 is a packaging exercise rather than a redesign.

### Storage design — resolved for now, still relevant later

**Superseded 2026-08-08.** Both adapters now ship in the one initramfs. Trimming
the image (unused MI libraries, vendor boot media, unused BusyBox applets) freed
about 944 KiB, and `8812eu.ko` costs 760 KiB compressed, so the `system`
partition holds both drivers with roughly 184 KiB to spare. No extra partition
was needed.

The original reasoning is kept below because the headroom is now thin again, and
the next bulky asset brings it straight back.

> The current 11,456 KiB `system` partition has only about 28 KiB free in the
> working image. That is not enough to ship a second external monitor-mode Wi-Fi
> driver: the existing RTL8812AU module alone compresses to roughly 735 KiB. The
> BL-M8812EU2 needs its distinct `rtl8812eu` module, so supporting both adapters
> cannot remain a one-image initramfs-only design.

Do not retrofit OpenIPC's writable squashfs-overlay root into this SDK just to
solve that. The current root runs from RAM, so `sysupgrade` can safely erase and
rewrite its backing `system` partition. A flash-mounted root makes the running
filesystem depend on the partitions being updated and requires a different,
recovery-aware upgrade design.

The intermediate design, if a third driver or any other bulky asset is wanted, is
a separate read-only squashfs MTD partition mounted early (for example at
`/opt/gs`) for immutable assets: Wi-Fi modules, firmware, and optional tools.
Keep the kernel, init, BusyBox, HDMI path, and updater in the RAM-root uImage;
bind-mount or symlink the modules into `/lib/modules`. Keep persistent keys and
settings in the existing JFFS2 `cfg` partition. This preserves the proven upgrade
model. Adopt a writable root overlay only with the Buildroot port.

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

**Feasible.** `OpenIPC/u-boot-sigmastar` describes itself as "U-Boot for
Infinity6xx SoCs" and tags only Infinity6 parts, but that is the description, not
the tree. It is SigmaStar's vendor U-Boot 2015.01, covering every Infinity
generation:

```
configs/infinity2m_defconfig            configs/infinity2m_emac1_defconfig
configs/infinity2m_spinand_defconfig    configs/infinity2m_usb_defconfig
```

Same base version as the stock XiongMai build here (`U-Boot 2015.01 (Feb 15
2022)`, `Version: I2gc99e607` — I2 for Infinity2).

**DDR init is not U-Boot's job on this SoC.** The IPL brings DRAM up before
U-Boot runs, which the boot log shows plainly:

```
IPL g4b89453 / miupll_233MHz / SPI 54M / 256MB      <- DRAM up here
IPL_CUST g4b89453
U-Boot 2015.01 ... @announce_dram_init(),DRAM:      <- only announces it
```

So keeping IPL and IPL_CUST at `0x0`–`0x10000` and replacing only U-Boot at
`0x10000`–`0x40000` avoids the hardest part of a bring-up entirely.

What remains is ordinary board porting, against SigmaStar's reference board:

- pin muxing — the stock `bootcmd` does `gpio output 25 1` before reading flash,
  which is board-specific and undocumented
- EMAC and PHY wiring, including which of emac0/emac1 is used
- environment at `0x40000`, and the `sf lock 0` behaviour this flash needs
- whether the stock IPL_CUST will load an image this tree produces unchanged —
  their `ipl/` directory and `make_boot_spinor.sh` suggest they normally build
  and flash IPL and U-Boot together

**Evaluate before writing anything.** The binary can be tested without touching
flash: `tftpboot` it into RAM and chainload with `go`. Compare it against the
stock one first — extract `0x10000`–`0x40000` from a flash dump and diff sizes,
strings and the entry point.

**What it would buy** is worth being honest about: the stock U-Boot already does
`tftpboot`, `sf read/write/erase/lock`, `bootm` and `saveenv`, which is every
operation the build and recovery flows use. The gains are a boot splash, a GPIO
boot menu, environment handling that can be changed in-image rather than through
`saveenv`, and a bootloader we can actually rebuild. That last one matters most
if the board is ever to be flashed by someone else.

**Risk:** a bad write below `0x50000` costs the TFTP recovery every fix in this
project has relied on, and needs a CH341A to undo. Do not attempt it without the
programmer to hand and a verified backup of the first 320 KB.

### It builds (tried it)

`patches/0004-uboot-sigmastar-build-for-infinity2m.patch` takes the tree from 33
errors to a clean build with our pinned gcc 7.3:

```
make infinity2m_defconfig
# disable CONFIG_MS_SDMMC and CONFIG_SSTAR_DISP -- the infinity2m headers lack
# their register definitions (16 and 8 errors respectively)
make KCFLAGS=-DPRODUCT_SOC=ssr621q
```

The patch is four changes:

- `drivers/mstar/gpio/infinity2m/mhal_gpio.{c,h}` \u2014 the shared `drvGPIO.c` moved
  to the Infinity6 HAL API (status return, out-parameters) and infinity2m was
  never updated. Adds `Pull_Up/Down/Off`, which infinity6 also stubs as
  unsupported.
- `include/configs/infinity2m.h` \u2014 include `<configs/sstar-common.h>`, which
  OpenIPC added and wired into infinity6 only. This is where
  `CONFIG_ENV_ROOTADDR` and the env offset of `0x40000` come from, and that
  offset happens to match this board.
- `common/autoboot.c` \u2014 two `mmc_get_dev` calls sat outside the
  `CONFIG_MS_SDMMC` guard.

Result: `u-boot.bin` 347,528 bytes, `u-boot.xz.img.bin` 128,440 bytes,
`CONFIG_SYS_TEXT_BASE=0x23E00000`.

### The two things that are still unknown

**Does it run? Chainloading cannot answer this — tried, twice.**

- `tftpboot 0x21000000 u-boot.bin` then `go 0x21000000` → prints "Starting
  application", emits one garbage byte and the board resets. The tree is not
  position-independent, so it cannot run away from its link address.
- `cp.b 0x21000000 0x23E00000 0x54d88` → hangs, exactly as `tftpboot` straight to
  `0x23E00000` did.

Both failures at `0x23E00000` say the same thing: the **running** stock U-Boot
occupies that address. It is built from the same vendor tree, so it shares
`CONFIG_SYS_TEXT_BASE=0x23E00000`, and it evidently executes in place rather than
relocating to high RAM. Writing there destroys the code that is executing.

So the build cannot run anywhere else, and the one place it can run is taken.
Both attempts were RAM-only and the board recovered on a power cycle, but there
is nothing further to learn without writing flash.

**Does it fit where the IPL_CUST looks?** The boot log shows IPL_CUST reading
`offset:00010000`, `size:65536` \u2014 our compressed image is 128,440, roughly double.
The U-Boot region is `0x10000`\u2013`0x40000` (192 KB), so it fits the *region*;
whether IPL_CUST honours a size field in the image header or always reads a fixed
64 KB decides this, and only writing flash answers it.

Note also that `make_boot_spinor.sh` builds a `BOOT.bin` for their layout \u2014
IPL_CUST at 64k, U-Boot at 128k \u2014 which is not this board's. And
`ipl/infinity2m/{IPL,IPL_CUST,MXP_SF}.bin` are absent from the repository, more
evidence that infinity2m is carried but not built. Keeping the stock IPL was the
plan anyway; only `u-boot.xz.img.bin` would ever be written, to `0x10000`.

### Still board-specific, even once it runs

The defconfig targets SigmaStar's reference board, not the XiongMai
NBD80S10S-KL:

- the stock `bootcmd` does `gpio output 25 1` before reading flash \u2014 purpose
  undocumented, and GPIO is exactly the subsystem the patch touches
- EMAC/PHY wiring, and which of emac0/emac1 is used
- `sf lock 0` behaviour this flash needs before erase and before `saveenv`
