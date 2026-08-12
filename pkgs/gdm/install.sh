#!/bin/sh
# Stage gdm, and check the three things that decide whether anyone can log in.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# --- where duct-live looks for it -------------------------------------------
#
# Not an arbitrary path check: pkgs/duct-live/files/graphical-session searches
# /usr/sbin/gdm and then /usr/bin/gdm, and falls back to weston when it finds
# neither. So a gdm installed anywhere else is not a broken greeter, it is an
# INVISIBLE one -- the live medium would quietly boot to the fallback compositor
# and nothing would report that the greeter had been built at all.
[ -x "$DESTDIR/usr/sbin/gdm" ] || \
	die "/usr/sbin/gdm is missing. duct-live's graphical-session searches /usr/sbin/gdm then /usr/bin/gdm and silently falls back to weston, so a gdm installed elsewhere disappears from the boot path without any error"

# --- THE PAM FILES, ASSERTED ONE BY ONE -------------------------------------
#
# THIS IS THE CHECK THIS RECIPE EXISTS FOR. -Ddefault-pam-config defaults to
# 'autodetect', which probes the BUILD environment for /etc/lfs-release and
# friends; none exist in the Duct builder, so it resolves to 'none' and
# data/meson.build:136 installs an EMPTY list of PAM files.
#
# linux-pam's `other` stack denies, so that outcome is a greeter which refuses
# every user with correct credentials -- built green, installed complete,
# failing closed at the only moment anyone would notice.
#
# Checked per file rather than by testing the directory, because an empty
# /etc/pam.d and a partial one fail identically at the login prompt and only the
# enumerated list distinguishes them. The five names are the 'lfs' entry of
# pam_data_files_map verbatim.
for p in gdm-autologin gdm-launch-environment gdm-fingerprint gdm-smartcard gdm-password; do
	[ -s "$DESTDIR/etc/pam.d/$p" ] || \
		die "/etc/pam.d/$p is missing or empty. gdm installs PAM files only for a KNOWN distro: -Ddefault-pam-config=autodetect probes the build environment for /etc/lfs-release, which the Duct builder does not have, and then installs NOTHING. With linux-pam's other stack denying, that is a greeter that rejects every user -- and this is the only check that can tell an empty pam.d from a complete one"
done

# --- nothing under /usr/etc -------------------------------------------------
#
# HONEST ABOUT WHAT THIS CHECK IS: it cannot fail today. meson special-cases a
# /usr prefix and resolves sysconfdir to the absolute /etc on its own
# (BUILTIN_DIR_NOPREFIX_OPTIONS in mesonbuild/options.py), so this passes with
# or without the -Dsysconfdir=/etc pin in pkg.env. It is a regression guard on
# that upstream special case, not a live test of this recipe -- the same
# category as a pinned default, and it is labelled so that nobody later reads a
# passing check as evidence that the flag is doing work.
#
# The eight sysconfdir-derived paths listed in pkg.env are why it is worth
# keeping: if meson ever drops the special case, this fires before a daemon
# ships compiled to look for its configuration where nothing writes.
[ ! -d "$DESTDIR/usr/etc" ] || \
	die "files were installed under /usr/etc. meson's /usr-prefix special case for sysconfdir has changed, or this package was built under a different prefix -- gdm compiles SYSCONFDIR into the daemon and derives its config, dm, dconf and D-Bus policy paths from it"

# --- no systemd units, which this tree cannot start -------------------------
#
# Unlike gnome-session, gdm accepts a literal 'no' for both unit directories, so
# nothing has to be removed after the fact. This confirms both took.
[ ! -d "$DESTDIR/usr/lib/systemd" ] || \
	die "systemd units were installed despite -Dsystemdsystemunitdir=no and -Dsystemduserunitdir=no; this tree has elogind and nothing to start them"

finish_install
log "installed gdm at /usr/sbin/gdm with its five LFS PAM profiles, on elogind"
