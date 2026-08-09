#!/bin/sh
# Stage libsass.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
export LIBSASS_VERSION=3.6.6

make DESTDIR="$DESTDIR" PREFIX=/usr install-shared || die "make install failed"

# The Makefile installs into $PREFIX/lib64 on a 64-bit host, the same trap meson
# and cmake fall into: on a merged-/usr layout nothing searches there.
if [ -d "$DESTDIR/usr/lib64" ]; then
	install -d "$DESTDIR/usr/lib"
	cp -a "$DESTDIR/usr/lib64/." "$DESTDIR/usr/lib/"
	rm -rf "$DESTDIR/usr/lib64"
fi

[ -e "$DESTDIR/usr/lib/libsass.so" ] || die "libsass.so was not installed"

finish_install
log "installed libsass"
