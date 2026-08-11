#!/bin/sh
# Stage libxcvt and assert the .pc, because being found by pkg-config is the
# whole of this package's job.
#
# Xwayland takes libxcvt with `required: true`, so its absence is loud there --
# which means the interesting failure is not "missing" but "present and
# unusable": an empty or truncated libxcvt.pc reads to pkgconf much like a file
# that is not there, and the fallback: in Xwayland's dependency() call cannot
# rescue it under --wrap-mode=nodownload.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

pc=$DESTDIR/usr/lib/pkgconfig/libxcvt.pc
[ -s "$pc" ] || die "libxcvt.pc was not installed, or is empty; Xwayland's dependency('libxcvt', required: true) would fail configure"
grep -q '^Libs:.*-lxcvt' "$pc" || die "libxcvt.pc does not link -lxcvt"

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libxcvt.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libxcvt.so.0.* was installed under /usr/lib"

[ -s "$DESTDIR/usr/include/libxcvt/libxcvt.h" ] || die "libxcvt/libxcvt.h is missing; nothing could compile against this"

# The cvt utility, which is what makes this a package rather than a header drop
# and is how a mode line gets checked by hand.
[ -s "$DESTDIR/usr/bin/cvt" ] || die "the cvt utility was not installed"

log "installed libxcvt"
