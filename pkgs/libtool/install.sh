#!/bin/sh
# Stage libtool, then assert libltdl specifically.
#
# WHY libltdl RATHER THAN THE libtool SCRIPT. This package is in the tree for
# the dynamic module loader, not for the build helper: libcanberra dlopens its
# sound backends through libltdl and fails configure outright without it
# (AC_MSG_ERROR "Unable to find libltdl"). The libtool and libtoolize scripts
# install regardless of whether the library did, so a package that shipped only
# them would look complete, satisfy anything looking for "libtool", and fail
# libcanberra under a name that is not this one.
#
# ltdl.h is asserted alongside the library because libcanberra's configure
# checks the HEADER first and only then the library -- a tree with the .so and
# no header takes the same failure path as one with neither.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

[ -s "$DESTDIR/usr/lib/libltdl.so" ] || \
	die "libltdl.so is missing or empty. This package exists for libltdl -- libcanberra dlopens its sound backends through it and fails configure without it; the libtool scripts install whether or not the library did"
[ -s "$DESTDIR/usr/include/ltdl.h" ] || \
	die "ltdl.h is missing or empty; libcanberra's configure checks the header before the library, so a missing header fails identically to a missing library"
[ -s "$DESTDIR/usr/bin/libtool" ] || die "the libtool script is missing or empty"

finish_install
log "installed libtool with libltdl"
