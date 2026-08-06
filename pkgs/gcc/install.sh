#!/bin/sh
# Stage gcc and add the names people actually type.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# The traditional name for the C compiler; a great many configure scripts and
# Makefiles look for it and fall over without it.
ln -sfn gcc "$DESTDIR/usr/bin/cc"

# libiberty is built by both gcc and binutils. tape treats two packages owning
# one path as a hard error with no override, so exactly one of them may ship it
# -- and neither needs to, since nothing in Duct links it statically.
rm -f "$DESTDIR/usr/lib/libiberty.a"

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload

[ -x "$DESTDIR/usr/bin/gcc" ] || die "gcc was not installed"
log "installed"
