#!/bin/sh
# Record what the image build still has to do for udev.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/sbin/udevd" ] || [ -x "$DESTDIR/usr/bin/udevd" ] \
	|| die "udevd was not installed"

# /etc/udev/hwdb.bin is compiled from the hwdb.d text files by
# `udevadm hwdb --update`. It is not shipped: it is a build product of whatever
# hwdb fragments are installed *system-wide*, so a copy from this package alone
# would be wrong the moment anything else adds a fragment. tape has no install
# hooks, so the image build runs it -- the same place it runs ldconfig.
log "note: the image build must run 'udevadm hwdb --update' after installation"
