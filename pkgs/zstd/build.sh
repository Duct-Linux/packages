#!/bin/sh
# Build zstd, which has no configure and no meson -- just a Makefile.
#
# In-tree, because that is the only thing this Makefile supports; hwdata sets
# the same precedent for a package whose build system cannot go out of tree.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# `lib` rather than `all`. The top-level `all` builds examples, the manual,
# contrib and the zlib wrapper; `allzstd` additionally builds the test suite.
# Neither is wanted, and the zlib wrapper in particular would link the zlib this
# recipe is deliberately keeping out of the dependency graph.
log "building libzstd with -j$JOBS"
# shellcheck disable=SC2086
make -j"$JOBS" PREFIX=/usr ${ZSTD_MAKE_VARS:-} lib || die "building the library failed"

# Just the zstd binary, not programs/'s `all`, which additionally builds
# zstd-compress, zstd-decompress and zstd-small -- three cut-down variants that
# exist for size experiments and that nothing installs.
log "building the zstd command"
# shellcheck disable=SC2086
make -j"$JOBS" -C programs PREFIX=/usr ${ZSTD_MAKE_VARS:-} zstd \
	|| die "building the zstd command failed"
