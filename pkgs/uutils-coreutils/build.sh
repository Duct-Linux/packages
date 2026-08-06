#!/bin/sh
# Build the uutils multicall binary.
#
# uutils ships a Makefile over cargo that knows how to produce the multicall
# layout and the applet symlinks, which is a great deal less fragile than
# driving cargo directly and reproducing that layout by hand.

. "$(dirname "$0")/../_scripts/common.sh"

command -v cargo >/dev/null 2>&1 || \
	die "no cargo -- this package builds in duct/rust, not duct/chroot"

cd "$SRC_PATH"

# Point cargo at Duct's own gcc.
#
# This is a native build -- rustc's host triple is the target -- but cargo still
# guesses a cross-linker name (aarch64-linux-gnu-gcc) that does not exist here.
# Naming the linker explicitly is also what guarantees the result is linked by
# the same compiler, against the same glibc, as every other Duct package.
host=$(rustc -vV | sed -n 's/^host: //p')
[ -n "$host" ] || die "cannot determine rustc host triple"
linker_var=CARGO_TARGET_$(echo "$host" | tr 'a-z-' 'A-Z_')_LINKER
export "$linker_var=gcc"
log "linking with gcc for $host"

# Crates come from crates.io and are not vendored upstream. Cargo.lock pins each
# one to an exact version and sha256, so what arrives is fixed even though the
# fetch itself is the one network access in the whole pipeline.
log "building with cargo"
make PROFILE=release MULTICALL=y -j"$JOBS" || die "build failed"
