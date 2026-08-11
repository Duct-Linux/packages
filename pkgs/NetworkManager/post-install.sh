#!/bin/sh
# Assert the daemon, the two files that decide who may talk to it, and -- the
# point of this file -- that the flags which are dangerous to get wrong
# actually took effect.
#
# meson prints a configuration summary, so unlike wpa_supplicant the flags here
# CAN be read back. That summary is not what these check. A summary reports what
# meson decided; these report what was installed, and the two differ exactly
# when something went wrong between them.

. "$(dirname "$0")/../_scripts/common.sh"

# --- the daemon -------------------------------------------------------------
[ -x "$DESTDIR/usr/sbin/NetworkManager" ] && [ -s "$DESTDIR/usr/sbin/NetworkManager" ] \
	|| die "the NetworkManager daemon was not installed at /usr/sbin/NetworkManager"

# nmcli, which is also the proof that the readline assert at meson.build 803
# was satisfied rather than sidestepped. If someone ever "fixes" a build failure
# here by adding -Dnmcli=false, this is what says so -- the resulting package
# would otherwise look complete and leave the system with no way to configure a
# network without a GUI.
[ -x "$DESTDIR/usr/bin/nmcli" ] \
	|| die "nmcli was not installed; either -Dnmcli=false was passed or readline was not found, and this system has no other way to configure a network"

[ -s "$DESTDIR/usr/lib/libnm.so" ] \
	|| die "libnm.so is missing; gnome-control-center's Network panel links it"

# --- authorization, which is the flag worth asserting twice ------------------
# THE POLKIT POLICY FILE. data/meson.build 71 installs it into
# polkit_gobject_policydir, and that whole block is inside `if enable_polkit`.
# So its presence is the OUTCOME of -Dpolkit=true, where the flag itself is only
# the input. A NetworkManager built with -Dpolkit=false installs no policy file
# and compiles in main.auth-polkit=false, at which point any local user may
# reconfigure the network and read every stored secret.
[ -s "$DESTDIR/usr/share/polkit-1/actions/org.freedesktop.NetworkManager.policy" ] \
	|| die "the polkit policy file is missing; -Dpolkit=false was in effect and NetworkManager would perform NO authorization on its D-Bus API"

# The second, independent check on the same decision. The action ids live in
# nm-common-macros.h and are compiled into the daemon only when the polkit code
# is built, so this catches a policy file that arrived some other way.
grep -q "org.freedesktop.NetworkManager.settings.modify.system" \
	"$DESTDIR/usr/sbin/NetworkManager" \
	|| die "the daemon contains no polkit action ids; the authorization code was not compiled in"

# The D-Bus policy. Without it the daemon starts, cannot acquire
# org.freedesktop.NetworkManager, and exits.
[ -s "$DESTDIR/usr/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf" ] \
	|| die "the D-Bus policy is missing; NetworkManager could not acquire its bus name and would exit at startup"

# --- what was excluded, asserted as absent ----------------------------------
# -Dsystemdsystemunitdir=no. data/meson.build 25 and 39 install unit files into
# that directory, and the option is a STRING whose empty default means "go and
# find systemd" rather than "no". Getting it wrong is a build failure here, but
# it would silently start shipping unit files the moment anything provides a
# systemd.pc -- so the absence is asserted rather than assumed.
if [ -d "$DESTDIR/usr/lib/systemd" ] || [ -d "$DESTDIR/lib/systemd" ]; then
	die "systemd unit files were staged; -Dsystemdsystemunitdir=no did not take effect"
fi

# -Dnmtui=false and -Dfirewalld_zone=false, both asserted as absences for the
# same reason: each would otherwise be a silently-acquired dependency.
#
# Written as `if`, not `[ ... ] && die`. common.sh runs under `set -eu`, and a
# failing test on the left of && is fine mid-script but becomes the script's
# exit status if it is ever the last statement -- so the negative assertion
# would fail the build precisely when it PASSED. The `if` form cannot do that,
# and it is what bluez's post-install already uses.
if [ -e "$DESTDIR/usr/bin/nmtui" ]; then
	die "nmtui was installed; -Dnmtui=false did not take effect and libnewt is not packaged"
fi
if [ -d "$DESTDIR/usr/lib/firewalld" ]; then
	die "a firewalld zone was staged; -Dfirewalld_zone=false did not take effect"
fi

# --- paths ------------------------------------------------------------------
# data/meson.build 53 installs the udev rules into $udev_udevdir/rules.d.
[ -d "$DESTDIR/usr/lib/udev/rules.d" ] \
	|| die "no udev rules were installed under /usr/lib/udev/rules.d; -Dudev_dir did not take effect"
if [ -d "$DESTDIR/lib" ]; then
	die "NetworkManager staged into /lib; duct-filesystem owns that symlink"
fi

# --- what this package cannot do, said out loud on every build ---------------
# Not assertions. Each is a capability that is absent by decision, and each is
# invisible in a build log, in the meson summary and in the installed tree --
# so the only place they can be seen is here.
log "note: -Dcrypto=null. NetworkManager cannot read or verify certificates, so an"
log "note: 802.1X connection with a CA or client certificate CANNOT BE CONFIGURED."
log "note: username/password PEAP is unaffected, which is why this looks like it works."
log "note: neither nss nor gnutls is packaged; this is a scope item, not a bug here."
log "note: -Dmodem_manager=false, so there is no mobile broadband panel until"
log "note: mm-glib exists (ModemManager, which waits on libgudev)."
