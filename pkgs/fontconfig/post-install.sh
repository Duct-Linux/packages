#!/bin/sh
# Record what fontconfig needs that a package cannot do.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/bin/fc-cache" ] || die "fc-cache was not installed"

# The font cache is a build product of whatever fonts are installed system-wide,
# so it cannot belong to any one package -- and tape has no install hooks to
# regenerate it. Without it every application rescans every font directory on
# first run, which on a live ISO is the several-second pause before the desktop
# appears.
log "note: the image build must run 'fc-cache -f' after all fonts are installed"
