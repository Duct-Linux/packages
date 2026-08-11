#!/bin/sh
# Stage libwacom and assert the database and its udev rules both arrived.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

[ -s "$DESTDIR/usr/lib/libwacom.so.9" ] || die "libwacom.so.9 was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/libwacom.pc" ] || die "libwacom.pc was not installed"
[ -s "$DESTDIR/usr/include/libwacom-1.0/libwacom/libwacom.h" ] || die "libwacom.h was not installed"

# THE DATABASE, WHICH IS THE ENTIRE POINT OF THE PACKAGE.
#
# libwacom is a lookup library over a directory of .tablet and .stylus
# descriptions. A build that installed the library and not the data would link,
# load, and answer "unknown device" for every tablet -- which is exactly what a
# missing datadir looks like from above, and is not an error anywhere.
[ -d "$DESTDIR/usr/share/libwacom" ] || die "the tablet database directory was not installed"
if [ -z "$(find "$DESTDIR/usr/share/libwacom" -name '*.tablet' -print -quit)" ]; then
	die "the tablet database is empty; libwacom would report every device as unknown"
fi
# THE UDEV RULES, at the path eudev reads. Asserted at the absolute path so a
# future -Dudev-dir, or a change to how the default is derived from the prefix,
# fails here rather than at first boot with a tablet that is never tagged.
[ -s "$DESTDIR/usr/lib/udev/rules.d/65-libwacom.rules" ] \
	|| die "65-libwacom.rules was not installed where eudev reads rules"
[ -s "$DESTDIR/usr/lib/udev/hwdb.d/65-libwacom.hwdb" ] \
	|| die "the libwacom hwdb entries were not installed"

# -Dtests=disabled, asserted as an absence. The tests install nothing, so this
# is not about the payload -- it is that the option's default reaches for
# pytest and two unpackaged python modules at CONFIGURE time. If a future
# recipe drops the flag the build fails long before here; this catches the
# other direction, an upstream that starts installing test data.
if [ -e "$DESTDIR/usr/share/installed-tests" ]; then
	die "installed-tests were shipped; -Dtests did not take"
fi

log "installed libwacom with its tablet database and udev rules"
