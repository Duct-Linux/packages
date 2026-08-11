#!/bin/sh
# Configure and build startup-notification, telling configure the build type
# explicitly because its own config.guess cannot work it out.
#
# WHY THIS EXISTS. startup-notification 0.12 is from 2011 and ships
# config.guess timestamped 2011-05-11, which predates aarch64 entirely. On
# aarch64 the shared _scripts/build.sh fails at
#
#     configure: error: cannot guess build type; you must specify one
#
# and on x86_64 it succeeds, because that same ancient script does know x86_64.
# A recipe with no --build is therefore GREEN ON ONE ARCHITECTURE AND RED ON THE
# OTHER, which reads like a flaky runner or an arch-specific bug and is neither:
# it is one file in the tarball being fourteen years old.
#
# THE OBVIOUS FIX IS WRONG, and quietly so. `--build=$(gcc -dumpmachine)` yields
# aarch64-linux-gnu here, and the equally ancient config.sub REJECTS the
# two-part form:
#
#     $ sh config.sub aarch64-linux-gnu
#     Invalid configuration `aarch64-linux-gnu': machine `aarch64' not recognized
#     $ sh config.sub aarch64-unknown-linux-gnu
#     aarch64-unknown-linux-gnu
#
# So the triple is built explicitly in the THREE-part form, which both
# architectures' values pass through config.sub unchanged. Verified against the
# tarball's own config.sub rather than assumed.
#
# Replacing config.guess and config.sub with current copies would also work and
# is what many distributions do -- but this tree packages neither autoconf nor
# automake, so there is no newer copy to take them from.

. "$(dirname "$0")/../_scripts/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to build"
	exit 0
fi

build_triple="$(uname -m)-unknown-linux-gnu"
log "configuring for $build_triple (its config.guess predates aarch64)"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# shellcheck disable=SC2086
"$SRC_PATH/configure" --prefix=/usr --build="$build_triple" ${CONFIGURE_ARGS:-} \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"
