#!/bin/sh
# Stage librest and assert what GOA resolves it by.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'librest-1.0.so.0*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no librest-1.0.so.0* was installed under /usr/lib"

# The name GOA asks pkg-config for. meson.build:130 takes `rest-1.0` with a
# subproject fallback, and under --wrap-mode=nodownload a miss here is a hard
# configure failure two packages later rather than a vendored copy -- so the
# .pc filename is the interface, not an implementation detail.
[ -s "$DESTDIR/usr/lib/pkgconfig/rest-1.0.pc" ] \
	|| die "rest-1.0.pc is missing or empty; gnome-online-accounts resolves 'rest-1.0' by that exact name and would fall through to a subproject fetch that cannot happen here"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify which libsoup major this linked"
fi
needed=$(readelf -d "$lib" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section"
printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-3\.0' \
	|| die "librest does not link libsoup-3.0"
if printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-2'; then
	die "librest links libsoup-2; -Dsoup2=false did not take"
fi

# -Dexamples=false. The examples are what would have pulled gtksourceview5 --
# which is not packaged -- so their absence is the trace of the flag rather
# than of a missing dependency.
if [ -n "$(find "$DESTDIR/usr/bin" -name 'rest-demo*' -print -quit 2>/dev/null)" ]; then
	die "a rest demo program was installed; -Dexamples=false did not take"
fi

log "installed librest against libsoup 3"
