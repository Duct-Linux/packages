#!/bin/sh
# Install the binary and nothing else.
#
# Not `make install`: that lays down one symlink per applet, and busybox has
# applets called ls, cp, mount, dmesg and blkid. uutils-coreutils and util-linux
# own those paths, and tape treats two packages claiming one path as a hard
# install error -- so a busybox that installed its symlinks would make the
# package set uninstallable rather than merely untidy.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

[ -f busybox ] || die "the build produced no busybox binary"

install -d -m 0755 "$DESTDIR/usr/bin"
install -m 0755 busybox "$DESTDIR/usr/bin/busybox"

# The one property the initramfs depends on. A dynamically linked busybox would
# still install and still look correct here, and would then fail at boot with
# "No such file or directory" -- the dynamic loader's way of saying it is not in
# the initramfs. Catch it now instead.
if command -v readelf >/dev/null 2>&1; then
	if readelf -l "$DESTDIR/usr/bin/busybox" 2>/dev/null | grep -q 'INTERP'; then
		die "busybox is dynamically linked; the initramfs would not be able to run it"
	fi
fi

log "installed a $(wc -c <"$DESTDIR/usr/bin/busybox") byte static busybox"

strip_payload
