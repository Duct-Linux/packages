#!/bin/sh
# Stage libcanberra, then prove the ALSA backend was actually built.
#
# WHY THE BACKEND RATHER THAN THE LIBRARY. libcanberra is a thin core plus a set
# of pluggable backend modules, and the core builds and installs perfectly with
# NO backend at all -- configure treats alsa, pulse, gstreamer, oss and null as
# independent optional features. A libcanberra with only the null backend
# installs cleanly, links fine, satisfies mutter's dependency('libcanberra'),
# and plays absolutely nothing.
#
# alsa is the only backend packaged in this tree, so libcanberra-alsa.so is the
# single file that separates "event sounds work" from "event sounds are silent",
# and neither the library nor the .pc distinguishes them.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libcanberra.so" ] || die "libcanberra.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/libcanberra.pc" ] || \
	die "libcanberra.pc is missing or empty; mutter resolves libcanberra through pkg-config"

backend=$(find "$DESTDIR/usr/lib/libcanberra-0.30" -name 'libcanberra-alsa.so' -print -quit 2>/dev/null)
[ -n "$backend" ] && [ -s "$backend" ] || \
	die "the ALSA backend module was not built. libcanberra's core installs cleanly with NO backend -- alsa, pulse, gstreamer and oss are all independent optional features -- and alsa is the only one packaged here, so without this module every event sound is silent while the library, the .pc and mutter's dependency check all look correct"

# THE GTK 3 HELPER IS ASSERTED TOO, AND IT IS ASSERTED HERE BECAUSE THE FLAG
# THAT BUILDS IT AND THE CHECK THAT PROVES IT ARE A PAIR THAT CHANGES TOGETHER.
#
# gnome-settings-daemon 48.1 meson.build:109 takes dependency('libcanberra-gtk3')
# unconditionally, so a libcanberra without this .pc fails g-s-d under a name
# that is not this package's. And the helper is exactly what failed to compile
# when gtk3 had no X11 backend -- it includes gdk/gdkx.h -- so its presence is
# also the evidence that the toolkit correction reached this build.
[ -s "$DESTDIR/usr/lib/pkgconfig/libcanberra-gtk3.pc" ] || \
	die "libcanberra-gtk3.pc is missing or empty. gnome-settings-daemon requires libcanberra-gtk3 by that exact name (meson.build:109, unconditional), and this helper is what needs GTK 3's X11 backend -- if it did not build, either --enable-gtk3 was dropped or gtk3 lost gdk/gdkx.h again"
[ -s "$DESTDIR/usr/lib/libcanberra-gtk3.so" ] || \
	die "libcanberra-gtk3.so is missing or empty although its .pc was installed"

finish_install
log "installed libcanberra with its ALSA backend at ${backend#"$DESTDIR"}"
