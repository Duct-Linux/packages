#!/bin/sh
# Stage mutter, then prove the three things that separate a compositor from a
# library that happens to have built.
#
# WHY THE TYPELIB IS FIRST AND WHY ITS PATH IS UNUSUAL. gnome-shell is written
# in JavaScript and reaches every one of mutter's APIs through introspection --
# so a mutter with no Meta typelib is a mutter gnome-shell cannot use at all,
# while being a perfectly good C library that links, installs and satisfies
# pkg-config. And mutter does NOT install its typelibs where every other package
# in this tree does: src/meson.build 1375-1376 set
#
#     girdir=${libdir}/mutter-16
#     typelibdir=${libdir}/mutter-16
#
# so an assertion pointed at /usr/lib/girepository-1.0 would fail against a
# completely correct install. The API version is part of the path, the .pc name
# and the typelib name, which is why it is written out once here and reused.
#
# THE .pc IS ASSERTED BY ITS EXACT NAME because gnome-shell, gnome-control-center
# and gnome-settings-daemon all resolve libmutter-16 through pkg-config, and a
# tree with the library and no .pc fails one package later under a name that is
# not this one.

. "$(dirname "$0")/../_scripts/common.sh"

api=16

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/bin/mutter" ] || \
	die "the mutter binary is missing or empty; the library can build and install without the compositor that is the point of it"
[ -s "$DESTDIR/usr/lib/libmutter-$api.so" ] || \
	die "libmutter-$api.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libmutter-$api.pc" ] || \
	die "libmutter-$api.pc is missing or empty; gnome-shell, gnome-control-center and gnome-settings-daemon all resolve mutter under exactly this name"

typelib=$(find "$DESTDIR/usr/lib/mutter-$api" -name "Meta-$api.typelib" -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty Meta-$api typelib was installed. gnome-shell is JavaScript and reaches ALL of mutter through introspection, so without this it cannot use the compositor at all -- while mutter remains a perfectly good C library that links and installs. Note mutter installs typelibs to /usr/lib/mutter-$api, NOT girepository-1.0"

finish_install
log "installed mutter $api with its Meta typelib at ${typelib#"$DESTDIR"}"
