#!/bin/sh
# Assert the library NetworkManager will not configure without, and the tool
# that is the only way to test it without NetworkManager.

. "$(dirname "$0")/../_scripts/common.sh"

# dependency('libndp') with no required:false is a pkg-config lookup, so the .pc
# is what NM's configure actually consults. Empty counts as present to
# pkg-config's --exists and then supplies no -lndp.
[ -s "$DESTDIR/usr/lib/pkgconfig/libndp.pc" ] \
	|| die "libndp.pc is missing or empty; NetworkManager's meson would stop at dependency('libndp')"

[ -s "$DESTDIR/usr/lib/libndp.so" ] \
	|| die "libndp.so (the unversioned symlink) is missing or dangling"

# ndptool is the whole reason this package ships a program at all: it sends
# router solicitations and prints the advertisements that come back. When IPv6
# does not come up, it is what distinguishes "the router is not advertising"
# from "NetworkManager is not asking" -- a distinction nothing else in this
# distribution can make.
[ -x "$DESTDIR/usr/bin/ndptool" ] && [ -s "$DESTDIR/usr/bin/ndptool" ] \
	|| die "ndptool was not installed as a non-empty executable"

log "libndp: libndp.pc, libndp.so and ndptool present"
