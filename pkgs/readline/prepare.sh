#!/bin/sh
# Stage 2 -- the three edits LFS makes to readline before it is configured.
#
# Its own stage rather than the generic one because this recipe has no patches
# and needs three seds instead. All three edit files under $SRC_PATH and all
# three must happen BEFORE configure runs: Makefile.in is the template configure
# expands, and support/shobj-conf is read while the shared library link line is
# being decided.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_DIR:-}" ] || die "no source tree to prepare"

# This recipe replaces the generic prepare.sh, which is the only thing that
# applies patches/*.patch. A patch dropped in here later would be silently
# ignored -- so say so rather than let it be discovered by a build that is
# missing a fix nobody can see is missing.
#
# `if`, not `[ -d ... ] && die`: this script runs under `set -e` from common.sh,
# and a trailing && whose left side is false makes the whole compound the
# script's last status -- so the guard would exit 1 in exactly the case where
# there is nothing wrong.
if [ -d "$RECIPE_DIR/patches" ]; then
	die "patches/ exists but this recipe's prepare stage does not apply patches; either fold them in here or switch [prepare] back to ../_scripts/prepare.sh"
fi

cd "$SRC_PATH"

# Reinstalling readline moves the old libraries aside as <name>.old, which can
# trip a linking bug in ldconfig. Nothing here ever reinstalls over a live
# tree -- the install goes into an empty $DESTDIR -- but the renamed leftovers
# would be PACKAGED, and two packages owning one path is a hard install error in
# tape with no override.
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install

# Do not bake an rpath into the shared libraries. The build directory is
# $DESTDIR-relative scaffolding that does not exist on an installed system, so
# an rpath here points at a path that will never be there -- and where it does
# resolve, it silently outranks the loader's own search order.
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf

log "prepared readline (old-library rename removed, rpath stripped)"
