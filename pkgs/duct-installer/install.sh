#!/bin/sh

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing the Duct installer into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

[ -x "$DESTDIR/usr/bin/duct-installer" ] || \
	die "the graphical duct-installer binary was not installed"
[ -x "$DESTDIR/usr/bin/duct-install-cli" ] || \
	die "the serial-console test harness was not installed"

finish_install
log "installed duct-installer 0.1.0"
