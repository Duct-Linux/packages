#!/bin/sh
# zlib's configure is a shell script of its own devising: it understands
# --prefix and little else, and it writes its Makefile into the source tree.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "configuring"
./configure --prefix=/usr || die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
