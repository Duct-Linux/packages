#!/bin/sh
# Repair an omission in the 2.12 tarball before building it.
#
# grub-core/Makefile.am names $(top_srcdir)/grub-core/extra_deps.lst as a
# prerequisite of syminfo.lst, and the release tarball does not contain that
# file -- it was never added to EXTRA_DIST. Every build of 2.12 from the
# published source therefore stops with
#
#   No rule to make target 'grub-core/extra_deps.lst', needed by 'syminfo.lst'
#
# It is a list of extra module dependencies and being empty is its normal
# state; upstream's own tree has it empty. So this is not a workaround for a
# bug in GRUB's code, it is supplying a file the distribution tarball forgot.
#
# Not a patch in patches/, because a patch that creates an empty file is
# awkward to express and impossible to read. This says what it does.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_DIR:-}" ] || die "no source tree to prepare"

deps=$SRC_PATH/grub-core/extra_deps.lst
if [ ! -f "$deps" ]; then
	log "creating the missing grub-core/extra_deps.lst"
	: >"$deps"
fi

# The shared prepare stage's job -- apply patches/*.patch in sorted order --
# still has to happen. There are none today; doing it here anyway means adding
# one later does not also require remembering to change this file.
patches=$RECIPE_DIR/patches
if [ -d "$patches" ]; then
	for p in "$patches"/*.patch; do
		[ -e "$p" ] || continue
		log "applying $(basename "$p")"
		patch -d "$SRC_PATH" -p1 --no-backup-if-mismatch <"$p" || \
			die "patch $(basename "$p") did not apply"
	done
fi
