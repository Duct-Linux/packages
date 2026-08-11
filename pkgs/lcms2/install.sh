#!/bin/sh
# Stage lcms2, then prove the engine and its pkg-config file actually shipped.
#
# WHY THIS ASSERTION EXISTS. lcms2's configure treats libjpeg and libtiff as
# optional and prints a summary rather than failing when they are missing, so a
# build that finds neither still produces a library, still installs, and still
# exits 0 -- it just has no converters in it. That is indistinguishable from a
# correct build by exit status alone.
#
# The library and the .pc file are the two things every consumer of lcms2 needs:
# mutter and colord both find it through pkg-config, and a missing lcms2.pc is
# how "colord builds without colour management" would begin. Both are checked
# for non-emptiness rather than existence, because an interrupted or misdirected
# install can leave a zero-length file behind and a bare -f test passes on it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# Existence and size assertions, safe before the strip in finish_install: strip
# rewrites files in place without deleting them and cannot invalidate these.
[ -s "$DESTDIR/usr/lib/liblcms2.so" ] || \
	die "liblcms2.so is missing or empty; nothing links against lcms2 without it"
[ -s "$DESTDIR/usr/lib/pkgconfig/lcms2.pc" ] || \
	die "lcms2.pc is missing or empty; mutter and colord find lcms2 through pkg-config and would silently build without it"

# transicc is the profile converter and is built from the core library alone, so
# it is present in every correct build regardless of the jpeg/tiff options.
[ -s "$DESTDIR/usr/bin/transicc" ] || \
	die "transicc is missing or empty; the tools half of lcms2 did not build"

finish_install
log "installed lcms2 with liblcms2.so, lcms2.pc and transicc"
