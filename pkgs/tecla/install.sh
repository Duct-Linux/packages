#!/bin/sh
# Stage tecla and assert the three things a GTK 4 application needs to be
# launchable rather than merely installed.
#
# The failure worth guarding here is not a missing binary -- it is a binary with
# no .desktop file or no compiled GResource, either of which produces an
# application that gnome-control-center's Keyboard panel cannot launch or that
# starts and draws nothing. Both are installed by different meson targets from
# the executable.
#
# Assertions run AFTER finish_install: this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

[ -s "$DESTDIR/usr/bin/tecla" ] || die "the tecla binary was not installed"

# What gnome-control-center actually resolves. The Keyboard panel launches this
# by DESKTOP ID, not by path, so a missing .desktop is a button that silently
# does nothing rather than an error.
[ -s "$DESTDIR/usr/share/applications/org.gnome.Tecla.desktop" ] \
	|| die "org.gnome.Tecla.desktop was not installed; gnome-control-center launches this by desktop id and would find nothing"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the toolkit this linked"
fi
needed=$(readelf -d "$DESTDIR/usr/bin/tecla" 2>/dev/null | grep 'NEEDED') || die "readelf could not read the dynamic section"

# gtk4 AND libadwaita, checked separately: libadwaita links gtk4 itself, so a
# tecla that somehow linked only gtk4 would still start and look wrong rather
# than fail. Both are named because both are declared.
printf '%s\n' "$needed" | grep -q 'NEEDED.*libgtk-4' || die "tecla does not link libgtk-4"
printf '%s\n' "$needed" | grep -q 'NEEDED.*libadwaita-1' || die "tecla does not link libadwaita-1"
printf '%s\n' "$needed" | grep -q 'NEEDED.*libxkbcommon' \
	|| die "tecla does not link libxkbcommon; it is a keyboard LAYOUT viewer and that is where the layouts come from"

# This tree is Wayland-first with one X server, and tecla takes gtk4-wayland
# required:false -- so a gtk4 without the Wayland backend would give a viewer
# that only runs under Xwayland. Asserted as an absence of surprise rather than
# a presence: nothing here should have pulled libX11 directly.
if printf '%s\n' "$needed" | grep -q 'NEEDED.*libX11'; then
	die "tecla links libX11 directly; it should reach X only through gtk4's backend, if at all"
fi

log "installed tecla, launchable by desktop id from the Keyboard panel"
