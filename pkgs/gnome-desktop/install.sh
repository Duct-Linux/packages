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
# The legacy GTK 3 library is asserted PRESENT, and this assertion was itself
# wrong for four hours -- which is worth recording here rather than quietly
# fixing, because the failure is instructive.
#
# When -Dlegacy_library was (mistakenly) turned off, this file asserted the
# library was ABSENT, on the reasoning that a pinned flag should be checked by
# its effect. That reasoning was right and the flag was wrong. When the flag was
# corrected to true, THIS CHECK WAS NOT, so CI failed with:
#
#     error: the legacy GTK 3 library was built despite -Dlegacy_library=false
#
# The assertion did exactly its job: it caught a mismatch between what the
# recipe intended and what the build produced. The mismatch was that the recipe
# had two statements of intent -- the flag and the check -- and only one of them
# had been updated. An outcome assertion is a second copy of the decision, and
# it goes stale in the same way a comment does.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/pkgconfig/gnome-desktop-4.pc" ] || \
	die "gnome-desktop-4.pc is missing or empty. This is the exact name mutter's dependency('gnome-desktop-4') resolves, and -Dbuild_gtk4 is what produces it -- without it this package installs a complete-looking libgnome-desktop-3 and mutter fails several waves later"
[ -s "$DESTDIR/usr/lib/libgnome-desktop-4.so" ] || \
	die "libgnome-desktop-4.so is missing or empty although its .pc was installed"

[ -s "$DESTDIR/usr/lib/pkgconfig/gnome-desktop-3.0.pc" ] || \
	die "gnome-desktop-3.0.pc is missing or empty. gnome-session (meson.build:97) and gnome-settings-daemon (meson.build:104) both require gnome-desktop-3.0 unconditionally, so the session does not start without it"
[ -s "$DESTDIR/usr/lib/libgnome-desktop-3.so" ] || \
	die "libgnome-desktop-3.so is missing or empty although its .pc was installed"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'GnomeDesktop-4.0.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty GnomeDesktop-4.0 typelib was installed, but introspection was requested; gnome-shell reaches this library from JavaScript through it"

finish_install
log "installed gnome-desktop with both its GTK 4 and legacy GTK 3 libraries"
