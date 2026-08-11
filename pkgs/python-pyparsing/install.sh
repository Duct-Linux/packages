#!/bin/sh
# Install pyparsing, which is pure Python and needs no build stage.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a pyparsing "$DESTDIR$sitedir/" || die "could not stage pyparsing"

# The module flatpak's schema compiler imports, rather than merely the directory.
[ -f "$DESTDIR$sitedir/pyparsing/core.py" ] || die "pyparsing was not staged"

finish_install
log "installed pyparsing into $sitedir"
