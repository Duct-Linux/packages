#!/bin/sh
# Stage the live system's boot wiring.
#
# Everything here comes from files/ next to this script rather than being
# generated inline. duct-filesystem writes its files with here-documents
# because they are short and mostly declarative; these are shell programs, and
# a shell program embedded in another shell program is one level of quoting
# away from a boot failure nobody can read.

. "$(dirname "$0")/../_scripts/common.sh"

files=$RECIPE_DIR/files
[ -d "$files" ] || die "files/ is missing"

log "installing the boot scripts"

install -d -m 0755 "$DESTDIR/etc"
install -m 0644 "$files/inittab" "$DESTDIR/etc/inittab"

install -d -m 0755 "$DESTDIR/usr/libexec/duct-live"
install -m 0755 "$files/rc"              "$DESTDIR/usr/libexec/duct-live/rc"
install -m 0755 "$files/shutdown"        "$DESTDIR/usr/libexec/duct-live/shutdown"
install -m 0755 "$files/console-session" "$DESTDIR/usr/libexec/duct-live/console-session"

install -d -m 0755 "$DESTDIR/usr/bin"
install -m 0755 "$files/duct-mkinitramfs" "$DESTDIR/usr/bin/duct-mkinitramfs"

# Not executable, and not in a bin directory: this is the payload
# duct-mkinitramfs copies into the archive as /init. Installing it as a program
# would invite someone to run it on a running system, where it would try to
# switch_root out from underneath them.
install -d -m 0755 "$DESTDIR/usr/share/duct-live"
install -m 0644 "$files/initramfs-init" "$DESTDIR/usr/share/duct-live/initramfs-init"

# PID 1.
#
# busybox decides which applet it is from argv[0], so a program called `init`
# that is a symlink to busybox *is* busybox's init. The link is relative and
# points at ../bin/busybox: /usr/sbin/init -> /usr/bin/busybox. An absolute
# target would be resolved against the build host while this package is being
# staged, and against the initramfs while it is being copied.
#
# This is also why the busybox package installs no applet symlinks of its own.
# One package owns this path, and it is this one.
install -d -m 0755 "$DESTDIR/usr/sbin"
ln -sfn ../bin/busybox "$DESTDIR/usr/sbin/init"

# The mount table a live system needs. The real root is an overlay the
# initramfs already mounted, so there is no root entry here and there cannot
# be one -- what would it name?
cat >"$DESTDIR/etc/fstab" <<'EOF'
# Duct live system.
#
# / is an overlay of a read-only squashfs and a tmpfs, assembled by the
# initramfs before this file was readable. It is deliberately absent: fsck and
# remount have nothing to do with it, and naming a device here that does not
# exist would only mislead.
#
# <device>   <mount point>  <type>     <options>              <dump> <pass>
proc         /proc          proc       nosuid,noexec,nodev    0      0
sysfs        /sys           sysfs      nosuid,noexec,nodev    0      0
devtmpfs     /dev           devtmpfs   mode=0755,nosuid       0      0
devpts       /dev/pts       devpts     gid=5,mode=620         0      0
tmpfs        /dev/shm       tmpfs      mode=1777,nosuid,nodev 0      0
tmpfs        /run           tmpfs      mode=0755,nosuid,nodev 0      0
EOF
chmod 0644 "$DESTDIR/etc/fstab"

cat >"$DESTDIR/etc/issue" <<'EOF'

Duct Linux \r on \m

This is a live system. The root filesystem is a read-only squashfs with a
tmpfs stacked over it, so everything written here is gone at the next boot.

EOF
chmod 0644 "$DESTDIR/etc/issue"

log "live boot wiring staged"
