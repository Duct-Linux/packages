#!/bin/sh
# Stage gnome-settings-daemon and prove that all seventeen plugins were built.
#
# THE PLUGIN LIST IS THE OPTION AUDIT. plugins/meson.build:1-19 names seventeen
# plugins and :21-52 removes one from that list for each option turned off --
# smartcard, usb-protection, wacom, cups (which removes TWO: cups and
# print-notifications), rfkill, wwan and colord. So a dependency this recipe
# failed to provide does not fail the build: it silently subtracts a daemon, and
# the session comes up with no colour management, or no printer notifications,
# or no media keys, and nothing anywhere reports it.
#
# Checking all seventeen is therefore not a file-list check. It is the assertion
# that every defaulted-on feature actually took -- a defaulted exclusion being a
# silent one.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

missing=""
for p in a11y-settings color datetime power housekeeping keyboard media-keys \
         screensaver-proxy sharing sound usb-protection xsettings smartcard \
         wacom print-notifications rfkill wwan; do
	[ -x "$DESTDIR/usr/libexec/gsd-$p" ] || missing="$missing $p"
done
[ -z "$missing" ] || \
	die "these gsd plugins were not built:$missing -- each corresponds to an option that was on by default and to a dependency this tree was supposed to provide. plugins/meson.build removes a plugin from the build when its option is off, so this is a feature silently subtracted rather than a build failure: colord gates 'color', cups gates BOTH 'cups' and 'print-notifications', and wacom is not even an option (meson.build:173 derives it from the architecture)"

# The schemas. GSettings aborts a process that asks for a schema it cannot find,
# and every one of the daemons above reads its configuration this way -- so a
# missing schema is seventeen daemons that exit at once, from a package whose
# binaries all installed.
[ -d "$DESTDIR/usr/share/glib-2.0/schemas" ] || \
	die "no GSettings schemas were installed; every gsd plugin reads its configuration through GSettings and aborts when the schema is absent"
sc=$(find "$DESTDIR/usr/share/glib-2.0/schemas" -name 'org.gnome.settings-daemon.*.gschema.xml' | wc -l | tr -d ' ')
[ "$sc" -ge 10 ] || \
	die "only $sc settings-daemon schemas were installed, which is too few for seventeen plugins -- the schema install is partial and the daemons that lack one will abort at session start"

# elogind took, not systemd -- checked on gsd-sharing, WHICH IS THE ONLY TARGET
# THAT LINKS IT.
#
# The obvious binary to test is gsd-power, and it would have been wrong:
# elogind_dep appears exactly once in the whole tree, at
# plugins/sharing/meson.build:15, as the elogind arm of the same if/else that
# adds libsystemd_dep on a systemd build. Everything else reaches logind
# functionality over D-Bus and links neither. An assertion on gsd-power would
# have failed on a perfectly good build.
#
# The two options are mutually exclusive by an explicit error(), so reaching
# here proves ONE was chosen. This proves WHICH -- and it matters, because
# choosing systemd would still have linked successfully against elogind's
# libsystemd.pc compatibility symlink and produced a binary bound to a provider
# nobody selected, under a name that says otherwise.
needs() { readelf -d "$1" 2>/dev/null | grep -qE "NEEDED.*\[$2"; }
needs "$DESTDIR/usr/libexec/gsd-sharing" 'lib' || \
	die "the DT_NEEDED reader found no NEEDED entries at all in gsd-sharing, which cannot be true of a linked binary -- the check below would be meaningless"
needs "$DESTDIR/usr/libexec/gsd-sharing" 'libelogind\.so' || \
	die "gsd-sharing does not link libelogind. plugins/sharing/meson.build:15 is the only place elogind_dep is used, so this says -Delogind=true did not select the elogind arm -- most likely the systemd arm ran and bound to elogind's libsystemd.pc symlink instead, which produces a working binary pointed at a provider nobody chose"

finish_install
log "installed gnome-settings-daemon with all seventeen plugins, on elogind"
