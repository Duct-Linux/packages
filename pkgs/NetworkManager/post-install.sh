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

# --- the crypto backend, asserted against the binary ------------------------
# -Dcrypto=gnutls. nm-crypto-gnutls.c is compiled into a static library and
# linked into libnm, so a DT_NEEDED on libgnutls is the outcome; the flag and
# the meson summary are only the input.
#
# THE FAILURE THIS PREVENTS IS SILENT AND SPECIFIC. -Dcrypto=null builds and
# installs identically -- same binaries, same paths, same .pc files -- and
# every entry point in nm-crypto-null.c returns FALSE, including
# _nm_crypto_init. Its caller is nm-setting-8021x.c:533, which runs when a
# certificate is SET on a connection, so an 802.1X connection with a CA or
# client certificate could not be configured while username/password PEAP kept
# working. Nothing about the installed tree would say so.
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$DESTDIR/usr/lib/libnm.so" 2>/dev/null | grep -q "libgnutls.so" \
		|| die "libnm.so does not link libgnutls; -Dcrypto=gnutls did not take effect and 802.1X certificates could not be read"
else
	log "warning: readelf is unavailable, so the crypto-backend check DID NOT RUN."
fi

# --- the WWAN plugin, which is what -Dmodem_manager=true actually produces ---
# The flag does not change the daemon: mm-glib is linked into the WWAN plugin
# (src/core/devices/wwan/meson.build 7 and 43), installed into the plugin
# directory. So the daemon existing proves nothing about modem support, and the
# plugin's presence is the outcome.
#
# Asserted by glob rather than by a fixed path, because the plugin directory is
# versioned and a hardcoded 1.54.0 would silently stop matching on the next
# version bump -- an assertion that quietly tests nothing is worse than none.
wwan=$(find "$DESTDIR/usr/lib/NetworkManager" -name 'libnm-device-plugin-wwan.so' -print -quit 2>/dev/null || true)
[ -n "$wwan" ] \
	|| die "the WWAN device plugin was not installed; -Dmodem_manager=true did not take effect and there would be no mobile broadband panel"
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$wwan" 2>/dev/null | grep -q "libmm-glib.so" \
		|| die "the WWAN plugin does not link libmm-glib; it cannot talk to ModemManager"
fi

# --- what this package still cannot do, said out loud on every build ---------
# Not an assertion, and not this package's decision. NetworkManager has full
# mobile broadband support; what it can DRIVE is bounded by ModemManager, which
# is built without MBIM, QMI and QRTR -- so the AT-command path is what remains,
# and most current LTE and 5G hardware is not driven. Deferred deliberately.
# See pkgs/ModemManager/pkg.env; repeated here only because this is the package
# whose panel the absence shows up in.
log "note: mobile broadband is built and wired, but ModemManager is compiled"
log "note: without MBIM/QMI/QRTR, so only AT-command modems will be driven."
