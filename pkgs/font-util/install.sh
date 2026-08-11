#!/bin/sh
# Stage font-util, then assert the one string this package exists to publish.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# THE PKG-CONFIG FILE, ASSERTED BY CONTENT AND NOT BY EXISTENCE. Two other
# packages read one variable out of it and fall back to a literal when the read
# returns nothing:
#
#   libfontenc  configure:19894, then `if test "x${FONTROOTDIR}" = "x"` ->
#               ${datadir}/fonts/X11
#   xwayland    meson.build:143-149, dependency('fontutil', required: false)
#
# Both fallbacks are silent. A fontutil.pc that exists but has no fontrootdir
# line -- which is what a lost --with-fontrootdir would produce -- therefore
# reads exactly like this package not being installed at all, and the failure
# does not appear here.
pc=$DESTDIR/usr/lib/pkgconfig/fontutil.pc
[ -s "$pc" ] || die "fontutil.pc was not installed into /usr/lib/pkgconfig; libfontenc and xwayland both read this file and both fall back SILENTLY when the read fails"
grep -q '^fontrootdir=/usr/share/fonts/X11$' "$pc" \
	|| die "fontutil.pc does not declare fontrootdir=/usr/share/fonts/X11; --with-fontrootdir did not take effect, and both consumers would silently fall back to their own literal instead of reading this one"

# The aclocal macro. Not decoration: libfontenc's configure.ac calls
# XORG_FONT_MACROS_VERSION and m4_fatal()s without it, so this file is what
# makes libfontenc's autotools regenerable at all. Nothing in this tree
# regenerates it -- the tarball ships a configure -- but shipping the macro is
# what makes that a choice rather than a dependency on the tarball's state.
[ -s "$DESTDIR/usr/share/aclocal/fontutil.m4" ] \
	|| die "fontutil.m4 was not installed; libfontenc's configure.ac m4_fatal()s without XORG_FONT_MACROS_VERSION"

# The two tools, which are the only machine code in this package and therefore
# the reason it is NOT stamped PKG_ARCH=any.
for prog in bdftruncate ucs2any; do
	[ -x "$DESTDIR/usr/bin/$prog" ] && [ -s "$DESTDIR/usr/bin/$prog" ] \
		|| die "$prog was not installed as a non-empty executable"
done

# The encoding maps, which land under the font root and are the only files this
# tree puts there. Asserted at the path rather than counted, because the path is
# what proves --with-fontrootdir reached MAPDIR as well as fontutil.pc -- the
# two are separate substitutions (configure.ac 45-52) and a --with-mapdir left
# over from anywhere would move these without touching the .pc.
[ -s "$DESTDIR/usr/share/fonts/X11/util/map-ISO8859-1" ] \
	|| die "the encoding maps are not under /usr/share/fonts/X11/util; MAPDIR did not follow fontrootdir"

# NOT AN ASSERTION: the six directories Xwayland's default font path names --
# misc, TTF, OTF, Type1, 100dpi, 75dpi -- are NOT created here and nothing in
# this tree fills them. Xwayland survives that on libXfont2's builtin fonts, and
# pkgs/libXfont2/install.sh is where that is checked. Written down here because
# this is the package whose name suggests otherwise.
log "note: only fonts/X11/util is populated. misc, TTF, OTF, Type1, 100dpi and 75dpi are empty;"
log "note: Xwayland's core X fonts come from libXfont2's compiled-in built-ins, not from this path."
