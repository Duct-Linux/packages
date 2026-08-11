#!/bin/sh
# Configure and build ICU4C.
#
# Its own build stage for two reasons, both of them facts about the tarball
# rather than choices:
#
#   * it unpacks to a bare `icu/` with no version in the name, and the configure
#     script is in `icu/source/`, not at the root the generic build.sh looks in;
#   * the build is IN-TREE. That is what BLFS does and what upstream's own
#     instructions do, and ICU's data build resolves a number of paths relative
#     to the working directory rather than to $srcdir. An out-of-tree build is
#     nominally supported and is not worth being the first thing here to find
#     out otherwise, on a package whose failure mode is a library that exists
#     with no locale data in it.
#
# Because the build is in-tree, install.sh has to look in the same place. Both
# derive it the same way rather than either one guessing.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_DIR:-}" ] || die "no source tree to build"

ICU_BUILD=$SRC_PATH/source
[ -x "$ICU_BUILD/configure" ] || die "no configure in $ICU_BUILD -- the tarball layout is not what this recipe expects"

cd "$ICU_BUILD"

log "configuring"
# shellcheck disable=SC2086
./configure --prefix=/usr --libdir=/usr/lib ${CONFIGURE_ARGS:-} || die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
