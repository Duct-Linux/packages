#!/bin/sh
# Stage gnome-autoar, then check the name its consumer actually asks for and the
# library it must NOT have built.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# The .pc filebase is what gnome-shell's extensions-tool resolves by name --
# dependency('gnome-autoar-0') -- and it is derived, not spelled out: it is
# '@0@-@1@'.format(project_name, api_version) in gnome-autoar/meson.build:6. An
# api_version bump upstream would rename it and the library alike, and the only
# symptom would be gnome-shell failing to find a package that installed cleanly.
[ -s "$DESTDIR/usr/lib/libgnome-autoar-0.so" ] || \
	die "libgnome-autoar-0.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/gnome-autoar-0.pc" ] || \
	die "gnome-autoar-0.pc is missing or empty. gnome-shell's subprojects/extensions-tool/meson.build:32 asks for exactly this name, and the whole reason this package is in the tree is to answer that call"

# -Dgtk=false took. Asserted as an ABSENCE because the flag is not evidence: the
# option defaults TRUE and resolves gtk+-3.0 as required, so if GTK 3 were
# reachable at build time a lost flag would quietly produce this second library
# and its .pc -- a working package carrying a toolkit edge that would then have
# to be declared and ordered after NETWORK_UI_PKGS.
for gtkfile in usr/lib/libgnome-autoar-gtk-0.so usr/lib/pkgconfig/gnome-autoar-gtk-0.pc; do
	[ ! -e "$DESTDIR/$gtkfile" ] || \
		die "$gtkfile was built, so -Dgtk=false did not take. This package would then depend on GTK 3, which lives in a LATER build group than this one -- the failure would surface as an ordering error in a package that looks correct"
done

# -Dintrospection=enabled took. The upstream default is the feature value 'auto',
# which succeeds here and would silently stop producing this the day the build
# image changed.
[ -s "$DESTDIR/usr/lib/girepository-1.0/GnomeAutoar-0.1.typelib" ] || \
	die "GnomeAutoar-0.1.typelib was not installed; -Dintrospection resolved to disabled, which an 'auto' feature does without complaint"

finish_install
log "installed gnome-autoar with introspection and without the GTK 3 widgets"
