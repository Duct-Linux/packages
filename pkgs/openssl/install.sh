#!/bin/sh
# Stage OpenSSL.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# install_sw is the libraries, headers and tools. The full `install` target also
# writes a certificate store, which is ca-certificates' job -- two packages
# claiming one path is a hard error in tape, and rightly so.
make DESTDIR="$DESTDIR" install_sw install_ssldirs || die "make install failed"

# ca-certificates owns the bundle; openssl must not ship one of its own.
rm -f "$DESTDIR/etc/ssl/cert.pem"
rm -rf "$DESTDIR/etc/ssl/certs"

[ -x "$DESTDIR/usr/bin/openssl" ] || die "the openssl tool was not installed"
[ -f "$DESTDIR/usr/lib/libssl.so" ] || die "libssl was not installed"

find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
rm -rf "$DESTDIR/usr/share/doc"
strip_payload

log "installed openssl"
