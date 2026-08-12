#!/bin/sh
# Configure and build NSPR, with a flag that depends on the architecture.
#
# WHY THIS IS NOT _scripts/build.sh: --enable-64bit is passed on x86_64 and NOT
# on aarch64, and the shared script takes one static CONFIGURE_ARGS string.
#
# THE ASYMMETRY IS REAL AND NOT A BLFS TYPO. NSPR's configure defaults to a
# 32-bit build on x86, so x86_64 must ask for 64-bit explicitly. aarch64 has no
# 32-bit variant in this configure, so the flag is neither needed nor accepted
# as meaningful there. BLFS writes it as
#
#     $([ $(uname -m) = x86_64 ] && echo --enable-64bit)
#
# and this reproduces that condition rather than hardcoding either answer --
# which matters because this tree builds BOTH architectures and a recipe that
# assumed one would be silently wrong on the other. An arch conditional is a
# place where "verified" means "verified on the arch I ran".
#
# --with-mozilla and --with-pthreads are BLFS's, and both are required by NSS:
# --with-mozilla builds the Mozilla-specific pieces NSS expects, and NSPR
# without pthreads gives NSS a runtime with no working thread primitives.

. "$(dirname "$0")/../_scripts/common.sh"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

arch=$(uname -m)
bits=""
if [ "$arch" = "x86_64" ]; then
	bits="--enable-64bit"
	log "x86_64: passing --enable-64bit (configure defaults to 32-bit on x86)"
else
	log "$arch: omitting --enable-64bit, which x86 alone needs"
fi

# shellcheck disable=SC2086
"$SRC_PATH/configure" --prefix=/usr --with-mozilla --with-pthreads $bits \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
