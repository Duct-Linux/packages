#!/bin/sh
# Stage PyGObject and assert the one thing its consumer actually does.
#
# The check that matters here is not "did files install" -- it is whether
# `from gi.repository import GLib` will work, which is the exact line
# libgweather's build runs. That involves three separate pieces installed by
# three different meson targets: the `gi` package itself, the compiled
# `_gi` extension module it imports, and an overrides directory. Any one of
# them missing gives an ImportError at libgweather's build rather than here.
#
# Assertions run AFTER finish_install: strip is the last step to touch the
# extension module, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# Found by glob rather than at a fixed python3.13 path: the site-packages
# directory is versioned, and a hardcoded version silently stops matching on the
# next python bump -- an assertion that quietly tests nothing is worse than
# none.
gi_init=$(find "$DESTDIR/usr/lib" -path '*/site-packages/gi/__init__.py' -print -quit 2>/dev/null)
[ -n "$gi_init" ] && [ -s "$gi_init" ] || die "the gi package was not installed under any site-packages; 'from gi.repository import GLib' would be ModuleNotFoundError"
gi_dir=$(dirname "$gi_init")

# The compiled extension. `gi/__init__.py` imports `_gi` immediately, so the
# pure-Python half alone is an ImportError rather than a degraded module.
ext=$(find "$gi_dir" -maxdepth 1 -name '_gi*.so' -print -quit 2>/dev/null)
[ -n "$ext" ] && [ -s "$ext" ] || die "the _gi extension module was not installed beside gi/__init__.py; the Python half cannot import without it"

# The overrides, which is what makes gi.repository.GLib a usable GLib rather
# than a raw introspection wrapper -- and it is a separate install target.
[ -s "$gi_dir/overrides/GLib.py" ] || die "gi/overrides/GLib.py was not installed; gi.repository.GLib would import without its overrides"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify what the extension module links"
fi
needed=$(readelf -d "$ext" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section of $ext"

# girepository-2.0, from glib rather than from gobject-introspection. Asserted
# because the name misleads: a reader checking this recipe's dependency list
# against the library name would expect gobject-introspection, and the link is
# what settles it.
printf '%s\n' "$needed" | grep -q 'NEEDED.*libgirepository-2\.0' \
	|| die "_gi does not link libgirepository-2.0; this build resolved a different girepository than the one glib ships"

# -Dpycairo=disabled, asserted as an absence. The option is `auto`, so it would
# switch itself on the day anybody packages pycairo -- changing this artefact
# with no change to this recipe.
if [ -e "$gi_dir/_gi_cairo.so" ] || printf '%s\n' "$needed" | grep -q 'NEEDED.*libcairo'; then
	die "a cairo integration was built; -Dpycairo=disabled did not take"
fi

log "installed PyGObject; gi, _gi and the GLib overrides are all present"
