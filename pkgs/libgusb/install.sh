#!/bin/sh
# Stage libgusb, then prove the library, its pkg-config file and its typelib
# actually shipped.
#
# WHY THIS ASSERTION EXISTS. colord resolves libgusb purely through pkg-config
# under the name `gusb` -- note the .pc file is gusb.pc while the package,
# library and headers are all called libgusb. That mismatch is the trap: a tree
# that installs libgusb.so and no gusb.pc looks complete to anything reading
# filenames, and fails at colord's meson setup one package later with an error
# naming colord.
#
# The typelib is checked because introspection is switched on in pkg.env and a
# meson build will quietly produce no typelib if g-ir-scanner is unavailable,
# leaving a library that works from C and is invisible to anything using
# GObject introspection.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/libgusb.so" ] || \
	die "libgusb.so is missing or empty"

# The pkg-config name colord actually asks for. Named explicitly here because it
# does not match the package name.
[ -s "$DESTDIR/usr/lib/pkgconfig/gusb.pc" ] || \
	die "gusb.pc is missing or empty; colord asks for the pkg-config module 'gusb' and would fail to configure"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'GUsb-*.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty GUsb typelib was installed, but -Dintrospection=true was requested; g-ir-scanner probably did not run"

finish_install
log "installed libgusb with gusb.pc and its GUsb typelib"
