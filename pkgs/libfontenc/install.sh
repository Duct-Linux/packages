#!/bin/sh
# Stage libfontenc, then assert the library, the .pc libXfont2 resolves it by,
# and the search path --with-fontrootdir was passed to control -- which is a
# string inside the library, not a directory on disk. See below.

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

# WHAT --with-fontrootdir ACTUALLY PRODUCES, AND IT IS NOT A DIRECTORY.
#
# This assertion was first written against /usr/share/fonts/X11/encodings and
# it failed CI, correctly: libfontenc INSTALLS NO ENCODING FILES AT ALL. Its
# entire payload is the library, one header and one .pc. ENCODINGSDIR never
# reaches an install rule -- it reaches the COMPILER, once, through
# src/Makefile.am 13-14:
#
#     FONTENCDIR=@ENCODINGSDIR@
#     FONTENCDEFS = -DFONT_ENCODINGS_DIRECTORY=\"$(FONTENCDIR)/encodings.dir\"
#
# so the flag's whole observable effect is a string literal in .rodata, read at
# run time by FontEncDirectory() (encparse.c 844-857). The directory it names is
# populated by X.Org's separate `encodings` package, which this tree does not
# have. Asserting the directory was asserting another package's payload.
#
# Asserted on the artefact instead, which is where the flag's effect actually
# is. Losing the flag does not fail anything: it silently compiles a path
# derived from whatever ${datadir} expanded to, and the library then looks for
# its tables somewhere nothing writes.
# Matched on the ROOT rather than on the whole FONT_ENCODINGS_DIRECTORY string:
# the "/encodings.dir" tail is appended by src/Makefile.am and is not what this
# flag controls, so asserting it would be asserting upstream's spelling. The
# root is the part --with-fontrootdir decides and the part that goes wrong.
grep -qa '/usr/share/fonts/X11/encodings' "$DESTDIR/usr/lib/libfontenc.so.1" \
	|| die "the shipped libfontenc does not contain the path /usr/share/fonts/X11/encodings; --with-fontrootdir did not reach FONT_ENCODINGS_DIRECTORY and the library will look for its encoding tables somewhere nothing populates"

# NOT AN ASSERTION, AND THE REASON IT IS NOT ONE IS THE POINT: the directory
# above is EMPTY in this distribution, and that is survivable rather than
# broken. fontenc.c compiles in tables for iso10646, iso8859-1 through -16 and
# koi8-r, so the encodings every font a GNOME desktop loads actually uses are in
# the library. encodings.dir supplies the REST -- the CJK and legacy vendor
# sets -- and X.Org ships them in a package of their own.
#
# This is the same shape as libXfont2's built-in fonts, one layer down: a
# compiled-in fallback is doing the work a data package would otherwise do, and
# nothing logs the difference. Packaging X.Org `encodings` is what would close
# it, and it is not needed for a Latin-script session.
log "note: /usr/share/fonts/X11/encodings is empty here -- X.Org's separate 'encodings' package fills it."
log "note: the iso8859-*, iso10646 and koi8-r tables are compiled into fontenc.c, so common encodings resolve without it."

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
