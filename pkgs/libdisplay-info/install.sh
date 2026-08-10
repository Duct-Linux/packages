#!/bin/sh
# Stage libdisplay-info, then prove the PNP vendor table actually reached it.
#
# WHY THIS ASSERTION EXISTS, and the measurement behind it. meson.build takes
# hwdata with required:false and falls back to a hardcoded
# /usr/share/hwdata/pnp.ids. Absence is loud -- meson's files() raises at
# configure if neither path resolves. TRUNCATION IS NOT: given an empty
# pnp.ids, tool/gen-search-table.py exits 0 and writes a pnp-id-table.c with
# zero vendor entries, and the library then builds, links and installs while
# naming no monitor manufacturer. Nothing fails anywhere.
#
# The check therefore sits on the OUTCOME rather than on either input. A missing
# .pc, a truncated pnp.ids and a fallback that found something useless all
# converge on the same observable, so this is immune to the
# mechanism-versus-payload distinction that makes single-cause assertions too
# narrow. Duct's hwdata recipe asserts pci.ids only; that proves a file was
# shipped, this proves the data reached the library, and neither substitutes for
# the other.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

# Existence assertions, safe before the strip in finish_install: strip rewrites
# files without deleting them and cannot invalidate them.
[ -f "$DESTDIR/usr/lib/libdisplay-info.so" ] || die "libdisplay-info.so was not installed"

# The generated table, checked in the build tree because that is where the
# evidence is unambiguous. The output name is meson.build's custom_target output,
# read from this tarball: output: 'pnp-id-table.c'.
table=$(find "$BUILD_DIR" -name 'pnp-id-table.c' -print -quit 2>/dev/null)
[ -n "$table" ] || die "no generated pnp-id-table.c in $BUILD_DIR; the custom_target's output name may have changed"

# A real pnp.ids carries a few thousand vendors. An empty one yields a 26-line
# file with none at all, which is the case this exists to catch, so the
# threshold only has to separate "thousands" from "almost none".
entries=$(grep -c '"' "$table" 2>/dev/null || true)
[ -n "$entries" ] || entries=0
[ "$entries" -gt 500 ] || \
	die "the generated PNP table has only $entries entries; hwdata's pnp.ids was missing or truncated"

finish_install
log "installed libdisplay-info with $entries PNP vendor entries"
