#!/bin/sh
# bzip2 builds the shared library from a separate makefile, then the rest.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "building the shared library"
make -f Makefile-libbz2_so -j"$JOBS" || die "shared library build failed"

# The shared build leaves object files compiled -fPIC that the static build
# must not reuse.
make clean >/dev/null

log "building the tools"
make -j"$JOBS" || die "make failed"
