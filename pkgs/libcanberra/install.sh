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

finish_install
log "installed libcanberra with its ALSA backend at ${backend#"$DESTDIR"}"
