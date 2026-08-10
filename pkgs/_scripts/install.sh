#!/bin/sh
# Stage 4 -- stage the install tree.
#
# Everything under $DESTDIR maps 1:1 onto / in the installed system, so this is
# also where the payload gets pruned of things that must not ship. The pruning
# itself lives in common.sh's finish_install, because the meson install stage
# needs exactly the same treatment.

. "$(dirname "$0")/common.sh"

if [ -n "${SRC_DIR:-}" ]; then
	cd "$BUILD_DIR"
	log "installing into the staging root"
	# shellcheck disable=SC2086
	make DESTDIR="$DESTDIR" ${MAKE_INSTALL_ARGS:-install} || die "make install failed"
fi

finish_install
