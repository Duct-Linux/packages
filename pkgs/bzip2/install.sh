#!/bin/sh
# bzip2 has no DESTDIR; PREFIX is the only knob, so it points at the staging
# root and the paths come out right by construction.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

make PREFIX="$DESTDIR/usr" install || die "make install failed"

# The shared library is not installed by the Makefile at all.
install -d "$DESTDIR/usr/lib"
cp -a libbz2.so.* "$DESTDIR/usr/lib/"
ln -sfn "libbz2.so.$(echo "$BZIP2_VERSION")" "$DESTDIR/usr/lib/libbz2.so"

# Replace the statically linked binary the Makefile installed with the shared
# one, so a bzip2 security fix does not mean rebuilding every user of it.
install -m 0755 bzip2-shared "$DESTDIR/usr/bin/bzip2"
for t in bunzip2 bzcat; do
	ln -sfn bzip2 "$DESTDIR/usr/bin/$t"
done

rm -f "$DESTDIR/usr/lib/libbz2.a"
strip_payload
log "installed"
