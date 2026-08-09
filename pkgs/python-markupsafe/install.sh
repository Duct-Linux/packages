#!/bin/sh
# Install MarkupSafe as pure Python.
#
# _speedups.c is not compiled. __init__.py imports it inside a try/except and
# falls back to _native.py, so the module is complete without it -- and building
# it would make an arch-independent package arch-specific to save microseconds
# in a template renderer that runs a handful of times per build.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a src/markupsafe "$DESTDIR$sitedir/" || die "could not stage markupsafe"
rm -f "$DESTDIR$sitedir/markupsafe/_speedups.c" "$DESTDIR$sitedir/markupsafe/_speedups.pyi"

[ -f "$DESTDIR$sitedir/markupsafe/_native.py" ] || die "the pure-Python fallback is missing"

finish_install
log "installed markupsafe into $sitedir"
