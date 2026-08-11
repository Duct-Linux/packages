#!/bin/sh
# Stage xcb-util, then assert the two .pc files its only consumer asks for BY
# NAME rather than the library.
#
# WHY BY NAME. One shared library, libxcb-util.so, backs four pkg-config files:
# xcb-util.pc, xcb-aux.pc, xcb-event.pc and xcb-atom.pc. startup-notification
# does not ask for the library or for "xcb-util" -- it asks for xcb-aux and
# xcb-event specifically, each with a hard PKG_CHECK_MODULES. So asserting
# libxcb-util.so would pass on a build that installed the library and, for
# whatever reason, not those two files, and the failure would appear in
# startup-notification's configure against a package that looks complete.
#
# This is also the check that would catch the wrong xcb-util being packaged:
# upstream split these into five tarballs and the other four ship none of these
# names.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libxcb-util.so" ] || die "libxcb-util.so is missing or empty"
for pc in xcb-aux xcb-event; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc.pc" ] || \
		die "$pc.pc is missing or empty; startup-notification's configure asks pkg-config for '$pc' by that exact name, and only the BASE xcb-util tarball provides it"
done

finish_install
log "installed xcb-util with xcb-aux and xcb-event"
