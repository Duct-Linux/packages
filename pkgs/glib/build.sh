#!/bin/sh
# Configure and build glib.
#
# Its own build stage because glib and gobject-introspection depend on each
# other and something has to break the cycle: g-ir-scanner links glib, and
# glib's own typelibs are produced by g-ir-scanner, so neither can be first.
#
# glib breaks it by never producing introspection data. What GNOME actually
# needs -- GLib-2.0.typelib, GObject-2.0.typelib, Gio-2.0.typelib, without which
# gjs cannot import Gio and gnome-shell is written in JavaScript -- is built by
# the glib-introspection package, which compiles this same source a second time
# once the scanner exists and installs nothing but the .gir and .typelib files.
#
# That is a deliberate change from doing it as a second pass over this recipe.
# A second pass is invisible to anything reading the dependency graph: CI
# schedules package builds in dependency waves derived from that graph, and
# "build this one twice, in the middle" is not something a graph can say. As a
# separate package it is an ordinary node that both the Makefile's order and
# CI's levelling already understand.

. "$(dirname "$0")/../_scripts/common.sh"

command -v meson >/dev/null 2>&1 || die "meson is not installed"

rm -rf "$BUILD_DIR"

# sysprof and selinux are disabled because neither is packaged; libmount is
# explicitly enabled because GIO's mount monitoring is what a file manager uses
# to notice a USB stick, and meson would quietly leave it out if util-linux were
# missing.
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	-Dintrospection=disabled \
	-Dlibmount=enabled \
	-Dselinux=disabled \
	-Dsysprof=disabled \
	-Dman-pages=disabled \
	-Ddocumentation=false \
	-Dtests=false \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
