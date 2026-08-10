#!/bin/sh
# Stage hwdata. Installed from the source tree, which is where it configured.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -f "$DESTDIR/usr/share/hwdata/pci.ids" ] || die "pci.ids was not installed"

finish_install
log "installed hwdata"
