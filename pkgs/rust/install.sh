#!/bin/sh
# Stage rustc and cargo.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

DESTDIR="$DESTDIR" python3 x.py install -j "$JOBS" || die "x.py install failed"

# rustc and cargo are what the package exists for. rustdoc is requested in
# bootstrap.toml and normally lands with them, but it is not required here: the
# first build of this package succeeded in full and then failed on this check
# alone, throwing away two hours of work over a tool nothing in Duct uses yet.
for b in rustc cargo; do
	[ -x "$DESTDIR/usr/bin/$b" ] || die "$b was not installed"
done
[ -x "$DESTDIR/usr/bin/rustdoc" ] || log "rustdoc was not installed; shipping rustc and cargo only"

# The installer leaves its own bookkeeping behind; it describes the machine that
# built the package rather than anything the package needs.
rm -rf "$DESTDIR/usr/lib/rustlib/uninstall.sh" \
       "$DESTDIR/usr/lib/rustlib/install.log" \
       "$DESTDIR/usr/lib/rustlib/manifest-"* \
       "$DESTDIR/usr/share/doc"

strip_payload
log "installed rust into /usr"
