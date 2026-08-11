#!/bin/sh
# Build librsvg: meson drives cargo, so this needs both.
#
# It cannot use _scripts/build-meson.sh unchanged for one reason -- the same one
# uutils-coreutils ships its own build.sh for. This is a NATIVE build, rustc's
# host triple is the target, but cargo still guesses a cross-linker name
# (aarch64-linux-gnu-gcc) that does not exist in this image. Naming the linker
# explicitly is also what guarantees the result is linked by the same compiler,
# against the same glibc, as every other Duct package.
#
# Everything else follows build-meson.sh deliberately rather than by accident,
# and the flags are repeated here rather than sourced because that script is
# shared by two thirds of the tree and must not grow a Rust branch:
#
#   --libdir=lib      meson picks lib64 whenever /usr/lib64 exists as a real
#                     directory, and duct-filesystem creates one. Libraries and
#                     .pc files landing there are found by neither the loader
#                     nor pkgconf.
#   --buildtype=release
#   --wrap-mode=nodownload
#                     librsvg ships no subprojects/ at all, so this changes
#                     nothing today. Kept so that a future tarball which starts
#                     shipping a wrap cannot turn a missing dependency into a
#                     silently vendored copy. Note this does NOT restrict cargo:
#                     the crates.io fetch is a separate mechanism, and it is
#                     expected here -- see pkg.env.

. "$(dirname "$0")/../_scripts/common.sh"

if [ -z "${SRC_DIR:-}" ]; then
	log "no source tree; nothing to build"
	exit 0
fi

command -v cargo >/dev/null 2>&1 || \
	die "no cargo -- this package builds in duct/rust, not duct/chroot"
command -v cargo-cbuild >/dev/null 2>&1 || \
	die "no cargo-cbuild -- librsvg's meson.build:27 requires cargo-c >= 0.10.0 and fails configure without it; it comes from the build image, not from a Duct package"
command -v meson >/dev/null 2>&1 || die "meson is not installed"
command -v ninja >/dev/null 2>&1 || die "ninja is not installed"

# Point cargo at Duct's own gcc, for the reason in the header.
host=$(rustc -vV | sed -n 's/^host: //p')
[ -n "$host" ] || die "cannot determine rustc host triple"
linker_var=CARGO_TARGET_$(echo "$host" | tr 'a-z-' 'A-Z_')_LINKER
export "$linker_var=gcc"
log "linking with gcc for $host"

# meson refuses to reconfigure a directory it did not create.
rm -rf "$BUILD_DIR"

log "configuring"
# shellcheck disable=SC2086
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	${MESON_ARGS:-} \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
