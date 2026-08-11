#!/bin/sh
# Assert the daemon, the library its consumers actually link, the authorization
# layer, and -- at the end, unmissably -- the modem protocols this build does
# not support.

. "$(dirname "$0")/../_scripts/common.sh"

# --- the daemon and the CLI -------------------------------------------------
[ -x "$DESTDIR/usr/sbin/ModemManager" ] && [ -s "$DESTDIR/usr/sbin/ModemManager" ] \
	|| die "the ModemManager daemon was not installed at /usr/sbin/ModemManager"
[ -x "$DESTDIR/usr/bin/mmcli" ] \
	|| die "mmcli was not installed; it is the only way to inspect a modem without a GUI"

# --- mm-glib, which is the half another package depends on ------------------
# NetworkManager's meson.build makes mm-glib a bare dependency() with no
# required:false whenever -Dmodem_manager is on. So this .pc file is not a
# detail of this package -- it is the thing that decides whether NetworkManager
# can be built with modem support at all.
[ -s "$DESTDIR/usr/lib/libmm-glib.so" ] \
	|| die "libmm-glib.so is missing"
[ -s "$DESTDIR/usr/lib/pkgconfig/mm-glib.pc" ] \
	|| die "mm-glib.pc is missing; NetworkManager's -Dmodem_manager=true would fail to configure against this package"
[ -s "$DESTDIR/usr/lib/girepository-1.0/ModemManager-1.0.typelib" ] \
	|| die "ModemManager-1.0.typelib is missing; -Dintrospection=true did not take effect"

# --- authorization ----------------------------------------------------------
# -Dpolkit=strict. The policy file is installed only when polkit is enabled, so
# its presence is the outcome of the flag rather than the flag itself. 'no'
# would remove the authorization layer; 'permissive' would keep the file and
# compile in a default of "yes" for every caller -- which this cannot
# distinguish, and which is why the flag is spelled out in pkg.env.
[ -s "$DESTDIR/usr/share/polkit-1/actions/org.freedesktop.ModemManager1.policy" ] \
	|| die "the polkit policy file is missing; -Dpolkit=no was in effect and ModemManager would perform no authorization"

# --- the D-Bus policy, without which the daemon cannot take its name --------
[ -s "$DESTDIR/usr/share/dbus-1/system.d/org.freedesktop.ModemManager1.conf" ] \
	|| die "the D-Bus policy is missing; ModemManager could not acquire org.freedesktop.ModemManager1 and would exit at startup"

# --- paths, and the absences that prove three flags -------------------------
[ -d "$DESTDIR/usr/lib/udev/rules.d" ] \
	|| die "no udev rules were installed under /usr/lib/udev/rules.d; -Dudevdir did not take effect"
if [ -d "$DESTDIR/lib" ]; then
	die "ModemManager staged into /lib; duct-filesystem owns that symlink"
fi
if [ -d "$DESTDIR/usr/lib/systemd" ] || [ -d "$DESTDIR/lib/systemd" ]; then
	die "systemd unit files were staged; -Dsystemdsystemunitdir=no did not take effect, and its EMPTY default means auto-detect rather than off"
fi

# --- what this package cannot do, on every build ----------------------------
# Not an assertion, and it cannot be one: a modem this build cannot drive looks
# exactly like no modem being plugged in. Nothing in the build log, the meson
# summary or the installed tree records it.
log "note: -Dmbim=false -Dqmi=false -Dqrtr=false, because libmbim, libqmi and"
log "note: libqrtr-glib are not packaged and each is a hard dependency when its"
log "note: option is on. MBIM and QMI are the control protocols essentially"
log "note: EVERY MODERN LTE AND 5G MODEM SPEAKS, so what remains is the"
log "note: AT-command path and older devices. The daemon, the panel and the"
log "note: D-Bus API are all present and correct; most current hardware simply"
log "note: will not be driven. Packaging libqmi is the first step back, since"
log "note: qrtr asserts qmi and mbim is independent of both."
