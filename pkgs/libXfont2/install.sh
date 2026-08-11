#!/bin/sh
# Stage libXfont2, then assert the built-in fonts -- on config.h AND on the
# shipped library, because they are two different facts.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

[ -s "$DESTDIR/usr/lib/libXfont2.so.2" ] \
	|| die "libXfont2.so.2 is missing or dangling"

# xwayland takes this as dependency('xfont2', version: '>= 2.0') in its COMMON
# dependency list, so a missing .pc stops that build rather than silently
# skipping -- asserted anyway, for the same reason as fontenc.pc.
[ -s "$DESTDIR/usr/lib/pkgconfig/xfont2.pc" ] \
	|| die "xfont2.pc was not installed"

[ -s "$DESTDIR/usr/include/X11/fonts/libxfont2.h" ] \
	|| die "libxfont2.h was not installed; nothing could compile against this package"

# ---------------------------------------------------------------------------
# THE BUILT-IN FONTS. See pkg.env: this is what stands between an Xwayland
# start and FatalError("could not open default font"), because nothing in this
# tree installs a font file into any directory Xwayland's font path names.
#
# Checked twice on purpose, because --enable-builtins and "the fonts are in the
# library" are not the same claim. The first is what configure decided; the
# second is what shipped, and the strip step in finish_install runs between
# them.
[ -f "$BUILD_DIR/config.h" ] \
	|| die "no config.h in the build directory; cannot verify the builtin fonts"
grep -q '^#define XFONT_BUILTINS 1' "$BUILD_DIR/config.h" \
	|| die "XFONT_BUILTINS is not set; --enable-builtins did not take effect and every Xwayland start would die on SetDefaultFont(\"fixed\")"

# The rasteriser and the bitmap reader the builtin PCF goes through. Either one
# off leaves --enable-builtins compiled in and unusable, which is a worse state
# than not having it: configure reports success and the font still cannot load.
grep -q '^#define XFONT_FREETYPE 1' "$BUILD_DIR/config.h" \
	|| die "XFONT_FREETYPE is not set; there is no rasteriser for the builtin fonts to go through"
grep -q '^#define XFONT_PCFFORMAT 1' "$BUILD_DIR/config.h" \
	|| die "XFONT_PCFFORMAT is not set; the builtin fonts ARE PCF, so they would be compiled in and unreadable"

# NOW ON THE ARTEFACT. Two strings, both from src/builtins/fonts.c, both in
# .rodata and therefore untouched by --strip-unneeded:
#
#   "built-ins"   the font path element name (fpe.c:33). dix/dixfonts.c:1716
#                 appends exactly this string to every font path, so it is the
#                 name the lookup goes through, not a label.
#   the 6x13 XLFD the font "fixed" is aliased to (fonts.c:1226,1243-1248).
#
# Asserted as content rather than as a symbol because the symbols are static
# and strip removes them; the strings are the payload itself.
grep -qa 'built-ins' "$DESTDIR/usr/lib/libXfont2.so.2" \
	|| die "the shipped libXfont2 does not contain the string \"built-ins\"; the builtin font path element is not in the artefact whatever config.h says"
grep -qa 'misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso8859-1' "$DESTDIR/usr/lib/libXfont2.so.2" \
	|| die "the shipped libXfont2 does not contain the 6x13 XLFD; the font \"fixed\" resolves to nothing and Xwayland would FatalError at startup"

# ---------------------------------------------------------------------------
# The two libraries the font engine reads through, on the artefact rather than
# on configure's report. Both failures are silent at the point they matter:
# without freetype nothing rasterises, without libfontenc no glyph mapping
# resolves, and in each case a font simply "is not there".
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify what libXfont2 links, and this check is not optional"
for lib in libfreetype libfontenc libz; do
	readelf -d "$DESTDIR/usr/lib/libXfont2.so.2" 2>/dev/null | grep -q "NEEDED.*$lib\.so" \
		|| die "libXfont2 does not link $lib; configure reported it found but the artefact does not have it"
done

# --without-xmlto and --disable-devel-docs, asserted the way finding 8 asks for:
# on the thing the flag excludes rather than on the flag. finish_install already
# removes /usr/share/doc, so this is about the developer documentation the
# DocBook chain would have produced elsewhere.
if [ -d "$DESTDIR/usr/share/X11/doc" ]; then
	die "the DocBook documentation was built and staged; --without-xmlto did not take effect"
fi
