#!/bin/sh
# Configure and build glibc.
#
# Out of tree because glibc refuses an in-tree build outright.

. "$(dirname "$0")/../_scripts/common.sh"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# glibc's own build system decides where sbin binaries go and offers no
# configure switch for it; this is the documented way to move them.
echo "rootsbindir=/usr/sbin" > configparms

# libc_cv_slibdir puts the runtime libraries in /usr/lib rather than /lib,
# which is what merged-/usr means -- duct-filesystem makes /lib a symlink to it.
log "configuring"
"$SRC_PATH/configure" \
	--prefix=/usr \
	--disable-werror \
	--disable-nscd \
	--enable-kernel=5.4 \
	--enable-stack-protector=strong \
	--with-headers=/usr/include \
	libc_cv_slibdir=/usr/lib \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
