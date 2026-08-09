#!/bin/sh
# Record what dbus needs that a package cannot provide.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/bin/dbus-daemon" ] || die "dbus-daemon was not installed"

# The system bus drops to the messagebus account, which duct-filesystem creates
# -- /etc/passwd can only be owned by one package, and that is the one that
# owns it.
#
# The machine ID is deliberately absent. It identifies the *installation*, and
# baking one into a package would give every Duct system on earth the same one.
# It is generated on first boot, or by the ISO build for a live session.
log "note: /etc/machine-id must be generated at first boot, not shipped"
