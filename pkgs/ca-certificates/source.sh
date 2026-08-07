#!/bin/sh
# Stage 1 -- take the PEM bundle out of the source cache.
#
# The shared _scripts/fetch.sh cannot be used: it ends in `tar -xf`, and this
# source is a single PEM file rather than an archive. The fetching itself
# happens on the build machine (tools/fetch-source.sh in CI, pin-versions.sh
# locally) because the build container has no curl and no wget on purpose.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_FILE:-}" ] || die "SRC_FILE is not set"
[ -n "${SRC_SHA256:-}" ] || die "SRC_SHA256 is not set"

bundle=$SRC_CACHE/$SRC_FILE
[ -f "$bundle" ] || die "$SRC_FILE is not in $SRC_CACHE; run tools/fetch-source.sh ca-certificates"
verify_sha256 "$bundle" "$SRC_SHA256" || die "bundle digest mismatch: $bundle"

log "using $SRC_FILE ($(grep -c 'BEGIN CERTIFICATE' "$bundle") certificates)"
cp "$bundle" "$WORK_DIR/ca-certificates.crt"
