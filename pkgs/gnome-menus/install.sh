#!/bin/sh
# Stage gnome-menus and assert the typelib, which is the half that matters.
#
# gnome-shell is a GJS application: it reaches this library THROUGH
# INTROSPECTION and never links it. So a gnome-menus that installs its shared
# library, its headers and its .pc but no typelib satisfies every check a
# C consumer would make and is useless to the only consumer it has.
# GOBJECT_INTROSPECTION_CHECK defaults to auto, which is exactly the shape that
# produces that outcome silently.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libgnome-menu-3.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libgnome-menu-3.so.0.* was installed under /usr/lib"
[ -s "$DESTDIR/usr/lib/pkgconfig/libgnome-menu-3.0.pc" ] || die "libgnome-menu-3.0.pc is missing or empty"

# Searched by glob rather than at a fixed girepository-1.0 path: the directory
# is versioned, and a hardcoded version silently stops matching on the next
# bump -- an assertion that quietly tests nothing is worse than no assertion.
typelib=$(find "$DESTDIR/usr" -name 'GMenu-3.0.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] \
	|| die "GMenu-3.0.typelib was not installed; --enable-introspection resolved to nothing and gnome-shell -- which reaches this library only through introspection -- would find no menus"

# The menu definition itself, which is data rather than code and is installed by
# a different rule.
[ -s "$DESTDIR/etc/xdg/menus/gnome-applications.menu" ] \
	|| die "gnome-applications.menu was not installed; the library would have nothing to parse"

log "installed gnome-menus with its typelib and menu definition"
