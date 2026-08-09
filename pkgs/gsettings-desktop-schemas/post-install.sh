#!/bin/sh
# Record what the schema store needs that a package cannot do.

. "$(dirname "$0")/../_scripts/common.sh"

[ -d "$DESTDIR/usr/share/glib-2.0/schemas" ] || die "no schemas were installed"

# gschemas.compiled is one file built from every schema on the system, so no
# single package can own it -- and GSettings aborts the process rather than
# falling back when it asks for a key and finds no compiled store. Every GNOME
# component would die on startup.
log "note: the image build must run 'glib-compile-schemas /usr/share/glib-2.0/schemas'"
