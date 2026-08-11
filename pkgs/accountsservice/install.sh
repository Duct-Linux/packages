#!/bin/sh
# Stage accountsservice and assert that the daemon, its authorization and its
# bus wiring all arrived.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The daemon. Nothing starts it by hand; dbus activates it into libexecdir.
[ -s "$DESTDIR/usr/libexec/accounts-daemon" ] || die "accounts-daemon is missing or empty"

# The client library, through its soname link, and the .pc that finds it.
# gnome-control-center and gdm both link this rather than talking to the bus
# themselves.
[ -s "$DESTDIR/usr/lib/libaccountsservice.so.0" ] || die "libaccountsservice was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/accountsservice.pc" ] || die "accountsservice.pc was not installed"

# -Dintrospection=true asked for this.
[ -s "$DESTDIR/usr/lib/girepository-1.0/AccountsService-1.0.typelib" ] \
	|| die "the AccountsService-1.0 typelib was not built"

# THE POLKIT ACTION FILE, installed into the directory read out of polkit's own
# .pc. Its absence would mean the daemon had been built against a polkit whose
# policydir this recipe did not find -- every account change would then be
# refused by a polkit that has never heard of the action.
[ -s "$DESTDIR/usr/share/polkit-1/actions/org.freedesktop.accounts.policy" ] \
	|| die "the polkit action file was not installed; every account change would be denied"

# D-Bus activation, bus policy, and the interface definitions.
[ -s "$DESTDIR/usr/share/dbus-1/system-services/org.freedesktop.Accounts.service" ] \
	|| die "the D-Bus activation file was not installed; the daemon could never be started"
[ -s "$DESTDIR/usr/share/dbus-1/system.d/org.freedesktop.Accounts.conf" ] \
	|| die "the D-Bus policy file was not installed; the daemon could not own its bus name"

# The user templates the daemon copies into a new account. Shipped as data, and
# easy to lose to a wrong datadir.
for t in administrator standard; do
	[ -s "$DESTDIR/usr/share/accountsservice/user-templates/$t" ] \
		|| die "the $t user template was not installed"
done

# -Dsystemdsystemunitdir=no, asserted rather than trusted: it is a string
# option, so a typo would not be an error -- it would be a directory name.
if [ -e "$DESTDIR/usr/lib/systemd" ]; then
	die "a systemd unit was installed; -Dsystemdsystemunitdir did not take"
fi

# THE LOGIND LINK, CHECKED IN THE BINARY RATHER THAN IN THE OPTIONS. -Delogind
# is a boolean and its false branch resolves too, because elogind ships a
# libsystemd.pc symlink -- so "it built" says nothing about which library is
# behind the session tracking. This reads the library's own DT_NEEDED.
#
# A HARD FAILURE IF readelf IS MISSING, rather than a log line. This is the
# only check that distinguishes elogind from systemd here, and "could not
# verify" is not "verified" -- degrading to a message would let the one wiring
# error this file exists to catch through silently. binutils is packaged and
# ghcr.io/duct-linux/builder carries /usr/bin/readelf, so an image without it
# is a broken build environment and should say so.
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify the libelogind link, and this check is not optional"
readelf -d "$DESTDIR/usr/lib/libaccountsservice.so.0" 2>/dev/null \
	| grep -q 'NEEDED.*libelogind' \
	|| die "libaccountsservice does not link libelogind; -Delogind=true did not take"

log "installed accountsservice with polkit authorization and elogind session tracking"
