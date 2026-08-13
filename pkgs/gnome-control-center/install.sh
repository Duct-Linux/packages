#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"
cd "$BUILD_DIR"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"
[ -x "$DESTDIR/usr/bin/gnome-control-center" ] || die "GNOME Settings binary was not installed"
[ -s "$DESTDIR/usr/share/applications/org.gnome.Settings.desktop" ] || die "GNOME Settings desktop entry was not installed"
finish_install

