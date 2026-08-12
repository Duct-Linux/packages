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

# The GTK 3 widgets ARE expected, and this assertion is the reversal of the one
# that first shipped here.
#
# It originally asserted these files were ABSENT, on the belief that -Dgtk=false
# disabled them. CI failed on that assertion -- correctly -- and the reason is
# worth keeping: meson.build:94-101 passes a BOOLEAN option to `required:`, and
# `required: false` means "do not fail if missing", not "do not look". GTK 3 is
# in the seeded build image, so the search finds it, and enable_gtk comes from
# .found() rather than from the option. The flag never had the power to decline.
#
# So the widgets are accepted rather than chosen, gtk3 is a declared dependency,
# and this package now sits in GNOME_UI_PKGS after gtk3. Asserted positively so
# that a future build which somehow DID drop them shows up here rather than as a
# surprise in a consumer -- and so this file cannot quietly go back to claiming
# an absence that the build system will not honour.
for gtkfile in usr/lib/libgnome-autoar-gtk-0.so usr/lib/pkgconfig/gnome-autoar-gtk-0.pc; do
	[ -s "$DESTDIR/$gtkfile" ] || \
		die "$gtkfile is missing, so the GTK 3 widgets did not build. That is unexpected here: the gtk option cannot switch them off while gtk+-3.0 is present, so this means gtk3 was NOT found at build time and the declared dependency did not reach the image"
done

# -Dintrospection=enabled took. The upstream default is the feature value 'auto',
# which succeeds here and would silently stop producing this the day the build
# image changed.
[ -s "$DESTDIR/usr/lib/girepository-1.0/GnomeAutoar-0.1.typelib" ] || \
	die "GnomeAutoar-0.1.typelib was not installed; -Dintrospection resolved to disabled, which an 'auto' feature does without complaint"

finish_install
log "installed gnome-autoar with introspection and without the GTK 3 widgets"
