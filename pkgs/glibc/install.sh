#!/bin/sh
# Stage glibc, then remove what must not ship.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# glibc's install refuses to run if it thinks it is installing into / with a
# mismatched kernel; DESTDIR staging sidesteps that entirely.
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

# ldd's shebang carries an absolute loader path that is wrong for a system whose
# real libraries live under /usr/lib.
if [ -f "$DESTDIR/usr/bin/ldd" ]; then
	sed -i '/RTLDLIST=/s@/usr@@g' "$DESTDIR/usr/bin/ldd"
fi

# Generated at image assembly time by ldconfig, not owned by any package. If it
# shipped here it would be stale the moment a second library was installed.
rm -f "$DESTDIR/etc/ld.so.cache"

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true

strip_payload

[ -n "$(find "$DESTDIR" -mindepth 1 -print -quit 2>/dev/null)" ] || die "staging root is empty"
log "installed"
