#!/bin/sh
# Stage gnome-desktop, then prove the GTK 4 half shipped.
#
# WHY THIS ASSERTION EXISTS. This package builds TWO libraries from one source:
# libgnome-desktop-4 (GTK 4) and libgnome-desktop-3 (GTK 3, the legacy one).
# Either one alone makes the staging root non-empty, so finish_install's
# emptiness guard cannot tell "both built" from "only the legacy one did".
#
# That matters because the GTK 4 half is the whole reason this package is built
# when it is. mutter's -Dlibgnome_desktop defaults true and resolves
# dependency('gnome-desktop-4') -- the .pc, not the library -- so a
# gnome-desktop that built only its legacy half installs cleanly, passes any
# check that merely looks for "a gnome-desktop library", and then fails mutter
# several waves later under a name that is not this package's.
#
# So gnome-desktop-4.pc is asserted by the exact name mutter asks for
# (libgnome-desktop/meson.build:153 sets filebase: 'gnome-desktop-4'), rather
# than the library alone or a glob that either half would satisfy.
#
# The legacy GTK 3 library is asserted ABSENT, which is the other half of the
# same idea. -Dlegacy_library is pinned false because nothing in this tree links
# libgnome-desktop-3.0 and because gtk3 is packaged here for one consumer only
# and must not accumulate others. A flag can be misspelled, renamed upstream, or
# ignored; the file either exists or it does not, so the flag is checked by its
# effect rather than trusted. This is also what stops the dependency on gtk3
# creeping back silently -- gtk3 is built AFTER this package, so a
# libgnome-desktop-3.0 appearing here would mean it had linked something that
# did not exist yet.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/pkgconfig/gnome-desktop-4.pc" ] || \
	die "gnome-desktop-4.pc is missing or empty. This is the exact name mutter's dependency('gnome-desktop-4') resolves, and -Dbuild_gtk4 is what produces it -- without it this package installs a complete-looking libgnome-desktop-3 and mutter fails several waves later"
[ -s "$DESTDIR/usr/lib/libgnome-desktop-4.so" ] || \
	die "libgnome-desktop-4.so is missing or empty although its .pc was installed"

if [ -e "$DESTDIR/usr/lib/libgnome-desktop-3.so" ] || \
   [ -e "$DESTDIR/usr/lib/pkgconfig/gnome-desktop-3.0.pc" ]; then
	die "the legacy GTK 3 library was built despite -Dlegacy_library=false. Nothing in this tree links libgnome-desktop-3.0 -- gnome-control-center, gnome-shell and mutter all ask for gnome-desktop-4 -- and gtk3 is packaged here for libnma alone and must not accumulate consumers. gtk3 is also built AFTER this package, so this would mean linking something that does not exist yet"
fi

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'GnomeDesktop-4.0.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty GnomeDesktop-4.0 typelib was installed, but introspection was requested; gnome-shell reaches this library from JavaScript through it"

finish_install
log "installed gnome-desktop with both its GTK 4 and legacy GTK 3 libraries"
