#!/bin/sh
# Stage 3 -- configure and compile with cmake.
#
# The third of the three build systems in this package set. Used by the handful
# of packages that ship a CMakeLists.txt and nothing else; anything offering
# autotools or meson as well uses those, because they need less coaxing to put
# their output in the right place.

. "$(dirname "$0")/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to build"
	exit 0
fi

command -v cmake >/dev/null 2>&1 || die "cmake is not installed"
command -v ninja >/dev/null 2>&1 || die "ninja is not installed"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# CMAKE_INSTALL_LIBDIR=lib for the same reason meson is given --libdir=lib:
# cmake's GNUInstallDirs picks lib64 on a 64-bit system whenever /usr/lib64
# exists, and on a merged-/usr layout nothing searches there.
#
# Ninja rather than make, because cmake's makefile generator serialises far more
# of the build than it needs to.
log "configuring"
# shellcheck disable=SC2086
cmake -G Ninja "$SRC_PATH" \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_SHARED_LIBS=ON \
	${CMAKE_ARGS:-} \
	|| die "cmake failed"

log "building with -j$JOBS"
ninja -j"$JOBS" || die "ninja failed"
