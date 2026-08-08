#!/bin/sh
# Stage rustc and cargo.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

DESTDIR="$DESTDIR" python3 x.py install -j "$JOBS" || die "x.py install failed"

for b in rustc cargo rustdoc; do
	[ -x "$DESTDIR/usr/bin/$b" ] || die "$b was not installed"
done

# The installer leaves its own bookkeeping behind; it describes the machine that
# built the package rather than anything the package needs.
rm -rf "$DESTDIR/usr/lib/rustlib/uninstall.sh" \
       "$DESTDIR/usr/lib/rustlib/install.log" \
       "$DESTDIR/usr/lib/rustlib/manifest-"* \
       "$DESTDIR/usr/share/doc"

strip_payload
log "installed rust into /usr"
