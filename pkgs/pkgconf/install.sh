#!/bin/sh
# Install pkgconf, including the pkg-config name everything actually looks for.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
make DESTDIR="$DESTDIR" install || die "make install failed"

# pkgconf is a drop-in replacement for pkg-config, but only if it answers to
# that name. Nothing searches for "pkgconf": autotools looks for pkg-config, and
# so does every -sys crate in Rust -- cargo's openssl-sys failed with
# "`pkg-config` could not be found" while pkgconf was installed and on PATH.
#
# Every distribution shipping pkgconf provides this link. Duct did not.
ln -sf pkgconf "$DESTDIR/usr/bin/pkg-config"

# The manual page follows the same rule.
if [ -f "$DESTDIR/usr/share/man/man1/pkgconf.1" ]; then
	ln -sf pkgconf.1 "$DESTDIR/usr/share/man/man1/pkg-config.1"
fi

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
strip_payload

[ -L "$DESTDIR/usr/bin/pkg-config" ] || die "the pkg-config link was not created"
log "installed pkgconf with the pkg-config name"
