#!/bin/sh
# Stage ninja: one binary.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
install -d "$DESTDIR/usr/bin"
install -m 0755 ninja "$DESTDIR/usr/bin/ninja"

install -d "$DESTDIR/usr/share/doc/ninja"
strip_payload
log "installed /usr/bin/ninja"
