#!/bin/sh
# Stage libgudev and assert it is a usable library rather than a directory tree.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The library itself, through its soname link: -s follows the link, so this
# asserts both that the link exists and that its target is a non-empty file.
[ -s "$DESTDIR/usr/lib/libgudev-1.0.so.0" ] || die "libgudev-1.0 was not installed"

# The .pc is how everything downstream finds it -- upower takes
# dependency('gudev-1.0', version: '>= 238') and stops without it.
pc=$DESTDIR/usr/lib/pkgconfig/gudev-1.0.pc
[ -s "$pc" ] || die "gudev-1.0.pc was not installed"

# THE TYPELIB, which is the whole reason -Dintrospection=enabled is passed. A
# libgudev without it is a C library that no GNOME component written in
# JavaScript or Python can use, and nothing about the build says so: the
# introspection option is a 'feature' defaulting to auto, so a missing scanner
# turns the typelib off and the build still succeeds.
[ -s "$DESTDIR/usr/lib/girepository-1.0/GUdev-1.0.typelib" ] \
	|| die "the GUdev-1.0 typelib was not built; introspection resolved to disabled"
[ -s "$DESTDIR/usr/share/gir-1.0/GUdev-1.0.gir" ] \
	|| die "the GUdev-1.0 gir was not installed"

log "installed libgudev with introspection"
