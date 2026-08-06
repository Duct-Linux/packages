#!/bin/sh
# Stage 3 -- configure and compile.
#
# The generic autotools path: out-of-tree configure with $CONFIGURE_ARGS, then
# make. A package whose build does not fit this shape ships its own build.sh and
# points build.script at it instead.

. "$(dirname "$0")/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to build"
	exit 0
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Out-of-tree by default. glibc refuses an in-tree build outright, gcc strongly
# prefers one, and it keeps the unpacked source pristine so a failed build can be
# retried without re-fetching.
log "configuring"
# shellcheck disable=SC2086
"$SRC_PATH/configure" --prefix=/usr ${CONFIGURE_ARGS:-} || die "configure failed"

log "building with -j$JOBS"
# shellcheck disable=SC2086
make -j"$JOBS" ${MAKE_ARGS:-} || die "make failed"
