#!/bin/sh
# Stage xdg-user-dirs, then prove the updater binary actually shipped.
#
# WHY THIS ASSERTION EXISTS. This package is two small programs and a config
# file, and the config file is the part that installs unconditionally. A build
# that produced no binaries at all would still stage a non-empty tree --
# /etc/xdg/user-dirs.conf and the locale data are enough to satisfy
# finish_install's "staging root is empty" guard. So the generic emptiness check
# cannot see this package failing; only naming the binary can.
#
# xdg-user-dirs-update is the one gnome-session actually runs at session start.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# Non-empty, not merely present: a zero-length binary passes a bare -f test and
# fails at exec time, which is far later and much harder to attribute.
[ -s "$DESTDIR/usr/bin/xdg-user-dirs-update" ] || \
	die "xdg-user-dirs-update is missing or empty; gnome-session runs this at login and the well-known directories would never be created"

# The configuration it reads. Shipped by the same make install, and cheap to
# assert because a missing one changes the tool's behaviour silently rather
# than making it fail.
[ -s "$DESTDIR/etc/xdg/user-dirs.defaults" ] || \
	die "user-dirs.defaults is missing or empty; the updater would create no directories"

finish_install
log "installed xdg-user-dirs-update and its defaults"
