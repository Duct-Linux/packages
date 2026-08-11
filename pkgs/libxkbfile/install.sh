#!/bin/sh
# Stage libxkbfile and assert the library, its .pc and its header.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

[ -s "$DESTDIR/usr/lib/libxkbfile.so.1" ] \
	|| die "libxkbfile.so.1 is missing or dangling"

# TWO CONSUMERS RESOLVE THIS ONE FILE, and both stop if it is absent:
# xkbcomp's PKG_CHECK_MODULES(XKBCOMP, [x11 xkbfile xproto]) and xwayland's
# dependency('xkbfile'). The pkg-config name is `xkbfile`, not `libxkbfile` --
# a mismatch there would be a package that installs correctly and is found by
# nobody.
[ -s "$DESTDIR/usr/lib/pkgconfig/xkbfile.pc" ] \
	|| die "xkbfile.pc was not installed; xkbcomp and xwayland both resolve this package by the pkg-config name 'xkbfile'"

[ -s "$DESTDIR/usr/include/X11/extensions/XKBfile.h" ] \
	|| die "XKBfile.h was not installed; nothing could compile against this package"

command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify the libX11 link, and this check is not optional"
readelf -d "$DESTDIR/usr/lib/libxkbfile.so.1" 2>/dev/null | grep -q 'NEEDED.*libX11\.so' \
	|| die "libxkbfile does not link libX11; PKG_CHECK_MODULES reported x11 found but the artefact does not have it"
