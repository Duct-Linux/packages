#!/bin/sh
# Stage libusb, then prove the library and its pkg-config file shipped.
#
# WHY THIS ASSERTION EXISTS. libgusb finds libusb only through pkg-config
# (libgusb-0.4.9/meson.build line 103, dependency('libusb-1.0')). A staged tree
# carrying the shared object but no libusb-1.0.pc builds and installs perfectly
# and then fails one package later, at libgusb's meson setup, with an error that
# names libgusb rather than libusb. Asserting the .pc file here moves that
# failure to the package that actually caused it.
#
# Both checks are -s rather than -f: an interrupted install can leave a
# zero-length file, which passes an existence test and fails at link time.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libusb-1.0.so" ] || \
	die "libusb-1.0.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libusb-1.0.pc" ] || \
	die "libusb-1.0.pc is missing or empty; libgusb resolves libusb through pkg-config and would fail to configure"
[ -s "$DESTDIR/usr/include/libusb-1.0/libusb.h" ] || \
	die "libusb.h is missing or empty; nothing can compile against libusb without it"

finish_install
log "installed libusb with libusb-1.0.pc and headers"
