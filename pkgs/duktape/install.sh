#!/bin/sh
# Stage duktape, and give it the pkg-config file it does not ship.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr DESTDIR="$DESTDIR" install \
	|| die "make install failed"

# Upstream ships no duktape.pc, and polkit's meson build looks the library up
# with dependency('duktape') -- which is pkg-config and nothing else. Every
# distribution packaging duktape writes this file; without it polkit configures
# with no JavaScript engine and refuses to build.
install -d "$DESTDIR/usr/lib/pkgconfig"
cat >"$DESTDIR/usr/lib/pkgconfig/duktape.pc" <<'PC'
prefix=/usr
libdir=${prefix}/lib
includedir=${prefix}/include

Name: duktape
Description: Embeddable Javascript engine
Version: 2.7.0
Libs: -L${libdir} -lduktape
Cflags: -I${includedir}
PC

[ -e "$DESTDIR/usr/lib/libduktape.so" ] || die "libduktape.so was not installed"
[ -f "$DESTDIR/usr/include/duktape.h" ] || die "duktape.h was not installed"

finish_install
log "installed duktape"
