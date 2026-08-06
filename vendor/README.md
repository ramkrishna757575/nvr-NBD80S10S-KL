# Vendor binaries

Proprietary components read off a XiongMai NBD80S10S-KL board's own flash.
They are here so a plain `git clone` can build a working image, the same way
[OpenIPC](https://github.com/OpenIPC/firmware) carries its SigmaStar `.ko` files
in `general/package/sigmastar-osdrv-*/files/`.

| | |
| --- | --- |
| `modules/` | 10 SigmaStar MI kernel modules, XiongMai's 2023 build (`sdk_commit.f947025`), vermagic `4.9.84 SMP preempt mod_unload ARMv7 thumb2 p2v8` |
| `config/` | The stock `/config` tree: `config_tool`, `mmap.ini`, `fbdev.ini` and the `panel/DACOUT_*.ini` timing tables |
| `lib/` | uClibc runtime, needed only because `config_tool` is linked against it |

## Why each is required

`modules/` is the only set that both decodes video and drives HDMI. The
SigmaStar SDK ships its own build of most of these, but it has no HDMI TX layer
at all — `mhal.ko` there exports zero `MhalHdmitx*` symbols — and its modules are
a newer release than its own libraries, so `MI_SYS_Init` fails with
`0xa009201f`.

`config/` has to be the whole directory. `MI_SYSCFG_GetPanelInfo` builds its
output-timing table from `panel/DACOUT_*.ini`, and without those every lookup
reports `Not Fund!!!` and `MI_DISP_SetPubAttr` dies on
`Can't find Timing(1080P60)`. It also carries the correct 256 MB `mmap.ini` —
the SDK's is for a 64 MB board.

`lib/` holds the uClibc loader. `config_tool` is XiongMai's uClibc binary and
must stay theirs: the SDK's glibc build emits a config blob in an older layout
that their `mi_sys` memcpys into a smaller buffer, which oopses the kernel.

## Provenance and licensing

Extracted from `usr.sqfs` (as `lib/modules.tar.lzma`) and `romfs.sqfs` of a
retail unit. Verify with `md5sum -c MD5SUMS`.

These are XiongMai's and SigmaStar's copyrighted binaries, redistributed here
without an explicit licence grant, purely so owners of this board can rebuild
firmware for hardware they already possess. Nothing here is authored by this
project. If either vendor objects, open an issue and it comes down.

The full 16 MB flash dump is **not** here — it carries the board's real MAC and
U-Boot environment. `fetch-deps.sh` can still extract these files from your own
dump if you prefer not to trust the copies committed here.
