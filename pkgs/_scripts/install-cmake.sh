#!/bin/sh
# Stage 4 -- stage the install tree from a cmake build.

. "$(dirname "$0")/common.sh"

if [ -n "${SRC_DIR:-}" ]; then
	cd "$BUILD_DIR"
	log "installing into the staging root"
	DESTDIR="$DESTDIR" ninja install || die "ninja install failed"
fi

finish_install
