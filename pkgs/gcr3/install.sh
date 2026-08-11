#!/bin/sh
# Stage gcr-3 and assert it is the two libraries gnome-keyring needs and
# nothing that would collide with gcr-4.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# THE TWO LIBRARIES THIS PACKAGE EXISTS FOR. gnome-keyring 48.0 asks for
# gck-1 >= 3.3.4 and gcr-base-3 >= 3.27.90 unconditionally, and gcr-4 cannot
# satisfy either -- it ships gck-2 and gcr-base-4, different names rather than
# newer versions. Majors are CURRENT from meson.build (gck 0.0.0, gcr 1.0.0).
[ -s "$DESTDIR/usr/lib/libgck-1.so.0" ] || die "libgck-1.so.0 was not installed"
[ -s "$DESTDIR/usr/lib/libgcr-base-3.so.1" ] || die "libgcr-base-3.so.1 was not installed"
for pc in gck-1.pc gcr-base-3.pc; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc was not installed"
done
# The header gnome-keyring includes.
[ -s "$DESTDIR/usr/include/gcr-3/gcr/gcr-base.h" ] || die "gcr-base.h was not installed"

# THE COLLISION PATH, ASSERTED ABSENT ON THIS SIDE.
#
# /usr/libexec/gcr-ssh-agent is the single name gcr-3 and gcr-4 both build --
# every other installed name in both packages carries its version. Two packages
# owning one path is a hard install error with no override, so exactly one of
# the pair may ship it, and in this tree that is gcr-4: it is what the live
# session links, while this package is here for two libraries.
#
# This assertion and the matching one in pkgs/gcr/install.sh are a pair. That
# one requires the file to be PRESENT; this one requires it ABSENT. Flipping
# either flag alone therefore fails a build with a message naming the path,
# instead of producing two packages that install fine separately and cannot be
# installed together.
if [ -e "$DESTDIR/usr/libexec/gcr-ssh-agent" ]; then
	die "gcr-ssh-agent was installed; -Dssh_agent did not take and this collides with gcr-4"
fi

# -Dgtk=false, ASSERTED AS THE ABSENCE OF A WHOLE TOOLKIT'S WORTH OF OUTPUT.
# The UI library, the viewer and the prompter all come with it, and so does a
# GTK3 dependency this distribution wants to keep at exactly one consumer.
# gnome-keyring 48.0 removed its gcr-ui-3 dependency deliberately (its NEWS:
# "meson: Remove dependency on gcr-ui-3"), so nothing here needs any of it.
for ui in usr/lib/libgcr-ui-3.so.1 usr/lib/pkgconfig/gcr-ui-3.pc \
          usr/bin/gcr-viewer usr/bin/gcr-prompter; do
	if [ -e "$DESTDIR/$ui" ]; then
		die "$ui was installed; -Dgtk did not take and this package now carries a GTK3 edge"
	fi
done

# The UI half gone means no GTK3 link anywhere in the payload. Checked in the
# library rather than inferred from the file list, because -Dgtk affects what
# is BUILT and this is what shipped.
if command -v readelf >/dev/null 2>&1; then
	if readelf -d "$DESTDIR/usr/lib/libgcr-base-3.so.1" 2>/dev/null | grep -q 'NEEDED.*libgtk-3'; then
		die "libgcr-base-3 links GTK3; the base library was built against the UI"
	fi
else
	die "no readelf; cannot verify the absence of a GTK3 link, and this check is not optional"
fi

# -Dsystemd=disabled.
if [ -e "$DESTDIR/usr/lib/systemd" ]; then
	die "systemd units were installed; -Dsystemd did not take"
fi

log "installed gcr-3 as libraries only: no agent, no UI, no GTK3 edge"
