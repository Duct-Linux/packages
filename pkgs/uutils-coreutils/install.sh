#!/bin/sh
# Install the multicall binary and one symlink per applet.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

make PROFILE=release MULTICALL=y PREFIX=/usr DESTDIR="$DESTDIR" install \
	|| die "make install failed"

multicall=$DESTDIR/usr/bin/coreutils
[ -x "$multicall" ] || die "the multicall binary was not installed"

# Strip before deduplicating, so the digests compared below are of the final
# bytes rather than of debug symbols that are about to be removed.
strip_payload

# MULTICALL=y is supposed to give one binary and a symlink per applet. It does
# not -- upstream's install copies the whole 14 MB binary once per applet, which
# packages at 643 MB for what is really 6 MB of program. Anything byte-identical
# to the multicall binary therefore becomes a symlink to it.
#
# Compared by digest rather than assumed by name: an applet that is genuinely a
# separate program must not be replaced by a link to something else.
want=$(sha256sum "$multicall" | cut -d' ' -f1)
linked=0
for f in "$DESTDIR"/usr/bin/*; do
	[ -f "$f" ] || continue
	[ "$f" = "$multicall" ] && continue
	[ -L "$f" ] && continue
	[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] || continue
	rm -f "$f"
	ln -s coreutils "$f"
	linked=$((linked + 1))
done

# The applets a system cannot function without. The old distro scripts
# symlinked five by hand and left a "ToDo: fix this"; this checks rather than
# hopes.
for applet in ls cat cp mv rm mkdir chmod chown ln; do
	[ -e "$DESTDIR/usr/bin/$applet" ] || die "applet $applet is missing"
done

log "installed the multicall binary and $linked applet symlinks"
