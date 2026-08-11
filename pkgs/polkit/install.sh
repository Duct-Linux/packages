#!/bin/sh
# Stage polkit, drop the systemd-only files, and assert that what was staged
# can actually authorize.
#
# This replaces the generic install-meson.sh rather than adding a
# post-install.sh, because ORDER MATTERS HERE. finish_install runs
# post-install.sh and THEN strip_payload, and strip rewrites every binary in
# usr/bin, usr/sbin and usr/libexec in place. The single most important
# assertion in this recipe is that pkexec is setuid root, so it has to be made
# against the bytes that ship -- i.e. after the strip, which a post-install.sh
# cannot be.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

# ------------------------------------------------------------------------------
# The systemd-only files
# ------------------------------------------------------------------------------
# data/meson.build installs three things unconditionally, into directories
# derived from systemd.pc when it exists and hardcoded when it does not. Nothing
# in Duct reads any of them: there is no systemd to start polkit.service, no
# systemd-sysusers to create the polkitd account (duct-filesystem's passwd
# template already carries it, at the same uid 27 BLFS uses), and no
# systemd-tmpfiles to act on polkit-tmpfiles.conf.
#
# BLFS deals with this by pointing -Dsystemdsystemunitdir at /tmp and deleting
# afterwards. That cannot be copied here: with DESTDIR staging, /tmp is inside
# the payload -- work/install/tmp/polkit.service becomes /tmp/polkit.service on
# every installed system. So they are installed where upstream puts them and
# removed here, where the removal is visible.
rm -rf "$DESTDIR/usr/lib/systemd" \
       "$DESTDIR/usr/lib/sysusers.d" \
       "$DESTDIR/usr/lib/tmpfiles.d"

# ------------------------------------------------------------------------------
# The rules directory, and why its mode is changed
# ------------------------------------------------------------------------------
# meson_post_install.py creates /etc/polkit-1/rules.d with mode 0750 and chowns
# it root:polkitd. Upstream's arrangement is that polkitd -- which drops
# privileges to the polkitd user before it reads anything (polkitd.c calls
# become_user(POLKITD_USER)) -- reaches its own rules through GROUP membership.
#
# THAT ARRANGEMENT CANNOT BE SHIPPED BY A TAPE PACKAGE. tape zeroes ownership
# when it builds the archive -- common/tarUtils/tar.go sets header.Uid and
# header.Gid to 0 -- so every file arrives root:root and the group half of
# 0750 is lost. What survives is a directory that root can read and polkitd
# cannot, which means the rules that decide every authorization silently do not
# load. Mode bits do survive (PreserveSetuid in daemon/utils/install.go), so
# this is specifically about ownership and not about modes generally.
#
# 0755 is the answer Debian ships for the same directory, and the exposure is
# small and worth naming: the rules become world-READABLE. They are policy, not
# secrets -- they are already world-readable in /usr/share/polkit-1/rules.d,
# which upstream installs 0755 itself. Nothing becomes world-writable.
for d in etc/polkit-1 etc/polkit-1/rules.d; do
	[ -d "$DESTDIR/$d" ] || die "$d was not created; polkit would load no local rules"
	chmod 0755 "$DESTDIR/$d"
done

finish_install

# ------------------------------------------------------------------------------
# What has to be true of the payload, checked after the strip
# ------------------------------------------------------------------------------
# Every one of these is a way polkit installs successfully and authorizes
# nothing.

pkexec=$DESTDIR/usr/bin/pkexec
[ -s "$pkexec" ] || die "pkexec is missing or empty"

# THE SETUID BIT. pkexec's whole function is to run a program as another user
# after asking polkitd for permission; without setuid root it cannot, and it
# does not fail at install time or at start-up -- it fails per invocation, with
# a message about not being able to re-exec, on a system where every other part
# of polkit looks healthy. meson_post_install.py only sets the bit when the
# install runs as uid 0, which every Duct build image except duct/bootstrap
# does, so this assertion is also the check on that assumption.
[ -u "$pkexec" ] || die "pkexec is not setuid; polkit installed but cannot authorize anything"

# The same argument, for the helper that does the actual PAM conversation.
# polkit-agent-helper-1 authenticates the invoking user AND possibly root, so it
# is setuid for a reason no less load-bearing than pkexec's.
helper=$DESTDIR/usr/lib/polkit-1/polkit-agent-helper-1
[ -s "$helper" ] || die "polkit-agent-helper-1 is missing or empty"
[ -u "$helper" ] || die "polkit-agent-helper-1 is not setuid; no agent could ever authenticate a user"

# The daemon itself. It lives in the private libdir, not in /usr/bin, and it is
# what the D-Bus service file execs.
[ -s "$DESTDIR/usr/lib/polkit-1/polkitd" ] || die "polkitd is missing or empty"

# The library and its .pc, which is how everything downstream finds polkit at
# all -- gnome-control-center, gnome-settings-daemon and flatpak's system helper
# all take dependency('polkit-gobject-1').
# The soname link rather than the versioned file: -s follows symlinks, so this
# asserts the link AND its target, and it does not have to be edited if upstream
# moves the library version.
[ -s "$DESTDIR/usr/lib/libpolkit-gobject-1.so.0" ] || die "libpolkit-gobject-1 was not installed"
[ -s "$DESTDIR/usr/lib/libpolkit-agent-1.so.0" ] || die "libpolkit-agent-1 was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/polkit-gobject-1.pc" ] || die "polkit-gobject-1.pc was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/polkit-agent-1.pc" ] || die "polkit-agent-1.pc was not installed"

# -Dintrospection=true asked for this, and gnome-shell's agent is JavaScript:
# without the typelib the shell has no way to raise an authentication dialog.
[ -s "$DESTDIR/usr/lib/girepository-1.0/Polkit-1.0.typelib" ] || die "the Polkit-1.0 typelib was not built"

# THE PAM FILE, AND THE PROOF THAT -Dos_type=lfs TOOK EFFECT. If os_type had
# fallen back to its autodetected default, all four management groups would
# include "system-auth" -- a file whose only line is an `auth` rule -- and
# authentication would fail for every polkit action on a system where nothing
# else looked wrong. Checking that the file merely EXISTS would not see that,
# so its contents are checked instead.
pam=$DESTDIR/etc/pam.d/polkit-1
[ -s "$pam" ] || die "/etc/pam.d/polkit-1 was not installed; every authorization would fall through to pam_deny"
for stack in system-auth system-account system-password system-session; do
	grep -q "include *$stack\$" "$pam" \
		|| die "$pam does not include $stack -- os_type did not resolve to lfs, and polkit cannot authenticate"
done

# The admin identity. 50-default.rules is generated from privileged_group, and
# an empty or wrong group here means nobody can ever be an administrator.
rules=$DESTDIR/usr/share/polkit-1/rules.d/50-default.rules
[ -s "$rules" ] || die "50-default.rules was not installed; polkit would have no admin identity"
grep -q 'unix-group:wheel' "$rules" \
	|| die "50-default.rules does not name unix-group:wheel; the admin identity is not the group duct-filesystem creates"

# The D-Bus service file, without which nothing can start polkitd at all.
[ -s "$DESTDIR/usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service" ] \
	|| die "the D-Bus activation file was not installed; polkitd could never be started"

log "installed polkit: duktape rules engine, elogind session tracking, pkexec setuid"
