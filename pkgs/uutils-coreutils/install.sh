#!/bin/sh
# Install the multicall binary and one symlink per applet.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# LN='ln -sf' is the whole fix for what used to be a 643 MB package.
#
# MULTICALL=y installs one 14 MB binary and 107 links to it. Upstream's default
# is LN ?= ln -f, so those are *hard* links -- correct and compact on disk, one
# inode for the lot. tape's archiver has no hard-link support: it walks the tree
# and writes each path as a regular file, so all 108 were stored in full.
#
# The earlier workaround deleted the duplicates afterwards and replaced them
# with symlinks, comparing digests to be sure. That worked, but it was repairing
# something that never needed to happen: LN is ?=, so asking for symlinks in the
# first place costs nothing and leaves nothing to undo.
#
# Worth knowing: any other package that installs hard links will still be
# stored expanded. That is a limitation in tape's archiver, not in the package.
make PROFILE=release MULTICALL=y CARGOFLAGS=--locked LN='ln -sf' \
	PREFIX=/usr DESTDIR="$DESTDIR" install \
	|| die "make install failed"

multicall=$DESTDIR/usr/bin/coreutils
[ -x "$multicall" ] || die "the multicall binary was not installed"

strip_payload

# Verify the links really are links. If upstream ever changes how MULTICALL
# installs, the package silently grows by two orders of magnitude, and the only
# symptom is a slow download.
regular=0
for f in "$DESTDIR"/usr/bin/*; do
	[ -f "$f" ] || continue
	[ -L "$f" ] && continue
	[ "$f" = "$multicall" ] && continue
	regular=$((regular + 1))
done
[ "$regular" -eq 0 ] || die "$regular applets installed as regular files, not links to coreutils"

# The applets a system cannot function without. The old distro scripts
# symlinked five by hand and left a "ToDo: fix this"; this checks rather than
# hopes.
for applet in ls cat cp mv rm mkdir chmod chown ln; do
	[ -e "$DESTDIR/usr/bin/$applet" ] || die "applet $applet is missing"
done

log "installed the multicall binary and $(find "$DESTDIR/usr/bin" -maxdepth 1 -type l | wc -l) applet symlinks"
