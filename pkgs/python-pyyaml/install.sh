#!/bin/sh
# Install PyYAML as pure Python.
#
# The optional C extension binds libyaml for speed. It is not built: it would
# make an arch-independent package arch-specific, and the only consumer here is
# mesa's build, which parses a handful of small files once.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"

install -d "$DESTDIR$sitedir"
cp -a lib/yaml "$DESTDIR$sitedir/" || die "could not stage yaml"

# lib/_yaml is the shim that re-exports the C extension; without the extension
# built it imports nothing that exists, so it is left out rather than shipped
# broken.
[ -f "$DESTDIR$sitedir/yaml/__init__.py" ] || die "yaml was not staged"

finish_install
log "installed PyYAML into $sitedir"
