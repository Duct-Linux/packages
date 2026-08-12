#!/bin/sh
# Stage libgweather and assert the generated location database is real.
#
# WHAT CAN GO WRONG HERE THAT NOTHING ELSE WOULD CATCH. The package's most
# important output is not a library: it is Locations.bin, a GVariant blob
# generated at build time by a Python script from a 4 MB XML file. The script
# needs PyGObject, and an ImportError there is a build failure -- loud. But the
# blob is also the thing that would be silently EMPTY or truncated if the
# generator half-ran, and a libgweather with an empty location database is a
# weather panel that finds no cities while every library check passes.
#
# So this asserts on the file's SIZE as well as its existence, and on the XML it
# is generated from, which is installed separately.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# files, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libgweather-4.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libgweather-4.so.0.* was installed under /usr/lib"
[ -s "$DESTDIR/usr/lib/pkgconfig/gweather4.pc" ] || die "gweather4.pc is missing or empty"

# THE GENERATED DATABASE. Searched by glob because it lands in a versioned
# pkglibdir, and checked for a plausible SIZE rather than mere existence: the
# generator writes its output incrementally, so a half-run leaves a small file
# rather than no file. Locations.xml is ~4 MB of source; a serialised database
# under 100 KB means the generator did not do its job.
locbin=$(find "$DESTDIR/usr/lib" -name 'Locations.bin' -print -quit 2>/dev/null)
[ -n "$locbin" ] || die "Locations.bin was not generated; gen_locations_variant.py did not run -- it needs PyGObject, which is what python-pygobject is packaged for"
size=$(wc -c <"$locbin")
[ "$size" -gt 100000 ] || die "Locations.bin is only $size bytes; the generator produced a truncated database and this libgweather would find almost no cities"

# The XML the database is generated FROM, installed separately by a different
# meson target -- so the two can go missing independently.
[ -s "$DESTDIR/usr/share/libgweather-4/Locations.xml" ] || die "Locations.xml was not installed"

# -Dintrospection=true, asserted by name because a GJS consumer resolves it by
# name. Glob rather than a fixed path: the typelib directory is versioned.
typelib=$(find "$DESTDIR/usr" -name 'GWeather-4.0.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || die "GWeather-4.0.typelib was not installed; -Dintrospection produced nothing"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify which libsoup major this linked"
fi
needed=$(readelf -d "$lib" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section"
printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-3\.0' \
	|| die "libgweather does not link libsoup-3.0"
if printf '%s\n' "$needed" | grep -q 'NEEDED.*libsoup-2'; then
	die "libgweather links libsoup-2; -Dsoup2=false did not take"
fi
printf '%s\n' "$needed" | grep -q 'NEEDED.*libgeocode-glib' \
	|| die "libgweather does not link libgeocode-glib; the geocoding half of this package is absent"

# BLFS lists GTK 3 as Required for this package and it is not: the only `gtk` in
# the whole meson tree is the gtk_doc option. Asserted as an absence so that
# claim stays checked rather than remembered -- if a future version really does
# grow a GTK dependency, this fails and the gtk3 island question gets asked
# again deliberately.
if printf '%s\n' "$needed" | grep -qE 'NEEDED.*libgtk-[34]'; then
	die "libgweather links a GTK library; BLFS claims GTK 3 is required and 4.4.4's meson says otherwise -- if that changed, the gtk3 island policy needs a decision rather than a silent edge"
fi

log "installed libgweather with a $(( size / 1024 )) KB location database"
