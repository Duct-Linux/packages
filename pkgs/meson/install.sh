#!/bin/sh
# Install meson by hand.
#
# Not via setup.py: Python 3.13 dropped distutils, and Duct's interpreter is
# built --without-ensurepip, so there is no setuptools to provide the
# replacement. A pure-Python package is a directory and a script, and copying
# them is both simpler and immune to whatever the packaging ecosystem does next.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# Asked of the interpreter rather than assembled from a version number, so a
# Python bump moves this without anyone remembering to.
sitedir=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
	|| die "cannot ask python3 where its site-packages live"
case "$sitedir" in
	/*) ;;
	*) die "python3 reported a relative site-packages path: $sitedir" ;;
esac

install -d "$DESTDIR$sitedir" "$DESTDIR/usr/bin"
cp -a mesonbuild "$DESTDIR$sitedir/" || die "could not stage mesonbuild"

# meson.py is the entry point; upstream's own installation renames it.
install -m 0755 meson.py "$DESTDIR/usr/bin/meson"

# The test corpus is larger than meson itself and is of no use once installed.
find "$DESTDIR$sitedir/mesonbuild" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

[ -x "$DESTDIR/usr/bin/meson" ] || die "meson was not installed"
[ -f "$DESTDIR$sitedir/mesonbuild/mesonmain.py" ] || die "mesonbuild was not staged"

finish_install
log "installed meson into $sitedir"
