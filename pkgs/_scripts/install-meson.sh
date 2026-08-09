#!/bin/sh
# Stage 4 -- stage the install tree from a meson build.

. "$(dirname "$0")/common.sh"

if [ -n "${SRC_DIR:-}" ]; then
	# --no-rebuild: `ninja install` otherwise re-runs the whole build, and with
	# it any code generation that wants a network or a display. The build stage
	# has already finished; this stage only copies.
	#
	# --skip-subprojects for the same reason as --wrap-mode=nodownload in the
	# build stage: nothing here may install files a subproject brought in.
	log "installing into the staging root"
	DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
		|| die "meson install failed"
fi

finish_install
