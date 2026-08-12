#!/bin/sh
# Stage geocode-glib and prove it resolved libsoup 3 rather than 2.
#
# The failure this guards is not subtle at build time -- -Dsoup2=true would stop
# at configure, because no libsoup-2.4 exists here. What it guards is the
# opposite direction: the option defaults TRUE, so the interesting state is a
# recipe that quietly loses the flag and starts failing for a reason that reads
# as "libsoup is broken" rather than "this recipe asked for the wrong major".
#
# Asserted on the link rather than on the flag, so the answer comes from the
# artefact either way.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# files, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libgeocode-glib-2.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libgeocode-glib-2.so.0.* was installed under /usr/lib"

pc=$DESTDIR/usr/lib/pkgconfig/geocode-glib-2.0.pc
[ -s "$pc" ] || die "geocode-glib-2.0.pc is missing or empty; libgweather resolves it through pkg-config by that exact name"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify which libsoup major this linked"
fi
needed=$(readelf -d "$lib" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section"

printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-3\.0' \
	|| die "libgeocode-glib does not link libsoup-3.0; -Dsoup2 defaults TRUE and this build did not override it"
if printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-2'; then
	die "libgeocode-glib links libsoup-2; -Dsoup2=false did not take"
fi

# -Denable-introspection=true, asserted by NAME because a GJS consumer resolves
# it by name. Searched by glob rather than at a fixed path: the typelib
# directory is versioned, and a hardcoded version silently stops matching on the
# next bump -- an assertion that quietly tests nothing.
gir=$(find "$DESTDIR/usr" -name 'GeocodeGlib-2.0.typelib' -print -quit 2>/dev/null)
[ -n "$gir" ] && [ -s "$gir" ] || die "GeocodeGlib-2.0.typelib was not installed; -Denable-introspection produced nothing"

# -Denable-installed-tests=false, asserted as an absence: the option defaults
# TRUE and what it installs are files under a directory half of GNOME writes
# into, where identically-named files are a hard install conflict.
if [ -e "$DESTDIR/usr/share/installed-tests" ]; then
	die "installed-tests were staged; -Denable-installed-tests=false did not take"
fi

log "installed geocode-glib against libsoup 3"
