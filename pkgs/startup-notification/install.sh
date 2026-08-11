#!/bin/sh
# Stage startup-notification and prove the library and its .pc shipped.
#
# The .pc name is libstartup-notification-1.0, which is NOT derived from the
# package name in the way most are -- mutter asks for it by that exact string
# (dependency('libstartup-notification-1.0')), so it is asserted literally
# rather than by a glob that a differently-named file would satisfy.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libstartup-notification-1.so" ] || \
	die "libstartup-notification-1.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libstartup-notification-1.0.pc" ] || \
	die "libstartup-notification-1.0.pc is missing or empty; mutter resolves it by that exact name"

finish_install
log "installed startup-notification"
