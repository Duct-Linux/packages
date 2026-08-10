#!/bin/sh
# Configure and build gcc.

. "$(dirname "$0")/../_scripts/common.sh"

# Duct is merged-/usr with everything in lib. On x86_64 gcc otherwise defaults
# its 64-bit libraries to lib64 and nothing finds them.
case "$(uname -m)" in
	x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig "$SRC_PATH/gcc/config/i386/t-linux64" ;;
esac

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --without-zstd IS LOAD-BEARING AND LOOKS DECORATIVE, which is why it is
# written down. gcc 15's --with-zstd DEFAULTS TO AUTO: configure probes for
# libzstd and links it if it finds one, so on a tree with no zstd package the
# probe fails, nothing links, and the flag appears to do nothing at all. The
# moment zstd exists in the build image the probe succeeds and cc1 acquires a
# runtime dependency ON A LIBRARY NO RECIPE DECLARES.
#
# THE EDGE IS CREATED BY A CONFIGURE-TIME PROBE RATHER THAN BY ANYTHING A
# RECIPE DECLARES, SO IT IS INVISIBLE TO dep-levels.sh BY CONSTRUCTION. No build
# order can prevent it and reordering is not an alternative fix: binutils hit
# exactly this and its zstd built at the SAME LEVEL, overlapping in time.
#
# Declaring zstd instead would be worse -- gcc would depend on zstd, zstd needs
# gcc to build, and dep-levels.sh would refuse to produce a graph at all.
# --with-system-zlib above is the deliberate opposite: zlib IS declared, so its
# probe is allowed to succeed.
#
# gcc has not yet been built with zstd present anywhere -- the climb that would
# have done it died at level 3, and zstd was only published today. So this is a
# defect fixed BEFORE it was observed, on the strength of binutils having the
# identical option on the identical default. If it were left, the next climb
# would go green and the one after would fail in cc1: the change that breaks it
# would not be the change that gets blamed.
log "configuring"
"$SRC_PATH/configure" \
	--prefix=/usr \
	--disable-multilib \
	--disable-bootstrap \
	--disable-fixincludes \
	--with-system-zlib \
	--without-zstd \
	--enable-default-pie \
	--enable-default-ssp \
	--enable-languages=c,c++ \
	--disable-nls \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
