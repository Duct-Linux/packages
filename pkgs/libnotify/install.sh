#!/bin/sh
# Stage libnotify, then prove both halves of it shipped: the library its
# consumers link, and the notify-send binary that is the only part a person
# ever runs directly.
#
# WHY THIS ASSERTION EXISTS. libnotify builds a library and one small program,
# and the library alone is enough to make the staging root non-empty -- so
# finish_install's emptiness guard cannot tell a complete install from one that
# produced no binary. notify-send is also the cheapest end-to-end evidence that
# the build was configured the way this recipe intends.
#
# The .pc file is asserted for the usual reason: everything downstream finds
# libnotify through pkg-config, and a tree with the .so and no .pc fails one
# package later under a name that is not this one.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/libnotify.so" ] || \
	die "libnotify.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libnotify.pc" ] || \
	die "libnotify.pc is missing or empty; consumers resolve libnotify through pkg-config"
[ -s "$DESTDIR/usr/bin/notify-send" ] || \
	die "notify-send is missing or empty; the tools half of libnotify did not build"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'Notify-*.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty Notify typelib was installed, but introspection was requested; gjs-based code could not use libnotify"

finish_install
log "installed libnotify with notify-send and its Notify typelib"
