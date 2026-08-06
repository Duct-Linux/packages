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

log "configuring"
"$SRC_PATH/configure" \
	--prefix=/usr \
	--disable-multilib \
	--disable-bootstrap \
	--disable-fixincludes \
	--with-system-zlib \
	--enable-default-pie \
	--enable-default-ssp \
	--enable-languages=c,c++ \
	--disable-nls \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
