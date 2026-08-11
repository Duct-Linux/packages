#!/bin/sh
# Stage upower and assert that the daemon, its authorization and its device
# rules all arrived.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The daemon and the command-line client. upowerd lives in libexecdir because
# nothing starts it by hand -- dbus activates it.
[ -s "$DESTDIR/usr/libexec/upowerd" ] || die "upowerd is missing or empty"
[ -s "$DESTDIR/usr/bin/upower" ] || die "the upower client is missing or empty"

# The library every consumer links, and the .pc that finds it.
[ -s "$DESTDIR/usr/lib/libupower-glib.so.3" ] || die "libupower-glib was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/upower-glib.pc" ] || die "upower-glib.pc was not installed"

# -Dintrospection=enabled asked for this. gnome-shell reads power state through
# UPowerGlib-1.0 and nothing else.
[ -s "$DESTDIR/usr/lib/girepository-1.0/UPowerGlib-1.0.typelib" ] \
	|| die "the UPowerGlib-1.0 typelib was not built; introspection resolved to disabled"

# THE POLKIT ACTION FILE. policy/meson.build installs it only `if
# polkit.found()`, so a build that failed to find polkit produces a complete,
# working, UNAUTHORIZED daemon and says nothing about it. Its presence is the
# only evidence in the payload that -Dpolkit=enabled took effect.
[ -s "$DESTDIR/usr/share/polkit-1/actions/org.freedesktop.upower.policy" ] \
	|| die "no polkit action file; upowerd was built without polkit and would authorize nobody"

# THE UDEV RULES, at the path eudev actually reads. These are what classify a
# power supply as a battery in the first place -- without them upower runs and
# reports no devices, which looks like a machine with no battery rather than a
# packaging error. Asserted at the absolute path so that a wrong -Dudevrulesdir
# fails here instead of at first boot.
for rule in 60-upower-battery.rules 95-upower-wup.rules 95-upower-hid.rules; do
	[ -s "$DESTDIR/usr/lib/udev/rules.d/$rule" ] || die "$rule was not installed where eudev reads rules"
done
[ -s "$DESTDIR/usr/lib/udev/hwdb.d/95-upower-hid.hwdb" ] || die "the upower hwdb entries were not installed"

# D-Bus activation and the bus policy. The daemon is unreachable without both.
[ -s "$DESTDIR/usr/share/dbus-1/system-services/org.freedesktop.UPower.service" ] \
	|| die "the D-Bus activation file was not installed; upowerd could never be started"
[ -s "$DESTDIR/usr/share/dbus-1/system.d/org.freedesktop.UPower.conf" ] \
	|| die "the D-Bus policy file was not installed; upowerd could not own its bus name"

# -Dsystemdsystemunitdir=no and -Dzshcompletiondir=no, asserted rather than
# trusted: both options are strings, so a typo in either is not an error -- it
# is a directory name, and the files land in it.
#
# `if ... then die`, not `[ ... ] && die`: under `set -e` a failing test at the
# head of an AND-list is exactly the shape whose exit status can end the script,
# and here the test failing is the GOOD outcome.
if [ -e "$DESTDIR/usr/lib/systemd" ]; then
	die "a systemd unit was installed; -Dsystemdsystemunitdir did not take"
fi
if [ -e "$DESTDIR/usr/share/zsh" ]; then
	die "a zsh completion was installed; -Dzshcompletiondir did not take"
fi

log "installed upower with polkit authorization and udev rules"
