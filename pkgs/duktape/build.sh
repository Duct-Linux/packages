#!/bin/sh
# Build duktape as a shared library.
#
# The tarball has no configure and its default Makefile builds the command-line
# interpreter statically. Makefile.sharedlibrary is upstream's supported way to
# get the .so that everything embedding duktape actually links.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

log "building with -j$JOBS"
make -j"$JOBS" -f Makefile.sharedlibrary INSTALL_PREFIX=/usr || die "make failed"
