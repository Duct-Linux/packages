#!/bin/sh
# Build OpenSSL.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# Configured in-tree: OpenSSL's Configure supports out-of-tree builds badly
# enough that every distribution builds it in place.
#
# openssldir points at the certificate directory ca-certificates already
# populates, so a freshly installed openssl trusts the same roots tape does
# rather than an empty store.
log "configuring"
./Configure \
	--prefix=/usr \
	--openssldir=/etc/ssl \
	--libdir=lib \
	shared \
	zlib-dynamic \
	|| die "Configure failed"

log "building"
make -j"$JOBS" || die "make failed"
