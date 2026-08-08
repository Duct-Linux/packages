#!/bin/sh
# Stage CMake.
#
# Its own install stage rather than the shared one: bootstrap configures in the
# source tree, so there is no separate $BUILD_DIR to install from.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"
make DESTDIR="$DESTDIR" install || die "make install failed"

for b in cmake ctest cpack; do
	[ -x "$DESTDIR/usr/bin/$b" ] || die "$b was not installed"
done

rm -rf "$DESTDIR/usr/share/doc"
strip_payload

log "installed $("$DESTDIR/usr/bin/cmake" --version 2>/dev/null | head -1 || echo cmake)"
