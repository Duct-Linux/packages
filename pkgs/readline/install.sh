#!/bin/sh
# Stage readline, and refuse to ship one whose terminal library is missing.
#
# The failure this exists to stop is the same one curl and glib-networking are
# guarded against here: a package that builds, installs, and is quietly missing
# the thing it was packaged for.
#
# readline's shared library only references ncurses if SHLIB_LIBS says so. Get
# that wrong and libreadline.so is produced with tgetent, tputs and friends left
# UNDEFINED. Nothing complains -- not the build, not the install, not tape --
# because an undefined symbol in a shared library is legal until something tries
# to resolve it. The bill arrives in the two packages this was added for, and
# neither error names readline:
#
#   mozjs   --enable-readline finds the header and the library and then fails
#           at link time on symbols that belong to ncurses;
#   gjs     compiles and RUNS a readline("foo") probe at configure time, and
#           with -Dreadline=auto a failed link is not an error -- it is a gjs
#           built with no interactive shell and no debugger input.
#
# So the assertion is on DT_NEEDED rather than on the file existing. "The
# library is present" was never the question.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
# shellcheck disable=SC2086
make DESTDIR="$DESTDIR" ${MAKE_INSTALL_ARGS:-install} || die "make install failed"

lib=$(find "$DESTDIR/usr/lib" -name 'libreadline.so.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] || die "no libreadline.so.* was installed"
[ -s "$lib" ] || die "$lib was installed but is empty"

[ -s "$DESTDIR/usr/include/readline/readline.h" ] \
	|| die "readline.h was not installed, or is empty"

pc=$DESTDIR/usr/lib/pkgconfig/readline.pc
[ -s "$pc" ] || die "readline.pc was not installed, or is empty"

# --with-curses is what decides this. Without it readline writes -ltermcap into
# its own .pc file, and nothing in this distribution provides a termcap library:
# every consumer would be handed a link line naming a library that is not there.
if grep -q -- '-ltermcap' "$pc"; then
	log "readline.pc reads:"
	sed 's/^/    /' "$pc" >&2
	die "readline.pc asks for -ltermcap, which nothing here ships -- configure was run without --with-curses"
fi

# THE POSITIVE CONTROL COMES FIRST, and it is not a formality here.
#
# The check below is "readelf does not print libncursesw". A readelf that is
# absent, or that cannot read this file, prints nothing either -- and a grep
# over nothing is indistinguishable from a grep over a correctly linked library
# that simply lacks the entry. Both would report success. So establish that
# readelf can produce NEEDED lines for this exact file before drawing any
# conclusion from their contents.
command -v readelf >/dev/null 2>&1 || die "no readelf; the DT_NEEDED assertion below cannot run, and an assertion that cannot run must not pass"

needed=$(readelf -d "$lib" 2>/dev/null | grep 'NEEDED')
[ -n "$needed" ] || die "readelf reported no NEEDED entries at all for $lib; the ncurses check below would prove nothing"

if ! printf '%s\n' "$needed" | grep -q 'libncursesw'; then
	log "DT_NEEDED entries in $(basename "$lib"):"
	printf '%s\n' "$needed" | sed 's/^/    /' >&2
	die "libreadline.so does not link libncursesw -- its terminal symbols are undefined. Check that SHLIB_LIBS reached both the build and the install."
fi

finish_install
log "installed readline linked against libncursesw"
