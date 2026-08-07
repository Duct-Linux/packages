#!/bin/sh
# Stage 4 -- stage the trust store.

. "$(dirname "$0")/../_scripts/common.sh"

bundle=$WORK_DIR/ca-certificates.crt
[ -f "$bundle" ] || die "source.sh did not produce ca-certificates.crt"

install -d -m 755 "$DESTDIR/etc/ssl/certs"
install -m 644 "$bundle" "$DESTDIR/etc/ssl/certs/ca-certificates.crt"

# Go's crypto/x509 tries a fixed list of locations and stops at the first hit;
# other TLS stacks each have their own idea of where the store lives. The
# canonical file is the Debian path above, which is the one Go looks for first;
# these are symlinks so every other convention resolves to the same bytes.
install -d -m 755 "$DESTDIR/etc/pki/tls/certs"
ln -sf ../../../ssl/certs/ca-certificates.crt "$DESTDIR/etc/pki/tls/certs/ca-bundle.crt"
ln -sf certs/ca-certificates.crt "$DESTDIR/etc/ssl/cert.pem"

log "installed $(grep -c 'BEGIN CERTIFICATE' "$bundle") CA certificates"

# Not done here: splitting the bundle into per-certificate files with the
# subject-hash symlinks OpenSSL wants for directory lookups. Nothing in Duct
# needs that yet -- tape is Go and reads the single file -- and generating it
# would mean running openssl at install time, which tape has no hooks for.
