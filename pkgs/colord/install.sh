#!/bin/sh
# Stage colord, then prove the daemon will actually run as the colord account
# rather than as root.
#
# WHY THIS ASSERTION EXISTS, and why it is not the usual "did the library ship"
# check. duct-filesystem's passwd and group templates have carried a colord
# account at uid/gid 71 since before this recipe existed. That account is worth
# nothing on its own: what makes it matter is the daemon being configured to
# drop to it, and those are two independent facts that nothing connects.
#
# Upstream's default disconnects them. meson_options.txt has
# daemon_user='root', and meson.build 196-197 downgrades that to a WARNING --
# "RUNNING THE DAEMON AS root IS NOT A GOOD IDEA" -- rather than an error. So a
# recipe that simply forgot the flag produces a clean build, a clean install, a
# green CI run, and a system colour daemon running as root with an unused colord
# account sitting in /etc/passwd next to it.
#
# The flag is therefore not evidence. What is checked here is the artefact the
# flag is supposed to produce: the D-Bus system activation file, which is
# generated from data/org.freedesktop.ColorManager.service.in and carries
# User=@daemon_user@ literally. If that line says root, the daemon runs as root,
# whatever pkg.env intended -- so grep for the value, and reject root
# explicitly rather than merely looking for the word colord somewhere.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

[ -s "$DESTDIR/usr/lib/libcolord.so" ] || \
	die "libcolord.so is missing or empty"
[ -s "$DESTDIR/usr/lib/pkgconfig/colord.pc" ] || \
	die "colord.pc is missing or empty; gnome-settings-daemon and gnome-control-center resolve colord through pkg-config"
[ -s "$DESTDIR/usr/bin/colormgr" ] || \
	die "colormgr is missing or empty; it is the only part of colord a person runs directly and the cheapest way to check the daemon by hand"

service="$DESTDIR/usr/share/dbus-1/system-services/org.freedesktop.ColorManager.service"
[ -s "$service" ] || \
	die "the D-Bus system service file is missing or empty; colord is D-Bus activated and without it nothing can ever start the daemon"

if grep -q '^User=root' "$service"; then
	die "colord's D-Bus service file says User=root. -Ddaemon_user defaults to root and upstream only WARNS about it (meson.build:196), so this is what a missing -Ddaemon_user=colord looks like after a completely successful build. duct-filesystem ships a colord account at uid 71 precisely so the daemon does not need root"
fi
grep -q '^User=colord' "$service" || \
	die "colord's D-Bus service file does not say User=colord. Whatever it does say, the daemon will not run as the account duct-filesystem provisions for it"

typelib=$(find "$DESTDIR/usr/lib/girepository-1.0" -name 'Colord-*.typelib' -print -quit 2>/dev/null)
[ -n "$typelib" ] && [ -s "$typelib" ] || \
	die "no non-empty Colord typelib was installed, but introspection was requested; the Settings Colour panel reaches colord through it"

finish_install
log "installed colord, D-Bus activated as the colord account"
