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

# ---------------------------------------------------------------------------
# What starts elogind
#
# NOTHING DOES, DIRECTLY, AND THAT IS CORRECT. elogind is D-Bus activated: it
# ships org.freedesktop.login1.service, and the first call to that name is what
# starts it. pam_elogind makes that call on every login, so a system whose bus
# is running gets a session manager without anything having to remember to
# start one -- which is why the live system's boot script starts dbus-daemon
# and does NOT start this.
#
# That is a fact about the built package rather than about elogind in general,
# and it decides whether a boot script somewhere else is right, so it is
# asserted here in the package that owns it.
#
# THE PATH INSIDE THE FILE, NOT THE FILE. The Exec line is rendered from
# {{LIBEXECDIR}} at build time, so it is a compile-time string in a file the
# install step places -- exactly the shape that put wpa_supplicant's activation
# Exec at /usr/local/sbin while its binaries went to /usr/sbin. Both halves
# looked perfect and dbus could not start it.
service=$DESTDIR/usr/share/dbus-1/system-services/org.freedesktop.login1.service
[ -s "$service" ] \
	|| die "org.freedesktop.login1.service is missing; nothing would ever start elogind, and every graphical login would wait for a session manager that never arrives"

exec_line=$(sed -n 's/^Exec=//p' "$service" | head -1)
exec_prog=${exec_line%% *}
case $exec_prog in
	/*) ;;
	*) die "the activation file's Exec is '$exec_line', which is not an absolute path; dbus-daemon resolves it against nothing" ;;
esac
[ -x "$DESTDIR$exec_prog" ] \
	|| die "the activation file execs $exec_prog and this package installs no such program; dbus would accept the activation request and fail it"

log "elogind is D-Bus activated: $exec_prog"
log "installed elogind with libsystemd compatibility links"
