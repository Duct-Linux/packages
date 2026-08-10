#!/bin/sh
# hwdata's configure is a short hand-written script that only understands a few
# options and writes its Makefile into the source tree, so the generic
# out-of-tree build stage cannot drive it. There is nothing to compile.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "configuring"
./configure --prefix=/usr --disable-blacklist --datarootdir=/usr/share \
	|| die "configure failed"
