################################################################################
#
# wfb-ng
#
################################################################################

# Pinned, not a branch. Upstream master moves, and a silent bump would change
# the wire format against an already-flashed drone. A later master also added a
# designated initializer that gcc 7.3 -- fixed here by the 4.9 kernel -- cannot
# compile. Bump deliberately, not by accident.
WFB_NG_VERSION = 5d31caadec51cf15c9c16b0ed252c26d0d2f2fc1
WFB_NG_SITE = https://github.com/svpcom/wfb-ng.git
WFB_NG_SITE_METHOD = git
WFB_NG_LICENSE = GPL-3.0
WFB_NG_DEPENDENCIES = libsodium libpcap libevent

# ZFEX_USE_INTEL_SSSE3 is dropped from upstream's defaults (x86 only) and NEON
# kept, which is what matters on the Cortex-A7.
WFB_NG_CFLAGS = $(TARGET_CFLAGS) -Wall -O2 -fno-strict-aliasing \
	-DZFEX_UNROLL_ADDMUL_SIMD=8 -DZFEX_USE_ARM_NEON \
	-DZFEX_INLINE_ADDMUL -DZFEX_INLINE_ADDMUL_SIMD

# Upstream's own Makefile knows the object lists and the -std flags per
# language, so drive it rather than reimplementing its rules. Only the specific
# binaries are asked for.
define WFB_NG_BUILD_CMDS
	$(MAKE) -C $(@D) wfb_rx wfb_tx wfb_keygen \
		CC="$(TARGET_CC)" CXX="$(TARGET_CXX)" \
		CFLAGS="$(WFB_NG_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)"
	$(MAKE) -C $(@D) wfb_tun \
		CC="$(TARGET_CC)" CXX="$(TARGET_CXX)" \
		CFLAGS="$(WFB_NG_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS) -levent_core"
endef

define WFB_NG_INSTALL_TARGET_CMDS
	$(foreach b,wfb_rx wfb_tx wfb_keygen wfb_tun, \
		$(INSTALL) -D -m 0755 $(@D)/$(b) $(TARGET_DIR)/bin/$(b)
	)
endef

$(eval $(generic-package))
