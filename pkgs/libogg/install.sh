#!/bin/sh
# Stage libogg and prove the shared library and its .pc both shipped.
#
# The .pc is asserted because libvorbis finds libogg through pkg-config, and a
# tree with the .so and no ogg.pc fails one package later under a name that is
# not this one -- the same failure ncurses had when it was built before pkgconf
# and silently installed no .pc files at all.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libogg.so" ] || die "libogg.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/ogg.pc" ] || \
	die "ogg.pc is missing or empty; libvorbis resolves libogg through pkg-config"

finish_install
log "installed libogg"
