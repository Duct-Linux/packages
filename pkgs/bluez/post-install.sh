#!/bin/sh
# Assert bluetoothd and the two files that decide whether anything may talk to
# it, and record the one thing a package cannot do for itself.

. "$(dirname "$0")/../_scripts/common.sh"

# THE DAEMON. Not in /usr/bin or /usr/sbin: bluez installs it with
# pkglibexec_PROGRAMS, so it lands in /usr/libexec/bluetooth/. Asserted at the
# path it actually occupies, confirmed by staging the install rather than by
# reading Makefile.am -- the whole panel is a client of this one binary.
[ -x "$DESTDIR/usr/libexec/bluetooth/bluetoothd" ] \
	&& [ -s "$DESTDIR/usr/libexec/bluetooth/bluetoothd" ] \
	|| die "bluetoothd was not installed as a non-empty executable at /usr/libexec/bluetooth/bluetoothd"

# THE MECHANISM BESIDE THE PAYLOAD. dbus-daemon's system.conf denies everything
# by default; bluetooth.conf is what allows root to own org.bluez and everyone
# else to send to it. Without it bluetoothd starts, fails to acquire its name,
# and exits -- a daemon that is present, executable and unable to run, which is
# indistinguishable from a Bluetooth-hardware problem at the panel.
[ -s "$DESTDIR/usr/share/dbus-1/system.d/bluetooth.conf" ] \
	|| die "the D-Bus policy bluetooth.conf is missing; bluetoothd could not acquire org.bluez and would exit at startup"

# The main configuration, which is also the proof that --sysconfdir=/etc took
# effect. Losing that flag puts this under /usr/etc/bluetooth, where bluetoothd
# does not look, and every setting silently reverts to its compiled-in default.
[ -s "$DESTDIR/etc/bluetooth/main.conf" ] \
	|| die "/etc/bluetooth/main.conf is missing; --sysconfdir=/etc did not take effect"

# --enable-library, asserted because it is on for a consumer in ANOTHER chain
# (pipewire's bluez5 plugin includes <bluetooth/bluetooth.h> and links
# libbluetooth). Nothing in this chain would notice its absence, which is
# precisely why it needs a check here rather than a discovery there.
[ -s "$DESTDIR/usr/lib/pkgconfig/bluez.pc" ] \
	|| die "bluez.pc is missing; --enable-library did not take effect and pipewire's bluez5 plugin will not find this package"
[ -s "$DESTDIR/usr/lib/libbluetooth.so" ] \
	|| die "libbluetooth.so (the unversioned symlink) is missing or dangling"
[ -s "$DESTDIR/usr/include/bluetooth/bluetooth.h" ] \
	|| die "the bluetooth headers were not installed"

# --enable-hid2hci. Both halves: the tool is useless without the rule that runs
# it, and the rule is what would silently move to /lib/udev if --with-udevdir
# were ever lost -- taking duct-filesystem's /lib symlink with it.
[ -s "$DESTDIR/usr/lib/udev/rules.d/97-hid2hci.rules" ] \
	|| die "the hid2hci udev rule is missing from /usr/lib/udev/rules.d"
[ -x "$DESTDIR/usr/lib/udev/hid2hci" ] \
	|| die "hid2hci was not installed"
if [ -d "$DESTDIR/lib" ]; then
	die "bluez staged into /lib; duct-filesystem owns that symlink and packaging it would replace it with a directory"
fi

# NOT AN ASSERTION, AND IT CANNOT BE ONE: nothing this package installs starts
# the daemon. src/org.bluez.service -- the D-Bus activation file -- is installed
# inside `if SYSTEMD` in Makefile.am, so --disable-systemd means it is not
# shipped, and there is no other activation path. bluetoothd must be started by
# the init system.
#
# Its absence is the right outcome rather than a gap to fill: upstream's file is
# Exec=/bin/false with SystemdService=dbus-org.bluez.service, so shipping it on
# a system without systemd would produce a service that looks activatable and
# runs /bin/false.
log "note: nothing activates bluetoothd -- no org.bluez.service is shipped without systemd."
log "note: the boot path (duct-live) must start /usr/libexec/bluetooth/bluetoothd, or the Bluetooth panel will show no adapter."
