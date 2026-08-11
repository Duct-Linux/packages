#!/bin/sh
# Stage libxshmfence, then assert the two things its pkg.env pinned -- because
# both flags select between implementations that install identically.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

[ -s "$DESTDIR/usr/lib/libxshmfence.so.1" ] \
	|| die "libxshmfence.so.1 is missing or dangling"

# xwayland looks this package up by the pkg-config name `xshmfence`, twice, and
# under -Ddri3=auto one of those lookups is required: false -- so a missing .pc
# is not a build failure, it is DRI3 silently off. See pkg.env.
[ -s "$DESTDIR/usr/lib/pkgconfig/xshmfence.pc" ] \
	|| die "xshmfence.pc was not installed; xwayland looks this up under a default that does NOT require it, so its absence would silently drop DRI3 rather than fail"

[ -s "$DESTDIR/usr/include/X11/xshmfence.h" ] \
	|| die "xshmfence.h was not installed; nothing could compile against this package"

# --enable-futex, asserted against config.h rather than against the flag.
# configure.ac 78-88 turns FUTEX into a choice of SOURCE FILES, so the pthread
# build and the futex build produce a library of the same name with the same
# soname exporting the same symbols. Nothing downstream can tell them apart and
# nothing about the installed tree records which one this is.
[ -f "$BUILD_DIR/config.h" ] \
	|| die "no config.h in the build directory; cannot verify which fence implementation was compiled"
grep -q '^#define HAVE_FUTEX 1' "$BUILD_DIR/config.h" \
	|| die "HAVE_FUTEX is not set; --enable-futex did not take effect and this is the pthread implementation, which is a different library wearing the same soname"

# The other half of the same fact, on the artefact rather than on config.h: the
# futex build sets PTHREAD=no and leaves PTHREAD_LIBS empty (configure.ac
# 84-96), so a libxshmfence that links libpthread is one that took the branch
# the flag was meant to close.
#
# A HARD FAILURE IF readelf IS MISSING rather than a skipped check, following
# accountsservice: a check that silently does nothing on the one image where it
# matters is worse than no check, and ghcr.io/duct-linux/builder has readelf.
command -v readelf >/dev/null 2>&1 \
	|| die "no readelf; cannot verify which fence implementation shipped, and this check is not optional"
if readelf -d "$DESTDIR/usr/lib/libxshmfence.so.1" 2>/dev/null | grep -q 'NEEDED.*libpthread'; then
	die "libxshmfence links libpthread; the pthread implementation was built despite --enable-futex"
fi

# NOT AN ASSERTION, AND IT CANNOT BE ONE FROM HERE: SHMDIR is a string compiled
# into the library, and the directory it names is created by duct-live at boot
# rather than by any package. Recorded so that the pairing is written down
# somewhere: if duct-live ever stops mounting /dev/shm, this library's fallback
# allocation path stops working, and nothing in either package would say so.
grep -q '^#define SHMDIR "/dev/shm"' "$BUILD_DIR/config.h" \
	|| die "SHMDIR is not /dev/shm; --with-shared-memory-dir did not take effect and the build container's directory layout was baked in instead"
log "note: SHMDIR is /dev/shm, which duct-live mounts at boot -- this package does not create it."
