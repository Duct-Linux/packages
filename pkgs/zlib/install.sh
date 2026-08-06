#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make DESTDIR="$DESTDIR" install || die "make install failed"

# The static archive is not wanted; everything in Duct links zlib dynamically.
rm -f "$DESTDIR/usr/lib/libz.a"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload

[ -e "$DESTDIR/usr/lib/libz.so" ] || die "libz.so was not installed"
log "installed"
