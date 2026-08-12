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

# --- BOTH backends, asserted three ways -------------------------------------
# THIS ASSERTION USED TO EXPECT THE OPPOSITE, and the reversal is the point
# rather than an embarrassment. It required targets= to contain wayland and NOT
# x11, because GTK 3 existed here for exactly one consumer -- libnma -- which is
# a Wayland client. The consumer set then grew: gnome-settings-daemon requires
# gtk+-x11-3.0 by name and libcanberra-gtk3 includes gdk/gdkx.h. The check was
# right for its facts and its facts changed; see pkg.env.
#
# 1. THE .pc FILE'S OWN ACCOUNT OF ITSELF. meson.build 954-965 builds a
# `targets` variable from the enabled backends and writes it into gtk+-3.0.pc.
# It is the most direct statement of what was built, and it is what another
# package's meson READS.
pc=$DESTDIR/usr/lib/pkgconfig/gtk+-3.0.pc
grep -qE "^targets=.*\bwayland\b" "$pc" \
	|| die "gtk+-3.0.pc does not list wayland in targets=; -Dwayland_backend=true did not take effect and this is the primary backend of the desktop"
grep -qE "^targets=.*\bx11\b" "$pc" \
	|| die "gtk+-3.0.pc does not list x11 in targets=; -Dx11_backend=true was lost, and gnome-settings-daemon requires gtk+-x11-3.0 BY NAME while libcanberra-gtk3 includes gdk/gdkx.h"

# The X11-specific pkg-config file, which is the thing gnome-settings-daemon
# actually asks for. The targets line and this file are produced by the same
# flag, but a consumer resolves THIS -- so it is checked as itself rather than
# inferred from the line above.
[ -s "$DESTDIR/usr/lib/pkgconfig/gtk+-x11-3.0.pc" ] \
	|| die "gtk+-x11-3.0.pc is missing; gnome-settings-daemon resolves that exact name and would fail to configure"

# 2. THE INSTALLED HEADERS, which another package's COMPILER includes.
# gdk/meson.build 164 sets GDK_WINDOWING_X11 in gdkconfig.h from x11_enabled,
# and gdk/gdkx.h is what libcanberra-gtk3 includes directly.
gdkconfig=$DESTDIR/usr/include/gtk-3.0/gdk/gdkconfig.h
[ -s "$gdkconfig" ] || die "gdkconfig.h was not installed"
grep -q "define GDK_WINDOWING_WAYLAND" "$gdkconfig" \
	|| die "gdkconfig.h does not define GDK_WINDOWING_WAYLAND; the Wayland backend was not compiled in"
grep -q "define GDK_WINDOWING_X11" "$gdkconfig" \
	|| die "gdkconfig.h does not define GDK_WINDOWING_X11; the X11 backend was not compiled in"
[ -s "$DESTDIR/usr/include/gtk-3.0/gdk/gdkx.h" ] \
	|| die "gdk/gdkx.h was not installed; libcanberra-gtk3 includes it directly and would fail to compile"

# 3. THE LINKED LIBRARIES, which is the one a mistake cannot talk its way out
# of. Guarded on readelf being present rather than assumed: an assertion whose
# tool is missing has not passed, it has failed to run.
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$DESTDIR/usr/lib/libgdk-3.so" 2>/dev/null | grep -q "libwayland-client.so" \
		|| die "libgdk-3.so does not link libwayland-client; the Wayland backend is not really there"
	readelf -d "$DESTDIR/usr/lib/libgdk-3.so" 2>/dev/null | grep -q "libX11.so" \
		|| die "libgdk-3.so does not link libX11; the X11 backend is not really there"
else
	log "warning: readelf is unavailable, so the DT_NEEDED checks DID NOT RUN."
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

log "note: GTK 3 serves three consumers now, not one: libnma for the network"
log "note: panel, gnome-settings-daemon (gtk+-x11-3.0) and libcanberra-gtk3."
log "note: It is still not a general application platform -- GTK 4 is."
