#!/bin/sh
# Apply the FHS patch: glibc still wants to put runtime state in /var/db.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${EXTRA_URL:-}" ] || die "EXTRA_URL is not set"

# No network here, by design. duct/builder ships without curl and wget so a
# package build cannot reach out, and the patch arrives the same way the tarball
# does: fetched and verified on the build machine (tools/fetch-source.sh in CI,
# tools/pin-versions.sh locally) and mounted read-only at $SRC_CACHE.
#
# The previous version fetched it here and fell back to wget. That worked on
# every local run -- pin-versions.sh had already put the patch in the cache, so
# the download was skipped -- and failed in CI the moment the cache did not have
# it, which is the one place the code path actually ran.
patchfile=$SRC_CACHE/$(basename "$EXTRA_URL")
[ -f "$patchfile" ] || die "$(basename "$EXTRA_URL") is not in $SRC_CACHE; run tools/fetch-source.sh glibc"
verify_sha256 "$patchfile" "$EXTRA_SHA256" || die "patch digest mismatch: $patchfile"

log "applying $(basename "$patchfile")"
patch -d "$SRC_PATH" -Np1 -i "$patchfile"
