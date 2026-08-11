#!/bin/sh
# Stage xkbcomp, then assert the binary AND the two strings that decide whether
# it and Xwayland are talking about the same directory.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# THE BINARY, AT THE PATH XWAYLAND BUILDS ITS COMMAND LINE FROM. Xwayland does
# not search $PATH: xkb/ddxLoad.c 143-157 concatenates XKB_BIN_DIRECTORY with
# "xkbcomp", and that directory comes from the `bindir` variable in the .pc
# asserted below. So the binary being executable at /usr/bin/xkbcomp and the
# .pc saying /usr/bin are one fact split across two files.
[ -x "$DESTDIR/usr/bin/xkbcomp" ] && [ -s "$DESTDIR/usr/bin/xkbcomp" ] \
	|| die "xkbcomp was not installed as a non-empty executable at /usr/bin/xkbcomp, which is where the X server builds its command line to reach"

# THE PKG-CONFIG FILE, WHICH XWAYLAND READS UNDER required: false.
# meson.build:105 is `dependency('xkbcomp', required: false)`, and lines
# 116-135 use it to resolve BOTH the XKB base directory and the bin directory,
# falling back to prefix-derived literals when the lookup fails. Those literals
# happen to be the same values -- so a missing xkbcomp.pc changes nothing
# TODAY and would change everything the moment either path moved, silently and
# in a package that is not this one. Asserted by content for that reason.
pc=$DESTDIR/usr/lib/pkgconfig/xkbcomp.pc
[ -s "$pc" ] || die "xkbcomp.pc was not installed; xwayland reads xkbconfigdir and bindir out of it under required:false and falls back SILENTLY"
grep -q '^xkbconfigdir=/usr/share/X11/xkb$' "$pc" \
	|| die "xkbcomp.pc does not declare xkbconfigdir=/usr/share/X11/xkb; --with-xkb-config-root did not take effect, and xwayland would inherit a different directory from this file than xkeyboard-config installs into"
grep -q '^bindir=/usr/bin$' "$pc" \
	|| die "xkbcomp.pc does not declare bindir=/usr/bin; xwayland resolves XKB_BIN_DIRECTORY from this line and would look for xkbcomp somewhere it is not"

# THE SAME DIRECTORY AGAIN, THIS TIME COMPILED INTO THE BINARY. It arrives by a
# different route -- AM_CPPFLAGS -DDFLT_XKB_CONFIG_ROOT in Makefile.am:25 --
# and it is what xkbcomp uses when the server does NOT pass -R. Both routes
# come from the same configure substitution, so this cannot currently disagree
# with the .pc; it is checked because they are separate substitutions and a
# future --with-mapdir-shaped mistake would move one without the other.
grep -qa '/usr/share/X11/xkb' "$DESTDIR/usr/bin/xkbcomp" \
	|| die "the xkbcomp binary does not contain /usr/share/X11/xkb; DFLT_XKB_CONFIG_ROOT is not what the .pc advertises, so a keymap compiled without -R would look in the wrong place"

command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify what xkbcomp links, and this check is not optional"
for lib in libxkbfile libX11; do
	readelf -d "$DESTDIR/usr/bin/xkbcomp" 2>/dev/null | grep -q "NEEDED.*$lib\.so" \
		|| die "xkbcomp does not link $lib"
done

# NOT AN ASSERTION, AND IT CANNOT BE ONE FROM HERE. Two things this package
# needs at RUN time are outside its own staging root:
#
#   /usr/share/X11/xkb        xkeyboard-config's rules, declared as a
#                             dependency so tape installs it, but not visible
#                             in this DESTDIR.
#   a writable output dir     Xwayland passes one on the command line. Its
#                             first choice is XKM_OUTPUT_DIR, and when that is
#                             not writable xkb/ddxLoad.c 76-82 falls back to
#                             $XDG_RUNTIME_DIR and then to /tmp. Nothing here
#                             creates any of them.
log "note: the keymap RULES come from xkeyboard-config at /usr/share/X11/xkb -- declared, but not staged by this package."
log "note: the X server chooses the .xkm output directory at run time, falling back to XDG_RUNTIME_DIR and then /tmp."
