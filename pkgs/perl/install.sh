#!/bin/sh
. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make DESTDIR="$DESTDIR" install || die "make install failed"

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload

[ -x "$DESTDIR/usr/bin/perl" ] || die "perl was not installed"
log "installed"
