#!/bin/sh
# Configure and build glib.
#
# Its own build stage for one reason: glib and gobject-introspection depend on
# each other. g-ir-scanner is a Python program that links glib to introspect a
# library, and glib's own GIR data is produced by g-ir-scanner. Neither can be
# first.
#
# The way out is to build glib twice. The first pass has no scanner available
# and produces a glib with no typelibs; gobject-introspection then builds
# against it; the second pass finds the scanner and produces Gio-2.0.typelib and
# the rest -- which is not optional, because gjs cannot import Gio without them
# and gnome-shell is written in JavaScript.
#
# Rather than have the two passes differ by a flag someone has to remember to
# pass, the recipe asks what is installed. First pass: no g-ir-scanner, so
# introspection is off. Second pass: it is there, so introspection is on. The
# Makefile's SECOND_PASS_PKGS is what runs the second one.

. "$(dirname "$0")/../_scripts/common.sh"

command -v meson >/dev/null 2>&1 || die "meson is not installed"

if command -v g-ir-scanner >/dev/null 2>&1; then
	introspection=enabled
	log "g-ir-scanner is present: building with introspection (second pass)"
else
	introspection=disabled
	log "no g-ir-scanner: building without introspection (first pass)"
fi

rm -rf "$BUILD_DIR"

# sysprof and selinux are disabled because neither is packaged; libmount is
# explicitly enabled because GIO's mount monitoring is what a file manager uses
# to notice a USB stick, and meson would quietly leave it out if util-linux were
# missing.
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	-Dintrospection="$introspection" \
	-Dlibmount=enabled \
	-Dselinux=disabled \
	-Dsysprof=disabled \
	-Dman-pages=disabled \
	-Ddocumentation=false \
	-Dtests=false \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
