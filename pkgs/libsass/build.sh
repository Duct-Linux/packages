#!/bin/sh
# Build libsass from its own Makefile.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# LIBSASS_VERSION would otherwise be derived by asking git, and there is no git
# repository here -- the build falls back to "[NA]" and stamps that into
# libsass.pc, where anything doing a version comparison then fails.
export LIBSASS_VERSION=3.6.6

log "building with -j$JOBS"
make -j"$JOBS" shared || die "make failed"
