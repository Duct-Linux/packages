#!/bin/sh
# Stage gjs, and assert that what shipped is an interpreter rather than a
# directory tree.
#
# "The package installed something" is not the question worth asking about gjs.
# It installs a library, a binary, a pkg-config file, a typelib and a pile of
# JavaScript modules, and the interesting failures leave most of that in place:
#
#   * a build that could not generate GjsPrivate-1.0.typelib still installs
#     libgjs.so, and every gnome-shell import fails at runtime;
#   * a gjs-console that did not link is absent while everything around it is
#     present, so a check on the directory passes.
#
# So each assertion below names one file and requires it to be non-empty, and
# the executable ones are required to be executable.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

# THE INTERPRETER. gnome-shell is started by running JavaScript, and this is
# what runs it.
console=$DESTDIR/usr/bin/gjs-console
[ -e "$console" ] || die "gjs-console was not installed -- this package exists to provide it"
[ -s "$console" ] || die "gjs-console was installed but is empty"
[ -x "$console" ] || die "gjs-console is not executable"

# THE PKG-CONFIG FILE. Every consumer in the tier above -- gnome-shell,
# gnome-settings-daemon -- finds gjs through this and through nothing else. A
# missing or truncated one is not a missing feature, it is those packages
# failing at configure with "gjs-1.0 not found" while gjs is installed.
pc=$DESTDIR/usr/lib/pkgconfig/gjs-1.0.pc
[ -e "$pc" ] || die "gjs-1.0.pc was not installed"
[ -s "$pc" ] || die "gjs-1.0.pc was installed but is empty"

# It must also name the library it describes; an empty-of-content .pc file is
# syntactically fine and useless.
grep -q '^Libs:' "$pc" || die "gjs-1.0.pc has no Libs: line, so nothing could link against it"

[ -s "$DESTDIR/usr/lib/libgjs.so.0" ] || \
	die "libgjs.so.0 was not installed, or is empty"

# gnome.generate_gir(libgjs) runs at build time and its output is what makes
# imports.gi work. If introspection data is missing, gjs starts and then fails
# on the first line of every GNOME script.
#
# THE PATH IS /usr/lib/gjs/girepository-1.0, NOT THE SYSTEM
# /usr/lib/girepository-1.0, and that is upstream's decision rather than an
# accident. meson.build's generate_gir call passes
#     install_dir_typelib: pkglibdir / 'girepository-1.0'
# so GjsPrivate is a PRIVATE typelib: gjs puts its own directory on the
# repository search path and nothing else is meant to import it.
#
# This assertion first named the system directory and FAILED A BUILD IN WHICH
# THE TYPELIB HAD INSTALLED PERFECTLY. The reason is recorded here because "a
# typelib is not in the directory typelibs go in" is a very natural thing to
# conclude and it is wrong -- and a check that cries wolf costs more trust than
# it buys, on a recipe whose other assertions are load-bearing.
typelib=$DESTDIR/usr/lib/gjs/girepository-1.0/GjsPrivate-1.0.typelib
[ -s "$typelib" ] || \
	die "GjsPrivate-1.0.typelib is missing or empty at $typelib; gjs would start and then fail on the first imports.gi line"

# -Dinstalled_tests=false is passed precisely so these do not ship. Assert the
# option took effect rather than trusting that it was spelled right: meson does
# not complain about a value it understood but that a later refactor moved.
if [ -d "$DESTDIR/usr/libexec/installed-tests" ]; then
	die "installed tests were staged despite -Dinstalled_tests=false"
fi

finish_install
log "installed gjs with gjs-console, gjs-1.0.pc and GjsPrivate typelib"
