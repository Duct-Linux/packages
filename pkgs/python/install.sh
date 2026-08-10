#!/bin/sh
# Install Python, and give it the unversioned names things actually invoke.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
make DESTDIR="$DESTDIR" install || die "make install failed"

# Upstream installs python3 and python3.13 but no bare `python`. Plenty of
# configure scripts -- glibc's among them -- look for `python`, so the absence
# is the difference between building and not.
cd "$DESTDIR/usr/bin"
[ -e python3 ] || die "python3 was not installed"
[ -e python ] || ln -s python3 python

# The extension modules this interpreter is expected to have.
#
# Python's build compiles the extension modules whose dependencies it can find
# and silently omits the rest. There is no error and no warning: configure
# succeeds, make succeeds, and the interpreter is simply incomplete. The gap
# then surfaces somewhere else entirely -- this was found when mesa's code
# generator died with "No module named '_ctypes'", three tiers away, because
# python had been built before libffi was packaged. The same build had no ssl
# either, and nothing had noticed.
#
# Checked by looking for the module files rather than by importing them: the
# staged interpreter cannot find libpython from a staging root, and the loader
# error that produces looks like a broken build when nothing is wrong.
#
# readline and sqlite3 are deliberately absent from this list: their libraries
# are genuinely not packaged, and they are the two worth adding the moment
# either is.
#
# _ssl was absent from it too, for a different reason worth remembering. Under
# OpenSSL 4.0 the module could not be built at all -- 4.0 made ASN1_OCTET_STRING
# and ASN1_IA5STRING opaque and _ssl reaches directly into them. The
# distribution moved to 3.5 LTS, so it builds, and it is asserted here.
for mod in _ctypes _ssl zlib _bz2 _lzma _curses; do
	if [ -z "$(find "$DESTDIR/usr/lib" -name "$mod.*.so" -o -name "$mod.so" 2>/dev/null | head -1)" ]; then
		die "the $mod extension was not built. Python omits a module whose
	dependency was missing at configure time without saying so -- check that
	this package's dependencies are all installed *before* it is built."
	fi
done

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
strip_payload

# Deliberately not running the staged binary to report its version: it cannot
# find libpython in a staging root, and the resulting loader error looks like a
# broken build when nothing is wrong.
log "installed python $PYTHON_VERSION"
