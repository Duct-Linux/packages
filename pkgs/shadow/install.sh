#!/bin/sh
# Stage shadow.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# exec_prefix=/usr rather than the configured default: shadow otherwise splits
# its commands between /usr/bin and /bin, and /bin is a symlink to /usr/bin
# here -- so the second half would land on top of the first.
make DESTDIR="$DESTDIR" exec_prefix=/usr install || die "make install failed"

# tape cannot represent a setuid bit (daemon/utils/install.go strips it), so
# passwd, chage and friends arrive unprivileged and a non-root user cannot
# change their own password. The image build restores the bits; recorded here so
# the reason is attached to the package that needs it.
log "note: setuid bits on passwd/chage/newgrp must be restored at image assembly"

[ -x "$DESTDIR/usr/bin/passwd" ] || die "passwd was not installed"
[ -x "$DESTDIR/usr/sbin/useradd" ] || die "useradd was not installed"

finish_install
log "installed shadow"
