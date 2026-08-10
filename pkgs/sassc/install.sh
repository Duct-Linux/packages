#!/bin/sh
# Stage sassc: one binary.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
install -d "$DESTDIR/usr/bin"
install -m 0755 sassc "$DESTDIR/usr/bin/sassc"

finish_install
log "installed /usr/bin/sassc"
