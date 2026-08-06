#!/bin/sh
# Apply the FHS patch: glibc still wants to put runtime state in /var/db.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${PATCH_URL:-}" ] || die "PATCH_URL is not set"

patchfile=$SRC_CACHE/$(basename "$PATCH_URL")
mkdir -p "$SRC_CACHE"
if [ ! -f "$patchfile" ] || ! verify_sha256 "$patchfile" "$PATCH_SHA256" 2>/dev/null; then
	rm -f "$patchfile"
	log "fetching $(basename "$PATCH_URL")"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$patchfile.part" "$PATCH_URL" || die "cannot fetch the FHS patch"
	else
		wget -q -O "$patchfile.part" "$PATCH_URL" || die "cannot fetch the FHS patch"
	fi
	verify_sha256 "$patchfile.part" "$PATCH_SHA256" || die "patch digest mismatch"
	mv "$patchfile.part" "$patchfile"
fi

log "applying $(basename "$patchfile")"
patch -d "$SRC_PATH" -Np1 -i "$patchfile"
