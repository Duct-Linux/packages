#!/bin/sh
# Install the binaries, and then the two D-Bus files `make install` does not.
#
# Upstream's install target handles $(BINALL) -- wpa_supplicant and wpa_cli --
# plus wpa_passphrase, and nothing else. Everything that makes the daemon
# REACHABLE is left in the build tree.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH/wpa_supplicant" || die "the wpa_supplicant/ subdirectory is missing"

# BINDIR must be named. Upstream defaults it to /usr/local/sbin (Makefile line
# 46), which is not on the PATH duct-filesystem sets and is not where anything
# would look for a system daemon.
#
# /usr/sbin is a REAL DIRECTORY here, not a compatibility symlink:
# duct-filesystem creates usr/bin, usr/sbin and usr/lib as directories and
# makes the top-level /bin, /sbin and /lib symlinks INTO them (install.sh
# lines 18 and 42). So staging into /usr/sbin is safe, and staging into /sbin
# would be the mistake -- the same hazard bluez's --with-udevdir and fuse3's
# recipe are written around.
# The SAME $WPA_BINDIR the build stage used. If these two ever disagree the
# binaries and the activation file point at different places, and the daemon
# becomes unstartable while looking perfectly installed -- so the value lives in
# pkg.env and neither stage spells it out.
log "installing into the staging root"
make install DESTDIR="$DESTDIR" BINDIR="$WPA_BINDIR" LIBDIR=/usr/lib \
	|| die "make install failed"

# THE D-BUS ACTIVATION FILE. This is the whole reason install.sh exists.
#
# NetworkManager does not start wpa_supplicant; it sends a message to
# fi.w1.wpa_supplicant1 and lets dbus-daemon start it. That works only if this
# file is in the system-services directory, and `make install` never puts it
# there. Without it the daemon is installed, correct, and never runs.
#
# Unlike bluez -- whose activation file ships Exec=/bin/false and is better
# left out -- this one carries a real Exec, generated from the .in with our
# BINDIR substituted (Makefile's `%.service: %.service.in` rule). It names
# SystemdService= as well, which dbus-daemon ignores when it is not running
# under systemd; the Exec line is what is used here.
log "installing the D-Bus activation file and bus policy"
install -d -m 0755 "$DESTDIR/usr/share/dbus-1/system-services"
install -m 0644 dbus/fi.w1.wpa_supplicant1.service \
	"$DESTDIR/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service" \
	|| die "could not install the D-Bus activation file"

# THE BUS POLICY, which is the other half and fails differently. dbus-daemon's
# system.conf denies by default, so without this wpa_supplicant starts, cannot
# acquire fi.w1.wpa_supplicant1, and exits -- and NetworkManager reports a
# supplicant that keeps dying rather than one that is not permitted.
#
# /usr/share/dbus-1/system.d rather than /etc/dbus-1/system.d, which is where
# BLFS puts it. Both are read, and they mean different things: /etc is for
# local administrative overrides, /usr/share is for policy a package owns.
# Putting a package's own file in /etc makes it a configuration file the
# package manager fights the administrator over. bluez's bluetooth.conf lands
# in /usr/share for the same reason -- upstream chose it there, and this
# matches so the two Bluetooth and Wi-Fi daemons are not in different places.
install -d -m 0755 "$DESTDIR/usr/share/dbus-1/system.d"
install -m 0644 dbus/dbus-wpa_supplicant.conf \
	"$DESTDIR/usr/share/dbus-1/system.d/wpa_supplicant.conf" \
	|| die "could not install the D-Bus bus policy"

# NOT INSTALLED, deliberately: systemd/*.service. The default target generates
# four of them (Makefile lines 4-7) because `ALL` names them unconditionally.
# There is no systemd here, nothing would read them, and shipping unit files
# for an init system that is absent is how a later reader concludes the daemon
# is started when it is not.

finish_install
