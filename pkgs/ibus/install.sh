#!/bin/sh
# Stage ibus, then prove the one file this package exists to produce.
#
# THE TYPELIB IS ASSERTED FIRST AND ALONE WOULD BE ENOUGH. ibus is in this tree
# for exactly one reason: gnome-shell 48 does `import IBus from 'gi://IBus'` in
# six JavaScript modules, one of them js/misc/dependencies.js under a heading
# that reads "Required dependencies", and gnome-shell has no build option to
# turn that off. A gjs consumer reaches ALL of ibus through introspection, so an
# ibus without IBus-1.0.typelib is an ibus that cannot do the job it was
# packaged for -- while remaining a complete, linkable, pkg-config-satisfying C
# library that every other check in this pipeline would pass.
#
# That failure mode is not hypothetical: --enable-introspection defaults to
# `auto`, and `auto` builds the typelib-less version silently. The pkg.env turns
# that into a configure failure; this turns it into an install failure, and the
# two checks fail at different times for different reasons, which is the point
# of having both. A flag that was accepted is not a file that was produced.
#
# WHY THE VERSION IN THE NAME MATTERS. gnome-shell does not ask for "IBus", it
# asks for IBus VERSION 1.0 -- `gi://IBus?version=1.0` -- and g-i resolves that
# against the typelib's own name. A typelib installed as IBus-2.0 would satisfy
# a glob and fail the import, so this looks for the exact name.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
make -C "$BUILD_DIR" DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/girepository-1.0/IBus-1.0.typelib" ] || \
	die "IBus-1.0.typelib is missing or empty. This is the ONLY reason ibus is packaged: gnome-shell imports gi://IBus?version=1.0 from six JS modules with no build option to disable it, and without this file the greeter dies at startup with 'Typelib file for namespace IBus, version 1.0 not found'. --enable-introspection defaults to 'auto', which builds a complete ibus WITHOUT the typelib and passes every other check in this pipeline"

[ -s "$DESTDIR/usr/lib/libibus-1.0.so" ] || \
	die "libibus-1.0.so is missing or empty; the typelib describes a library that has to be there to load"
[ -s "$DESTDIR/usr/lib/pkgconfig/ibus-1.0.pc" ] || \
	die "ibus-1.0.pc is missing or empty; consumers resolve ibus through pkg-config"

# The daemon, because a library and a typelib describe an input method
# framework that cannot actually run one. gnome-shell's ibusManager spawns
# ibus-daemon by name.
[ -x "$DESTDIR/usr/bin/ibus-daemon" ] || \
	die "ibus-daemon is missing or not executable; gnome-shell's ibusManager launches it by name and an ibus that cannot start is a runtime failure rather than a build one"

# The GSettings schema, which the patch moved off the legacy /desktop/ibus
# path. Asserted on the path INSIDE the file rather than on the file's
# existence: a schema that installs and then fails the tree-wide
# glib-compile-schemas pass at ISO build breaks every OTHER package's schemas
# too, and that failure names the compile step rather than ibus.
schema="$DESTDIR/usr/share/glib-2.0/schemas/org.freedesktop.ibus.gschema.xml"
[ -s "$schema" ] || die "the ibus GSettings schema was not installed"
if grep -q 'path="/desktop/ibus' "$schema"; then
	die "the ibus schema still declares the legacy /desktop/ibus path; the 0001 patch did not take, and glib-compile-schemas runs over the WHOLE installed set at ISO build, so this breaks every package's schemas and not just this one"
fi

finish_install
log "installed ibus with IBus-1.0.typelib -- the file gnome-shell's greeter will not start without"
