# Porting to the OpenIPC buildroot tree

Notes for a possible move from `build-sdk.sh` to OpenIPC's buildroot external
tree. Nothing here has been attempted — this is the research, written down so it
does not have to be repeated.

**Status: not started. Do not begin until video works end to end** (apfpv and
wfb-ng both verified against a real air unit). Porting a build system while the
product is unproven means debugging two unknowns at once.

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
Hi3536DV100**, built in their normal tree as
`br-ext-chip-hisilicon/configs/hi3536dv100_lite_defconfig`.

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

## Lower-risk first step

Switching the rootfs from initramfs to squashfs + overlay is the single biggest
structural difference, is independently useful, and needs no buildroot. It would
free the RAM the rootfs currently occupies and give a writable filesystem
without the `/mnt/cfg` special case. Worth doing on its own terms, and it makes a
later port smaller.
