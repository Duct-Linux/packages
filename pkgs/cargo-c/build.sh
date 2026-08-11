#!/bin/sh
# Build cargo-c's four binaries.
#
# Not _scripts/build.sh: this is a Rust crate with no configure and no meson,
# built in duct/rust like uutils-coreutils. See pkg.env for why the
# vendored-openssl feature is mandatory rather than preferred.

. "$(dirname "$0")/../_scripts/common.sh"

command -v cargo >/dev/null 2>&1 || \
	die "no cargo -- this package builds in duct/rust, not duct/chroot"

cd "$SRC_PATH"

# Point cargo at Duct's own gcc, for the reason uutils-coreutils records: this
# is a native build, but cargo still guesses a cross-linker name
# (aarch64-linux-gnu-gcc) that does not exist here. Naming it explicitly is also
# what guarantees the result is linked by the same compiler, against the same
# glibc, as every other Duct package.
host=$(rustc -vV | sed -n 's/^host: //p')
[ -n "$host" ] || die "cannot determine rustc host triple"
linker_var=CARGO_TARGET_$(echo "$host" | tr 'a-z-' 'A-Z_')_LINKER
export "$linker_var=gcc"
log "linking with gcc for $host"

# Crates come from crates.io: the same deliberate exception uutils documents as
# the one network access in the pipeline. --locked is what makes the pin real.
log "building with cargo (features: ${CARGO_FEATURES:-none})"
cargo build --release --locked \
	${CARGO_FEATURES:+--features "$CARGO_FEATURES"} \
	-j "$JOBS" || die "cargo build failed"
