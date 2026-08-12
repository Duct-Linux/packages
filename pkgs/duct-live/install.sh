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
install -m 0755 "$files/graphical-session" "$DESTDIR/usr/libexec/duct-live/graphical-session"

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

# Every program the inittab names must be installed by this package.
#
# ASSERT THE OUTCOME, and this is the outcome that matters: an inittab entry
# pointing at a path that does not exist is not an install error, it is a
# terminal that silently has nothing on it -- and busybox respawns the missing
# program forever while saying so only to a console nobody is reading. An ISO
# once shipped with no console-session at all and passed its boot test, because
# the marker it looked for was printed before console-session would have run.
#
# The inittab is the enumeration, so it is read rather than restated: a new
# entry is covered the moment it is added, and a renamed script fails here
# instead of at 3am on a live medium. Field four is the command; the leading
# "-" busybox uses to mean "this is a login shell" is not part of the path.
# A for loop over a command substitution rather than `awk | while read`: the
# pipeline puts the loop in a SUBSHELL, so a die() inside it would exit that
# subshell and the check would report a problem the build then continued past.
# Word splitting is what is wanted here -- an entry like `busybox reboot`
# becomes two tokens and neither matches the paths below.
for cmd in $(awk -F: '$4 != "" { print $4 }' "$DESTDIR/etc/inittab"); do
	prog=${cmd#-}
	case $prog in
		/usr/libexec/duct-live/*|/usr/sbin/init)
			# -e FOLLOWS SYMLINKS, and /usr/sbin/init is deliberately a
			# dangling one at this point: it points at ../bin/busybox, which
			# another package installs. Testing with -e alone fails a
			# perfectly correct build -- which is what the first run of this
			# check did, and is worth more than the check would have been.
			[ -e "$DESTDIR$prog" ] || [ -L "$DESTDIR$prog" ] || \
				die "/etc/inittab runs $prog and this package does not install it"
			;;
	esac
done

# The two session scripts refer to each other -- console-session asks
# graphical-session whether it is going to take tty1 -- so the edge is checked
# in both directions rather than assumed from the fact that both files exist.
#
# MATCHED AS A TOKEN, not as a substring. The first version of this grepped for
# `--would-start` and a control that renamed the flag to `--would-startx` --
# breaking exactly the edge being guarded -- passed, because the new name
# contains the old one. A check that cannot fail is worse than no check: it
# reports a verified edge that nobody has verified.
flag='--would-start([^-A-Za-z0-9]|$)'
grep -qE -- "graphical-session $flag" \
	"$DESTDIR/usr/libexec/duct-live/console-session" \
	|| die "console-session no longer asks graphical-session about tty1; a shell and a greeter could land on the same terminal"
grep -qE -- "\"$flag" \
	"$DESTDIR/usr/libexec/duct-live/graphical-session" \
	|| die "graphical-session no longer answers --would-start, which console-session depends on to stay off tty1"

log "live boot wiring staged"
