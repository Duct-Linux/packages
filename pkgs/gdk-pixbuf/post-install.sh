#!/bin/sh
# Record what gdk-pixbuf needs that a package cannot do.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/bin/gdk-pixbuf-query-loaders" ] \
	|| die "gdk-pixbuf-query-loaders was not installed"

# loaders.cache lists every loader module installed system-wide, so it is a
# build product of the whole installation rather than of this package. Without
# it gdk-pixbuf loads nothing but its built-in formats -- which is enough to
# make the desktop start and not enough for it to show an icon.
log "note: the image build must run 'gdk-pixbuf-query-loaders --update-cache'"
