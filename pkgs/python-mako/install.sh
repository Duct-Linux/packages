#!/bin/sh
# Install Mako, which is pure Python and needs no build stage.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a mako "$DESTDIR$sitedir/" || die "could not stage mako"

[ -f "$DESTDIR$sitedir/mako/template.py" ] || die "mako was not staged"

finish_install
log "installed mako into $sitedir"
