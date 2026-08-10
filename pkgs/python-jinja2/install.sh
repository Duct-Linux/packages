#!/bin/sh
# Install Jinja2, which is pure Python and needs no build stage.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a src/jinja2 "$DESTDIR$sitedir/" || die "could not stage jinja2"

[ -f "$DESTDIR$sitedir/jinja2/environment.py" ] || die "jinja2 was not staged"

finish_install
log "installed jinja2 into $sitedir"
