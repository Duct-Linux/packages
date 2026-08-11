#!/bin/sh
# Write .config and build, in-tree and in the wpa_supplicant/ subdirectory.
#
# Not the generic autotools stage: there is no configure. ../src/build.rules
# reads CONFIG_FILE=.config, and every feature is a make variable rather than a
# probe -- so nothing here is detected, everything is declared, and anything
# not declared is absent.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH/wpa_supplicant" || die "the wpa_supplicant/ subdirectory is missing"

# WRITTEN FROM SCRATCH RATHER THAN FROM defconfig, which is what BLFS does and
# what upstream's README describes -- and it is the more dangerous of the two,
# so the danger is written down here rather than assumed.
#
# defconfig is not a minimal file: it is a fully populated configuration with
# roughly forty features already enabled. Starting from empty means every one
# of those is off unless it appears below, and the loss is silent because a
# missing CONFIG_ line is indistinguishable from a feature nobody wanted.
# CONFIG_SAE is the case that matters (see below) and it is unlikely to be the
# only one, so: ANYTHING ADDED HERE LATER SHOULD BE CHECKED AGAINST defconfig
# IN THE TARBALL, not against another distribution's copy of this file.
log "writing .config"
cat >.config <<'EOF'
# --- what talks to us -------------------------------------------------------
# The D-Bus interface NetworkManager uses. fi.w1.wpa_supplicant1 is the "new"
# interface; the old fi.epitest.hostap.WPASupplicant one is deliberately NOT
# enabled, because NetworkManager has not used it for over a decade and it
# would be a second, unauthenticated way into the same daemon.
#
# THIS IS THE MOST LOad-BEARING LINE IN THE FILE. Without it wpa_supplicant
# builds, installs, runs and is completely unreachable by NetworkManager: the
# Wi-Fi panel lists networks (that scan is NetworkManager's own) and every
# connection attempt fails.
CONFIG_CTRL_IFACE_DBUS_NEW=y

# Introspect() on those D-Bus objects. Costs a libxml2 dependency at build time
# (the dbus/Makefile calls xml2-config, which libxml2 ships) and is worth it:
# it is the only way to ask a running wpa_supplicant what interface it actually
# exposes, which is the first question when NetworkManager cannot drive it.
CONFIG_CTRL_IFACE_DBUS_INTRO=y

# The UNIX socket control interface, which is what wpa_cli speaks. Independent
# of D-Bus and kept because it is the debugging path that still works when the
# D-Bus side is what is broken.
CONFIG_CTRL_IFACE=y

# --- how we reach the hardware ---------------------------------------------
# nl80211 is the only Wi-Fi driver interface on a modern kernel. It brings in
# libnl automatically: drivers.mak asks pkg-config for libnl-3.0 and sets
# CONFIG_LIBNL32 itself (lines 167-179), so that symbol is deliberately not set
# here. It also sets CONFIG_LIBNL3_ROUTE, which links -lnl-route-3 -- pkgs/libnl
# ships and asserts all three of libnl-3, libnl-genl-3 and libnl-route-3.
#
# If libnl were missing, this does NOT fall back quietly: it falls through to
# -lnl -lnl-genl, the libnl 1.x names, and fails at link. Loud, which is the
# right direction, but it fails late.
CONFIG_DRIVER_NL80211=y
# 802.1X over ethernet. NetworkManager offers wired 802.1X in the Network panel
# and drives it through this same daemon.
CONFIG_DRIVER_WIRED=y
# The pre-nl80211 ioctl interface. Kept for drivers that never grew an nl80211
# path; it costs a few kilobytes and no dependencies.
CONFIG_DRIVER_WEXT=y

# --- what a modern network actually requires --------------------------------
# WPA3-Personal. NOT OPTIONAL IN 2026, AND NOT ON BY DEFAULT HERE.
#
# defconfig enables it (line 258). The Makefile only forces it on inside
# `ifdef CONFIG_MESH` (line 266), which is off. So a .config written from
# scratch without this line -- which is what the widely copied BLFS
# configuration is -- produces a wpa_supplicant with no SAE at all.
#
# The failure is invisible from here: the build is green, NetworkManager drives
# the daemon perfectly, and WPA3 networks simply never associate. It cannot be
# caught without a WPA3 access point to test against, and WPA3 has been
# mandatory for Wi-Fi 6E and Wi-Fi 7 certification, so "the new router in the
# building does not work and the old one does" is how it would be reported.
CONFIG_SAE=y
# Opportunistic Wireless Encryption -- encryption on networks with no
# passphrase. Off in defconfig (line 642). Cheap, and it is the difference
# between an open network being encrypted and being in the clear.
CONFIG_OWE=y
# WPS push-button and PIN enrolment.
CONFIG_WPS=y

# --- enterprise authentication ---------------------------------------------
# EAP. CONFIG_IEEE8021X_EAPOL is the switch the individual methods hang off,
# and each method below is one NetworkManager offers in its 802.1X UI. TLS,
# PEAP and TTLS are the three that matter; MD5, GTC, OTP, LEAP and MSCHAPv2 are
# inner methods PEAP and TTLS select between.
CONFIG_IEEE8021X_EAPOL=y
CONFIG_EAP_TLS=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_GTC=y
CONFIG_EAP_OTP=y
CONFIG_EAP_MD5=y
CONFIG_EAP_LEAP=y
# PKCS#12 certificate bundles and PKCS#11 tokens, both routed through OpenSSL.
# This is how a user-supplied client certificate reaches EAP-TLS.
CONFIG_PKCS12=y
CONFIG_SMARTCARD=y

# --- the rest ---------------------------------------------------------------
# Where the network list is kept. `file` means /etc/wpa_supplicant.conf, which
# is the form wpa_cli and wpa_passphrase write.
CONFIG_BACKEND=file
CONFIG_IPV6=y
# Logging. Without these the daemon has exactly one output channel, stdout, and
# it is started by an init system that discards it.
CONFIG_DEBUG_FILE=y
CONFIG_DEBUG_SYSLOG=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON

# --- deliberately absent ----------------------------------------------------
# CONFIG_TLS is not set: openssl is the default and openssl is what is
# packaged. Naming it would be a second place to keep in step.
#
# CONFIG_READLINE gives wpa_cli history and completion, and readline belongs to
# another chain. UNLIKE bluez's --disable-client, THE COST HERE IS SMALL AND
# THE DIFFERENCE IS WORTH KNOWING: readline is not a hard requirement of
# wpa_cli, it selects which line editor it links (Makefile 1746-1752). Without
# it CONFIG_WPA_CLI_EDIT's internal editor is used and wpa_cli is still built
# and still fully functional -- it loses history and tab completion, not
# existence. Revisit when readline lands; nothing breaks until then.
#
# CONFIG_PEERKEY is not set because IT NO LONGER EXISTS. See pkg.env.
#
# CONFIG_MESH (802.11s), CONFIG_AP, CONFIG_P2P, CONFIG_SAE_PK, CONFIG_HS20,
# CONFIG_MATCH_IFACE, CONFIG_TDLS, CONFIG_IEEE80211R (fast BSS transition):
# each off, each a decision rather than an omission. IEEE80211R is the one most
# likely to be wanted next -- it is roaming between access points on one
# network, which matters on any site with more than one AP.
EOF

# BINDIR IS PASSED HERE AS WELL AS AT INSTALL TIME, and it is not redundant.
# The default target generates the D-Bus activation file by substituting
# @BINDIR@, so this stage decides what Exec= says. See pkg.env for what
# happens when only the install stage is told.
log "building with -j$JOBS"
make -j"$JOBS" BINDIR="$WPA_BINDIR" || die "make failed"

# The D-Bus activation file is GENERATED BY THE DEFAULT TARGET AND INSTALLED BY
# NOTHING. `ALL` includes dbus/fi.w1.wpa_supplicant1.service (Makefile line 8),
# built from the .in by substituting @BINDIR@; but `install` only handles
# $(BINALL) and wpa_passphrase, so the file is produced and then left in the
# build tree.
#
# That is the worst shape for this kind of mistake: anyone checking whether the
# activation file "got built" finds it and concludes it shipped. install.sh
# installs it by hand, and this assertion is here so the two stages cannot
# drift -- if upstream ever stops generating it, this fails at build time
# rather than leaving install.sh silently copying nothing.
[ -s dbus/fi.w1.wpa_supplicant1.service ] \
	|| die "dbus/fi.w1.wpa_supplicant1.service was not generated; without it nothing can D-Bus-activate wpa_supplicant"
