#!/bin/sh
# Build glib a second time, with introspection on.

. "$(dirname "$0")/../_scripts/common.sh"

command -v meson >/dev/null 2>&1 || die "meson is not installed"

# Asserted rather than assumed: with the scanner absent meson would quietly
# configure introspection off and this package would install nothing, which the
# empty-payload check would then report as something else entirely.
command -v g-ir-scanner >/dev/null 2>&1 \
	|| die "g-ir-scanner is not installed; gobject-introspection must be built first"

rm -rf "$BUILD_DIR"

# The same options as the glib package, except introspection. They have to
# match: this compiles the same sources, and a difference in libmount or in the
# feature set would produce introspection data describing a glib that is not the
# one installed.
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	-Dintrospection=enabled \
	-Dlibmount=enabled \
	-Dselinux=disabled \
	-Dsysprof=disabled \
	-Dman-pages=disabled \
	-Ddocumentation=false \
	-Dtests=false \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
