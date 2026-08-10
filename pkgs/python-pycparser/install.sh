#!/bin/sh
# Install pycparser, which is pure Python and needs no build stage.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a pycparser "$DESTDIR$sitedir/" || die "could not stage pycparser"

[ -f "$DESTDIR$sitedir/pycparser/c_parser.py" ] || die "pycparser was not staged"

finish_install
log "installed pycparser into $sitedir"
