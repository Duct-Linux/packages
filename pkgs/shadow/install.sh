#!/bin/sh
# Stage shadow.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# exec_prefix=/usr rather than the configured default: shadow otherwise splits
# its commands between /usr/bin and /bin, and /bin is a symlink to /usr/bin
# here -- so the second half would land on top of the first.
make DESTDIR="$DESTDIR" exec_prefix=/usr install || die "make install failed"

finish_install

# The setuid bits on passwd, chage, newgrp, su and expiry are deliberate and are
# carried by the package: the archive records them and the daemon's install path
# preserves them.
#
# Checked AFTER finish_install, not before, and the ordering is the point.
# finish_install runs strip --strip-all over usr/bin, and strip on some
# toolchains recreates the file rather than editing it in place -- which drops
# the setuid bit. An assertion placed before that would be validating an
# intermediate artefact and would pass forever while the shipped binary
# silently lacked the property it guards.
#
# Measured on this toolchain: the bit does survive, and the shipped tarball has
# -rwsr-xr-x. The assertion is placed here anyway, because that is a fact about
# this binutils rather than a guarantee, and a non-root user who cannot change
# their own password is a failure that only shows up in use.
for b in passwd chage newgrp; do
	f=$DESTDIR/usr/bin/$b
	[ -f "$f" ] || continue
	case $(ls -l "$f") in
		-rws*) ;;
		*) die "$b is not setuid after strip; a non-root user could not change a password" ;;
	esac
done

log "installed shadow"
