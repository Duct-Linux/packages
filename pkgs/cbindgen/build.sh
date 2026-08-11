#!/bin/sh
# Build cbindgen with cargo.
#
# Modelled directly on uutils-coreutils/build.sh, which is the only other Rust
# package here -- same image, same linker override, same --locked argument, and
# the same honest note about the network.

. "$(dirname "$0")/../_scripts/common.sh"

command -v cargo >/dev/null 2>&1 || \
	die "no cargo -- this package builds in duct/rust, not duct/chroot. It is in RUST_PKGS in the Makefile and in build.yml's per-package image case; if it reached this image, one of those two is out of step with the other."

cd "$SRC_PATH"

# Point cargo at Duct's own gcc, exactly as uutils does.
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

# --locked, for the reason uutils spells out: Cargo.lock names an exact version
# and digest for every crate, and without --locked cargo may REWRITE the lock
# file when it decides it is stale, silently resolving to versions other than
# the ones this tarball's sha256 covers. With it, that is an error.
#
# And the same caveat applies unchanged: this does not make the build offline.
# The crates come from crates.io, so cbindgen joins uutils-coreutils as the
# second package in the tree that reaches the network -- BLFS says as much on
# its own cbindgen page ("An Internet connection is needed for building this
# package"). Narrowing that to zero means vendoring the crates into a tarball
# pinned like every other source, which is the same open item uutils already
# carries and is not made worse by having two callers instead of one.
log "building with cargo"
cargo build --release --locked -j"$JOBS" || die "cargo build failed"

[ -x "$SRC_PATH/target/release/cbindgen" ] || die "cargo reported success but produced no target/release/cbindgen"
