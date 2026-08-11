#!/bin/sh
# Stage gnome-backgrounds, then prove actual image data reached the tree.
#
# WHY THIS ASSERTION EXISTS, and why it counts files rather than naming one.
# This package is pure data, which makes it the easiest kind to ship broken:
# there is no compiler to fail and no linker to complain. A meson install that
# staged only the XML property files -- or only the locale directories -- would
# leave a non-empty staging root, pass finish_install's emptiness guard, publish
# cleanly, and produce a desktop whose wallpaper setting points at nothing.
#
# So the check sits on the payload: there must be real image files, and they
# must not be zero-length. A specific filename is deliberately not asserted,
# because upstream renames and re-crops the wallpaper set every cycle and a
# recipe that hardcodes one becomes a maintenance trap at the next bump. The
# threshold only has to separate "a wallpaper set" from "almost nothing".

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

bg_dir="$DESTDIR/usr/share/backgrounds/gnome"
[ -d "$bg_dir" ] || die "no /usr/share/backgrounds/gnome directory was installed"

# -size +1k rather than merely counting names: a truncated or zero-length image
# is exactly what a partially-staged tree leaves behind, and it passes any test
# that only looks for the file.
images=$(find "$bg_dir" -type f \( -name '*.jpg' -o -name '*.jxl' -o -name '*.png' -o -name '*.webp' \) -size +1k 2>/dev/null | wc -l)
[ "${images:-0}" -ge 4 ] || \
	die "only $images non-trivial wallpaper images were installed; the image payload did not reach the staging root"

# The XML is what gnome-control-center's Appearance panel and the shell read to
# enumerate wallpapers. Images without it are invisible to the desktop.
props=$(find "$DESTDIR/usr/share/gnome-background-properties" -name '*.xml' -size +0 2>/dev/null | wc -l)
[ "${props:-0}" -ge 1 ] || \
	die "no gnome-background-properties XML was installed; the wallpapers would not be listed by the desktop"

finish_install
log "installed gnome-backgrounds with $images images and $props property files"
