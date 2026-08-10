#!/bin/sh
# Stage libcap. Its makefile installs from the source tree, not a build tree.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make DESTDIR="$DESTDIR" prefix=/usr lib=lib install || die "make install failed"

[ -e "$DESTDIR/usr/lib/libcap.so" ] || die "libcap.so was not installed"

finish_install
log "installed libcap"
