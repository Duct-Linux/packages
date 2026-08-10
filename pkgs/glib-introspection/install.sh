#!/bin/sh
# Stage only the introspection data.
#
# The build produced a complete glib; every part of it except the .gir and
# .typelib files is already owned by the glib package, and two packages owning
# one path is a hard install error in tape with no override. So this installs
# the lot into the staging root and then removes everything that is not
# introspection data.

. "$(dirname "$0")/../_scripts/common.sh"

DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

# Keep exactly two trees.
staged=$(mktemp -d) || die "cannot create a temporary directory"
for d in usr/share/gir-1.0 usr/lib/girepository-1.0; do
	if [ -d "$DESTDIR/$d" ]; then
		install -d "$staged/$d"
		cp -a "$DESTDIR/$d/." "$staged/$d/"
	fi
done

find "$DESTDIR" -mindepth 1 -delete 2>/dev/null || rm -rf "${DESTDIR:?}"/*
install -d "$DESTDIR"
cp -a "$staged/." "$DESTDIR/"
rm -rf "$staged"

# The four that matter. gjs imports Gio, and gnome-shell is JavaScript.
for gir in GLib-2.0 GObject-2.0 GModule-2.0 Gio-2.0; do
	[ -f "$DESTDIR/usr/lib/girepository-1.0/$gir.typelib" ] \
		|| die "$gir.typelib was not produced; introspection did not run"
done

finish_install
log "installed introspection data for GLib, GObject, GModule and Gio"
