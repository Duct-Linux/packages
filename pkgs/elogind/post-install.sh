#!/bin/sh
# Answer to libsystemd as well as libelogind, and ship the PAM stack that
# actually registers a session.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$DESTDIR/usr/lib/pkgconfig" 2>/dev/null || die "elogind installed no pkg-config files"

# Every GNOME component looks for "libsystemd": mutter, gnome-session, gdm and
# gnome-settings-daemon all call dependency('libsystemd') or check for
# <systemd/sd-login.h>. elogind is API-compatible and installs under its own
# name, so without these two links the whole desktop configures as though there
# were no session tracking at all -- and then builds, and then cannot create a
# session at runtime. Every distribution shipping elogind provides them.
[ -f libelogind.pc ] || die "libelogind.pc is missing"
ln -sfn libelogind.pc libsystemd.pc

if [ -d "$DESTDIR/usr/include/elogind/systemd" ]; then
	install -d "$DESTDIR/usr/include"
	ln -sfn elogind/systemd "$DESTDIR/usr/include/systemd"
fi

# pam_elogind.so is what puts a login into a session; a graphical login that
# does not go through it produces a session logind knows nothing about, and
# gnome-shell then sits waiting for an activation that never comes.
[ -f "$DESTDIR/usr/lib/security/pam_elogind.so" ] || die "pam_elogind was not installed"

install -d -m 0755 "$DESTDIR/etc/pam.d"
cat >"$DESTDIR/etc/pam.d/elogind-user" <<'PAM'
# Begin /etc/pam.d/elogind-user
#
# The stack elogind runs for a user's own session bus. Deliberately minimal:
# authentication has already happened by the time this runs.
account  include  system-account
session  required pam_loginuid.so
session  include  system-session
PAM

log "installed elogind with libsystemd compatibility links"
