#!/bin/sh
# The historical command names. kmod is one binary that decides what to do from
# argv[0]; everything from init scripts to udev rules invokes it by these names.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/bin/kmod" ] || die "kmod was not installed"

install -d "$DESTDIR/usr/sbin"
for t in depmod insmod modinfo modprobe rmmod; do
	[ -e "$DESTDIR/usr/sbin/$t" ] || ln -sfn ../bin/kmod "$DESTDIR/usr/sbin/$t"
done
[ -e "$DESTDIR/usr/bin/lsmod" ] || ln -sfn kmod "$DESTDIR/usr/bin/lsmod"

log "kmod command links created"
