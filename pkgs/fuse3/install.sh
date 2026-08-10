#!/bin/sh
# Stage fuse3, then assert the one bit this package exists to carry.
#
# fusermount3 must ship SETUID ROOT. It is the only way an unprivileged process
# mounts a FUSE filesystem, and two shipped features depend on it: flatpak's
# revokefs-fuse, and every type-2 AppImage -- whose runtime walks $PATH for a
# binary named fusermount plus optional digits, checks that it is setuid root,
# and refuses to run when it finds none.
#
# pkg.env builds with -Duseroot=false, so upstream's install helper does NOT set
# the bit (it would also try to mknod /dev/fuse into the staging root, which
# needs privileges the build does not have). Setting it is therefore this
# script's job, and asserting it is the point: a fuse3 that installs cleanly
# without the bit produces a package where AppImages fail at run time on a system
# that looks entirely correct.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

fusermount=$DESTDIR/usr/bin/fusermount3

# An EXISTENCE assertion, and safe here: strip rewrites files without deleting
# them, so finish_install cannot invalidate it.
[ -f "$fusermount" ] || die "fusermount3 was not installed; is -Dutils still true?"

# Upstream would have done this in install_helper.sh under -Duseroot=true. Doing
# it here instead is what lets the build stay unprivileged. tape carries the
# mode: the archive records it and the daemon's install path preserves it, which
# is how shadow ships passwd setuid.
chmod 4755 "$fusermount" || die "could not set the setuid bit on fusermount3"

# finish_install runs strip --strip-all over usr/bin, and the check below is a
# PROPERTY assertion, so it must come after.
#
# The rule, measured rather than assumed: an EXISTENCE assertion is safe before
# strip, because strip rewrites files without deleting them and cannot
# invalidate one. A PROPERTY assertion is not -- anything asserting a file's
# mode, ownership or size has to run after the last step that touches the file.
# On this binutils strip does in fact preserve setuid, so nothing is broken
# today; that is a fact about one binutils rather than a guarantee, and an
# assertion that does not cover the file which actually ships is worth nothing.
finish_install

case $(ls -l "$fusermount") in
	-rws*) ;;
	*) die "fusermount3 is not setuid after staging; AppImages and flatpak would both fail at run time" ;;
esac

# The config the binary was compiled to look for. -Dsysconfdir=/etc in pkg.env is
# what keeps this out of /usr/etc, and the failure it prevents is silent, so it
# is worth one line to confirm the two agree.
[ -f "$DESTDIR/etc/fuse.conf" ] || die "fuse.conf is not at /etc/fuse.conf; check -Dsysconfdir"

log "installed fuse3 with fusermount3 setuid root"
