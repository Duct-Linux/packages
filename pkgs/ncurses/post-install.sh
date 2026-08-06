#!/bin/sh
# Wide-character ncurses ships as libncursesw; almost everything asks for
# -lncurses. Without these links, every consumer fails to link against a library
# that is right there under a different name.
#
# Runs from the generic install stage, which invokes post-install.sh if present.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$DESTDIR/usr/lib" || die "no /usr/lib in the staging root"

for lib in ncurses form panel menu; do
	[ -e "lib${lib}w.so" ] || continue
	ln -sfn "lib${lib}w.so" "lib${lib}.so"
	if [ -e "pkgconfig/${lib}w.pc" ]; then
		ln -sfn "${lib}w.pc" "pkgconfig/${lib}.pc"
	fi
done

# The historical name, still hardcoded in a surprising number of configure
# scripts.
[ -e libncursesw.so ] && ln -sfn libncursesw.so libcurses.so

# curses.h guards the wide-character declarations behind _XOPEN_SOURCE_EXTENDED.
# Everything here is the wide build, so expose them unconditionally rather than
# making every consumer define the right macro first.
if [ -f "$DESTDIR/usr/include/curses.h" ]; then
	sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$DESTDIR/usr/include/curses.h"
fi

log "wide-character compatibility links created"
