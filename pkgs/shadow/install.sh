#!/bin/sh
# Stage shadow.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# exec_prefix=/usr rather than the configured default: shadow otherwise splits
# its commands between /usr/bin and /bin, and /bin is a symlink to /usr/bin
# here -- so the second half would land on top of the first.
make DESTDIR="$DESTDIR" exec_prefix=/usr install || die "make install failed"

# The setuid bits on passwd, chage, newgrp, su and expiry are deliberate and are
# carried by the package: the archive records them and the daemon's install path
# preserves them. Checked rather than assumed, because a non-root user who
# cannot change their own password is a failure that only shows up in use.
for b in passwd chage newgrp; do
	f=$DESTDIR/usr/bin/$b
	[ -f "$f" ] || continue
	case $(ls -l "$f") in
		-rws*) ;;
		*) die "$b is not setuid; a non-root user could not change a password" ;;
	esac
done

[ -x "$DESTDIR/usr/bin/passwd" ] || die "passwd was not installed"
[ -x "$DESTDIR/usr/sbin/useradd" ] || die "useradd was not installed"

finish_install
log "installed shadow"
