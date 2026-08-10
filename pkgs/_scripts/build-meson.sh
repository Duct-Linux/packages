#!/bin/sh
# Stage 3 -- configure and compile with meson.
#
# The counterpart to build.sh for the two thirds of the desktop stack that has
# left autotools behind. A package whose meson build does not fit this shape
# ships its own build.sh and points build.script at it instead.

. "$(dirname "$0")/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to build"
	exit 0
fi

command -v meson >/dev/null 2>&1 || die "meson is not installed"
command -v ninja >/dev/null 2>&1 || die "ninja is not installed"

# meson refuses to reconfigure a directory it did not create, and a half-written
# one left by a failed run is worse than none at all.
rm -rf "$BUILD_DIR"

# --wrap-mode=nodownload, always: meson's fallback for a missing dependency is
# to clone a subproject, and the build containers have no network on purpose. A
# missing dependency has to fail here, loudly, rather than turn into a silent
# vendored copy -- or, in the container, into a confusing git error.
#
# buildtype=release rather than plain: several GNOME components assume NDEBUG
# and ship assertions that are far too expensive to run in a shipped desktop.
#
# --libdir=lib is not cosmetic. meson picks lib64 whenever /usr/lib64 exists as
# a real directory, and duct-filesystem creates one -- it has to, because the
# ELF interpreter path baked into every x86_64 binary is /lib64/ld-linux-x86-64.
# The first meson packages therefore installed their libraries and their .pc
# files into /usr/lib64, where the loader's search path does not reach and where
# pkgconf does not look, so each one built perfectly and then could not be found
# by the next.
log "configuring"
# shellcheck disable=SC2086
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	${MESON_ARGS:-} \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
