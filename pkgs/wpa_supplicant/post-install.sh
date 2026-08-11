#!/bin/sh
# Assert the payload, and then assert the FEATURES -- because in this package
# the flags cannot be trusted to have done anything.
#
# Every other recipe here can read a configure log or a meson summary to learn
# whether a flag took effect. wpa_supplicant has neither: .config is a list of
# make variables, an unrecognised one is silently ignored, and the file reads
# back exactly as written whether or not the build used a single line of it.
# CONFIG_PEERKEY is the proof -- it was removed upstream and still appears in
# the configuration everyone copies.
#
# So the assertions below are made against the BUILT BINARY. That is finding 8
# in its strongest form: the flag is the input, the compiled-in feature is the
# outcome, and only the outcome is worth checking.

. "$(dirname "$0")/../_scripts/common.sh"

sbin=$DESTDIR/usr/sbin

# --- the payload ------------------------------------------------------------
for prog in wpa_supplicant wpa_cli wpa_passphrase; do
	[ -x "$sbin/$prog" ] && [ -s "$sbin/$prog" ] \
		|| die "$prog was not installed as a non-empty executable in /usr/sbin; BINDIR did not take effect (upstream defaults it to /usr/local/sbin)"
done

# duct-filesystem ships /sbin as a symlink to usr/sbin. A package that staged
# a real /sbin directory would replace that symlink on install, which tape
# cannot refuse because its conflict check exempts directories.
if [ -d "$DESTDIR/sbin" ]; then
	die "wpa_supplicant staged into /sbin; duct-filesystem owns that symlink"
fi

# --- what makes the daemon reachable ----------------------------------------
# The activation file, and the substitution inside it. Asserting only that the
# file exists would pass on a file naming /usr/local/sbin -- dbus-daemon would
# then fail to start a daemon that is installed and correct, reporting nothing
# more useful than a timeout. So the assertion is on the PATH IT CONTAINS.
service=$DESTDIR/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service
[ -s "$service" ] \
	|| die "the D-Bus activation file is missing; NetworkManager could not start wpa_supplicant and every Wi-Fi connection would fail"
grep -q '^Exec=/usr/sbin/wpa_supplicant' "$service" \
	|| die "the activation file does not name /usr/sbin/wpa_supplicant; the @BINDIR@ substitution did not take effect"

# The bus policy. Without it the daemon starts, cannot acquire its name, and
# exits -- which NetworkManager reports as a supplicant that keeps dying.
[ -s "$DESTDIR/usr/share/dbus-1/system.d/wpa_supplicant.conf" ] \
	|| die "the D-Bus bus policy is missing; wpa_supplicant could not acquire fi.w1.wpa_supplicant1 and would exit at startup"

# --- the features, asserted against the binary ------------------------------
# grep on the binary rather than `strings`: grep is in duct/builder for certain
# and searches binary files perfectly well, so the check has one fewer
# precondition. An assertion that cannot run is not an assertion that passed.
binary=$sbin/wpa_supplicant

# THE D-BUS INTERFACE NetworkManager DRIVES. If CONFIG_CTRL_IFACE_DBUS_NEW had
# been dropped or misspelled, everything above would still pass: the binaries
# install, the activation file is generated from a template that does not know
# what was compiled in, and the policy is a static file. This is the only check
# that can tell.
grep -q "fi.w1.wpa_supplicant1" "$binary" \
	|| die "the binary contains no fi.w1.wpa_supplicant1; CONFIG_CTRL_IFACE_DBUS_NEW did not take effect and NetworkManager cannot drive this daemon"

# WPA3-Personal. defconfig enables SAE and a from-scratch .config does not, so
# this is the line most likely to be lost by someone tidying the config later
# -- and its absence cannot be seen without a WPA3 access point.
grep -q "SAE: Failed to derive PWE" "$binary" \
	|| die "the binary contains no SAE code; CONFIG_SAE did not take effect and no WPA3-Personal network will associate"

# Opportunistic Wireless Encryption, off in defconfig and enabled deliberately.
grep -q "OWE: transition mode BSSID" "$binary" \
	|| die "the binary contains no OWE code; CONFIG_OWE did not take effect"

# The driver interface. Without it the daemon has no way to reach a Wi-Fi
# device at all, and the failure appears as "no wireless interfaces found".
grep -q "nl80211" "$binary" \
	|| die "the binary contains no nl80211 driver; CONFIG_DRIVER_NL80211 did not take effect"

# --- what is deliberately absent, asserted as absent ------------------------
# The other half of finding 8: pin the flag AND assert the thing it excludes is
# gone. `ALL` generates four systemd unit files unconditionally, so they exist
# in the build tree and it would be easy for an install stage to sweep them up.
if [ -d "$DESTDIR/usr/lib/systemd" ] || [ -d "$DESTDIR/lib/systemd" ]; then
	die "systemd unit files were staged; there is no systemd here and shipping them would suggest the daemon is started when it is not"
fi

log "note: wpa_supplicant is D-Bus activated, so nothing needs to start it at boot --"
log "note: dbus-daemon starts it when NetworkManager first asks for fi.w1.wpa_supplicant1."
