#!/bin/sh
# Stage dbus, and set the one bit D-Bus system activation cannot work without.
#
# This replaces the generic install-meson.sh rather than adding to
# post-install.sh, for the reason polkit's recipe records: ORDER MATTERS.
# finish_install runs post-install.sh and THEN strip_payload, and strip
# rewrites every binary under usr/bin, usr/sbin and usr/libexec. A mode is a
# PROPERTY, so anything asserting one has to run after the last step that
# touches the file, which a post-install.sh cannot be.
#
# ------------------------------------------------------------------------------
# WHY THIS IS THE RECIPE'S JOB AND NOT UPSTREAM'S
# ------------------------------------------------------------------------------
# dbus-daemon-launch-helper must be setuid root. D-Bus activation of any service
# whose .service file names a User= runs through it, and it refuses without the
# bit: "The permission of the setuid helper is not correct". Every system
# service in this tree names a User= -- elogind, polkit, accountsservice,
# upower, colord, NetworkManager, ModemManager, geoclue, wpa_supplicant,
# nm-dispatcher -- so without this, system activation cannot fire at all, for
# anything.
#
# Upstream does not set it. bus/meson.build:177 installs the helper with a bare
# `install: true` and no install_mode, and the 1.16.2 tarball contains no
# install_mode, no chmod, no 4750 and no add_install_script anywhere. The
# autotools build had an install-exec-hook that chmod'd 4750; the meson port
# dropped it and nothing failed. Measured rather than inferred: a full seeded
# build of this recipe stages the helper at 0755.
#
# ------------------------------------------------------------------------------
# WHY 4755 root:root AND NOT UPSTREAM'S 4750 root:messagebus
# ------------------------------------------------------------------------------
# DO NOT "CORRECT" THIS TO THE UPSTREAM VALUE. Upstream restricts the helper to
# the bus user's group, which is the better arrangement and is unavailable
# here. Two independent mechanisms take the group away:
#
#   - tape's archiver zeroes ownership on purpose (common/tarUtils/tar.go sets
#     header.Uid and header.Gid to 0), so NO package can ship a file owned by
#     anything but root. Measured across the whole published index: 0 of
#     251,608 entries has a non-zero owner.
#   - images' build-iso.sh packs the rootfs with `mksquashfs -all-root`, which
#     forces every file on the medium to root:root. The setuid BIT survives
#     that; the GROUP does not.
#
# So 4750 root:messagebus arrives as 4750 root:root -- executable by nobody but
# root -- and dbus-daemon, which runs as messagebus, cannot exec its own
# helper. That was measured on a booted medium: identical mode, works in a
# container as uid 18, EACCES on the ISO, nosuid refuted from /proc/mounts.
# 4755 is what made accounts-daemon start for the first time in this tree.
# The restriction has to come from the mode, because the group cannot survive.
#
# A chown here would also be wrong for a third reason: the build container has
# no messagebus group, and a builder that happened to have one would silently
# bake in the wrong gid.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

helper=$DESTDIR/usr/libexec/dbus-daemon-launch-helper

# An EXISTENCE assertion, safe before strip: strip rewrites files without
# deleting them, so finish_install cannot invalidate it. If this fires, the
# helper was not built at all and the chmod below would create nothing.
[ -f "$helper" ] || die "dbus-daemon-launch-helper was not installed; system activation could never work"

finish_install

# The chmod runs AFTER finish_install, deliberately, and this differs from
# fuse3 on purpose. fuse3 sets the bit before the strip and notes in its own
# comment that survival is "a fact about one binutils rather than a guarantee".
# Setting it afterwards removes the dependency entirely: nothing runs between
# this line and the packaging.
chmod 4755 "$helper" || die "could not set the setuid bit on dbus-daemon-launch-helper"

case $(ls -l "$helper") in
	-rws*) ;;
	*) die "dbus-daemon-launch-helper is not setuid; D-Bus could not activate a single system service" ;;
esac

# NOTE FOR WHOEVER READS A GREEN BUILD HERE. This assertion checks $DESTDIR --
# the staged tree -- and that is ALL it can check. Until tape's publish path is
# fixed, `tape-repo add-to-repo` extracts each package with PreserveSetuid
# false and re-tars the extraction, so the bit is destroyed on its way into the
# repository and this assertion cannot see it happen. It has to be verified
# against the DOWNLOADED PUBLISHED PAYLOAD as well, once, after the republish.
# Every other setuid assertion in this tree (fuse3, polkit, shadow) has been
# passing for exactly this reason while shipping 0755.

log "installed dbus with dbus-daemon-launch-helper setuid root"
