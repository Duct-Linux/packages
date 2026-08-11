#!/bin/sh
# Stage highway, then prove it shipped a SHARED library and the cmake package
# file libjxl actually looks for.
#
# WHY THIS ASSERTION EXISTS. highway's own CMakeLists.txt:561 declares
#
#   option(BUILD_SHARED_LIBS "Build shared libraries" OFF)
#
# so the upstream default is a STATIC-ONLY build. _scripts/build-cmake.sh passes
# -DBUILD_SHARED_LIBS=ON, which is why that default is not what happens here --
# but it is a value set in a shared script two directories away, and a static
# build installs cleanly. libhwy.a is a perfectly good package as far as
# finish_install's emptiness guard is concerned. The failure would surface in
# libjxl, as a link error naming a library that this package appears to have
# installed correctly.
#
# The cmake config file is asserted separately because it, not the .pc, is what
# resolves the dependency: libjxl's third_party/CMakeLists.txt:34 calls
# find_package(HWY 1.0.7), which is Config mode and reads
# /usr/lib/cmake/hwy/hwy-config.cmake. The version file next to it is what makes
# the "1.0.7" in that call mean anything -- without it cmake cannot answer the
# version query and the find fails despite the library being present.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

[ -s "$DESTDIR/usr/lib/libhwy.so" ] || \
	die "libhwy.so is missing or empty; highway defaults to a STATIC-only build (CMakeLists.txt:561) and libjxl links the shared library"
[ -s "$DESTDIR/usr/lib/pkgconfig/libhwy.pc" ] || \
	die "libhwy.pc is missing or empty"
[ -s "$DESTDIR/usr/lib/cmake/hwy/hwy-config.cmake" ] || \
	die "hwy-config.cmake is missing or empty; libjxl resolves highway with find_package(HWY 1.0.7), which is cmake Config mode and reads this file rather than the .pc"
[ -s "$DESTDIR/usr/lib/cmake/hwy/hwy-config-version.cmake" ] || \
	die "hwy-config-version.cmake is missing or empty; without it find_package(HWY 1.0.7) cannot satisfy its version request even though the library is installed"

finish_install
log "installed highway with a shared libhwy and its cmake package files"
