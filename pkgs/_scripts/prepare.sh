#!/bin/sh
# Stage 2 -- apply patches.
#
# tape has no notion of a patch, so this is where upstream fixes and the
# distribution's own changes get applied. Patches are applied in sorted order
# from <recipe>/patches/, which makes the order explicit in the filenames rather
# than hidden in a script.

. "$(dirname "$0")/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to prepare"
	exit 0
fi

patches=$RECIPE_DIR/patches
if [ ! -d "$patches" ]; then
	exit 0
fi

for p in "$patches"/*.patch; do
	# The glob stays literal when the directory is empty.
	[ -e "$p" ] || continue
	log "applying $(basename "$p")"
	patch -d "$SRC_PATH" -p1 --no-backup-if-mismatch <"$p" || die "patch $(basename "$p") did not apply"
done
