#!/bin/sh
# Stage libfontenc, then assert the library, the .pc libXfont2 resolves it by,
# and the directory --with-fontrootdir was passed to control.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

[ -s "$DESTDIR/usr/lib/libfontenc.so.1" ] \
	|| die "libfontenc.so.1 is missing or dangling"

# libXfont2 names this in a PKG_CHECK_MODULES with no fallback, so its absence
# IS a hard error there rather than a silent skip -- which makes this the
# cheerful case. Asserted anyway, because "fails loudly in the next package" is
# a worse place to find out than "fails here".
[ -s "$DESTDIR/usr/lib/pkgconfig/fontenc.pc" ] \
	|| die "fontenc.pc was not installed; libXfont2's PKG_CHECK_MODULES would stop on it"

[ -s "$DESTDIR/usr/include/X11/fonts/fontenc.h" ] \
	|| die "fontenc.h was not installed; nothing could compile against this package"

# THE ENCODINGS DIRECTORY, WHICH IS WHAT --with-fontrootdir WAS PASSED FOR.
# ENCODINGSDIR is derived as ${FONTROOTDIR}/encodings (configure 19915), so
# this path existing is the proof that the flag took effect -- and losing the
# flag does not fail anything, it silently relocates these files relative to
# whatever ${datadir} expanded to. The encodings are looked up at RUNTIME by
# path, so a relocated set is a set that is never read.
[ -d "$DESTDIR/usr/share/fonts/X11/encodings" ] \
	|| die "/usr/share/fonts/X11/encodings does not exist; --with-fontrootdir did not take effect and the encoding tables are somewhere nothing looks"
[ -n "$(find "$DESTDIR/usr/share/fonts/X11/encodings" -name '*.enc*' -print -quit 2>/dev/null)" ] \
	|| die "the encodings directory was created but holds no .enc files"

# The link to zlib, asserted on the artefact. AC_CHECK_LIB decides this at
# configure time and a failure there is fatal, so this cannot currently be
# false -- it is here because the alternative outcome, a libfontenc that cannot
# open a compressed encoding, produces no error anywhere: fontenc's readers
# return "encoding not found", which is indistinguishable from an encoding this
# font does not use.
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify the zlib link, and this check is not optional"
readelf -d "$DESTDIR/usr/lib/libfontenc.so.1" 2>/dev/null | grep -q 'NEEDED.*libz\.so' \
	|| die "libfontenc does not link libz; gzipped .enc files would silently read as missing encodings"
