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

# --- THE GREETER'S OWN SESSION HAS NO SESSION MODULE ------------------------
#
# The check above proves the five files are THERE. It cannot see that one of
# them names a module this tree does not ship -- which is finding 44 exactly:
# it asserts the shape of the evidence rather than the thing.
#
# gdm opens the greeter's session through gdm-launch-environment, and the 'lfs'
# profile's entire session stack is:
#
#     session  required  pam_succeed_if.so audit quiet_success user = gdm
#    -session  optional  pam_systemd.so
#     session  optional  pam_keyinit.so force revoke
#     session  optional  pam_permit.so
#
# pam_systemd.so does not exist here; elogind ships pam_elogind.so and NO alias
# for it (checked in the published package -- the libsystemd.pc trick has no
# PAM equivalent). The leading '-' means PAM skips a missing module SILENTLY,
# so the greeter's session is opened with nothing that registers it with
# logind: no XDG_SESSION_ID, no seat, and no /run/user/21 -- which is where a
# Wayland socket has to live. Every one of those absences is quiet.
#
# UPSTREAM SHIPS THE FIX IN THE TARBALL, one directory away. data/pam-arch/ and
# data/pam-exherbo/ carry BOTH lines, adjacent:
#
#    -session   optional   pam_systemd.so
#    -session   optional   pam_elogind.so
#
# Only pam-lfs -- the profile this tree must select, and correctly does -- has
# the systemd line without its elogind sibling. So this is not a Duct policy
# choice being patched over: it is one upstream profile lacking a line two
# other upstream profiles have, adopted verbatim from them.
#
# Appended rather than rewritten, and asserted after the fact: the point is
# that the module is REACHED, and a check on the file we just wrote would be
# unfalsifiable. Both lines keep their '-', so a system with neither module
# still logs in exactly as before.
lenv="$DESTDIR/etc/pam.d/gdm-launch-environment"
if ! grep -qE '^-?session[[:space:]]+optional[[:space:]]+pam_elogind\.so' "$lenv"; then
	printf -- '-session optional       pam_elogind.so\n' >>"$lenv"
fi
grep -qE '^-?session[[:space:]]+optional[[:space:]]+pam_elogind\.so' "$lenv" || \
	die "gdm-launch-environment has no pam_elogind session line. That stack is how the GREETER's own session is opened, and without a logind module it gets no XDG_RUNTIME_DIR -- so gnome-shell has nowhere to put the Wayland socket and the greeter cannot draw. Upstream's pam-arch and pam-exherbo profiles carry this line beside pam_systemd.so; only pam-lfs omits it"

# The systemd line is asserted too, and deliberately: it is the line whose
# silent uselessness hid this, and if a future gdm drops it the pair should be
# re-read rather than half-inherited.
grep -qE '^-session[[:space:]]+optional[[:space:]]+pam_systemd\.so' "$lenv" || \
	die "gdm-launch-environment no longer names pam_systemd.so. The elogind line above was added as its sibling, copied from upstream's pam-arch profile; if upstream has restructured this stack, re-read it rather than assuming the addition still belongs"

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
