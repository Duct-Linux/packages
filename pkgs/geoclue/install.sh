#!/bin/sh
# Stage geoclue and check the three things that are decided somewhere other than
# this recipe's flag list.
#
# Assertions run AFTER finish_install: strip is the last step to touch these
# files, so this is the tree that ships.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The service itself, and the convenience library gnome-control-center links.
[ -s "$DESTDIR/usr/libexec/geoclue" ] || die "the geoclue daemon was not installed; -Denable-backend produced nothing"

lib=$(find "$DESTDIR/usr/lib" -maxdepth 1 -name 'libgeoclue-2.so.0.*' -type f -print -quit 2>/dev/null)
[ -n "$lib" ] && [ -s "$lib" ] || die "no libgeoclue-2.so.0.* was installed; -Dlibgeoclue produced nothing"
[ -s "$DESTDIR/usr/lib/pkgconfig/libgeoclue-2.0.pc" ] || die "libgeoclue-2.0.pc is missing or empty"

# THE MODEM SOURCES, WHICH ARE THE WHOLE REASON ModemManager IS DECLARED.
# Checked on the artefact rather than on the three flags: mm-glib is added to
# geoclue_deps (src/meson.build:36) only when at least one of them is on, so its
# absence from the link is exactly what "the flags stopped taking" looks like --
# and the daemon would still build, install and answer on D-Bus with no way to
# use a modem.
if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; cannot verify the modem sources linked, and nothing else can see them"
fi
readelf -d "$DESTDIR/usr/libexec/geoclue" 2>/dev/null | grep -q 'NEEDED.*libmm-glib' \
	|| die "the geoclue daemon does not link libmm-glib; the 3g/cdma/modem-gps sources resolved to nothing and a machine with a WWAN card could not report a position"

# -Dnmea-source=false, asserted as an absence on the same object. avahi is not
# packaged, so this would have failed at configure rather than silently -- but
# the option defaults TRUE, so the check is here to catch the flag being lost
# rather than the dependency being missing.
if readelf -d "$DESTDIR/usr/libexec/geoclue" 2>/dev/null | grep -qE 'NEEDED.*libavahi'; then
	die "the geoclue daemon links libavahi; -Dnmea-source=false did not take"
fi

# -Ddemo-agent=false. The demo agent is the only thing that pulls libnotify, so
# its absence is the trace of the flag.
if [ -e "$DESTDIR/usr/libexec/geoclue-2.0/demos/agent" ]; then
	die "the demo agent was installed; -Ddemo-agent=false did not take and libnotify came with it"
fi

# THE D-BUS POLICY, WITHOUT WHICH THE SERVICE CANNOT CLAIM ITS NAME.
# data/meson.build:44 computes this path from $datadir when -Ddbus-sys-dir is
# empty, which is the default and is deterministic -- so this asserts the
# computation landed where the system bus actually reads, rather than that some
# file exists somewhere.
[ -s "$DESTDIR/usr/share/dbus-1/system.d/org.freedesktop.GeoClue2.conf" ] \
	|| die "the GeoClue2 D-Bus policy was not installed under /usr/share/dbus-1/system.d; geoclue would fail to claim its bus name"

# THE UNIT THAT MUST NOT BE THERE, AND WHY THIS IS AN ASSERTION RATHER THAN A
# FLAG. -Dsystemd-system-unit-dir is a string option with no value, which in
# these files means "go and find it": data/meson.build:57 falls back to
# `dependency('systemd', required: false)` and installs geoclue.service only if
# that resolves. elogind ships libelogind.pc and the libsystemd.pc alias but NOT
# systemd.pc, so it fails CLOSED here -- the right outcome reached by accident.
# There is no option value meaning "never", so this is what converts the
# accident into a guarantee: if anyone ever packages a systemd.pc, this fails
# instead of quietly installing a unit nothing will start.
if [ -n "$(find "$DESTDIR" -name 'geoclue.service' -print -quit 2>/dev/null)" ]; then
	die "geoclue.service was installed; something now provides systemd.pc and the empty-string default found it -- this tree has no systemd to start it"
fi

log "installed geoclue with its modem sources linked and no systemd unit"
