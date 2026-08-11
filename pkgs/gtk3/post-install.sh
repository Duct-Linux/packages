#!/bin/sh
# Assert the library, and then assert that this really is a Wayland-only GTK 3.
#
# The whole justification for packaging GTK 3 in a GTK 4 tree is narrow -- it
# exists so libnma can build, so gnome-control-center's network panel can build.
# An X11-enabled GTK 3 would satisfy that too, and would quietly link libX11,
# libXi, libXrandr and libXext into a system that runs no X server. The flags
# are the input; these are the outcome.

. "$(dirname "$0")/../_scripts/common.sh"

# --- the payload ------------------------------------------------------------
[ -s "$DESTDIR/usr/lib/libgtk-3.so" ] \
	|| die "libgtk-3.so is missing"
[ -s "$DESTDIR/usr/lib/libgdk-3.so" ] \
	|| die "libgdk-3.so is missing"
[ -s "$DESTDIR/usr/lib/pkgconfig/gtk+-3.0.pc" ] \
	|| die "gtk+-3.0.pc is missing; libnma's unconditional gtk+-3.0 dependency would not resolve and gnome-control-center's network panel could not be built"

# The typelib, which is the half of -Dintrospection=true that another package
# actually consumes. The .so existing says nothing about whether the scanner
# ran.
[ -s "$DESTDIR/usr/lib/girepository-1.0/Gtk-3.0.typelib" ] \
	|| die "Gtk-3.0.typelib is missing; -Dintrospection=true did not take effect"

# --- Wayland-only, asserted three ways --------------------------------------
# 1. THE .pc FILE'S OWN ACCOUNT OF ITSELF. meson.build 954-965 builds a
# `targets` variable from the enabled backends and writes it into gtk+-3.0.pc.
# It is the most direct statement of what was built, and it is what another
# package would read.
pc=$DESTDIR/usr/lib/pkgconfig/gtk+-3.0.pc
grep -q "^targets=.*wayland" "$pc" \
	|| die "gtk+-3.0.pc does not list wayland in targets=; -Dwayland_backend=true did not take effect"
if grep -qE "^targets=.*\bx11\b" "$pc"; then
	die "gtk+-3.0.pc lists x11 in targets=; this was built with the X11 backend on a system that runs no X server"
fi

# 2. THE INSTALLED HEADER. gdk/meson.build 164 sets GDK_WINDOWING_X11 in
# gdkconfig.h from x11_enabled, and that header is installed and read by every
# package that compiles against GTK 3. A stale or wrongly-configured build
# shows here even if the .pc were somehow right.
gdkconfig=$DESTDIR/usr/include/gtk-3.0/gdk/gdkconfig.h
[ -s "$gdkconfig" ] || die "gdkconfig.h was not installed"
if grep -q "define GDK_WINDOWING_X11" "$gdkconfig"; then
	die "gdkconfig.h defines GDK_WINDOWING_X11; the X11 backend was compiled in"
fi
grep -q "define GDK_WINDOWING_WAYLAND" "$gdkconfig" \
	|| die "gdkconfig.h does not define GDK_WINDOWING_WAYLAND; the Wayland backend was not compiled in"

# 3. THE LINKED LIBRARIES, which is the one a mistake cannot talk its way out
# of. Guarded on readelf being present rather than assumed: an assertion whose
# tool is missing has not passed, it has failed to run, so the absence is
# reported rather than skipped silently.
if command -v readelf >/dev/null 2>&1; then
	if readelf -d "$DESTDIR/usr/lib/libgdk-3.so" 2>/dev/null | grep -q "libX11.so"; then
		die "libgdk-3.so has a DT_NEEDED on libX11; this is an X11 build"
	fi
	readelf -d "$DESTDIR/usr/lib/libgdk-3.so" 2>/dev/null | grep -q "libwayland-client.so" \
		|| die "libgdk-3.so does not link libwayland-client; the Wayland backend is not really there"
else
	log "warning: readelf is unavailable, so the DT_NEEDED check DID NOT RUN."
	log "warning: the .pc and gdkconfig.h checks above still passed."
fi

# --- what was excluded ------------------------------------------------------
# -Ddemos=false and -Dexamples=false. Both default TRUE and both install
# binaries into /usr/bin, so their absence is the outcome check on two flags at
# once.
for prog in gtk3-demo gtk3-widget-factory gtk3-icon-browser; do
	if [ -e "$DESTDIR/usr/bin/$prog" ]; then
		die "$prog was installed; -Ddemos/-Dexamples did not take effect"
	fi
done

# -Dprint_backends=file,lpr, asserted as the absence of the one that would have
# arrived on its own. `auto` drops backends whose dependencies are missing
# SILENTLY, so if cups is ever packaged and this flag is lost, a cups print
# backend appears here with nothing in the recipe to explain it.
if [ -e "$DESTDIR/usr/lib/gtk-3.0/3.0.0/printbackends/libprintbackend-cups.so" ]; then
	die "a cups print backend was built; -Dprint_backends was not honoured"
fi

# The unprefixed tools. Named because GTK 4 ships gtk4-prefixed equivalents and
# these do NOT collide with them -- checked against tools/program-index.tsv
# before packaging, since two packages owning one path is a hard install error.
[ -x "$DESTDIR/usr/bin/gtk-update-icon-cache" ] \
	|| die "gtk-update-icon-cache is missing; GTK 3 applications would find no icon cache"

log "note: GTK 3 is here only so libnma can build, which gnome-control-center's"
log "note: network panel requires. It is not a second application platform."
