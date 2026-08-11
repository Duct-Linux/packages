#!/bin/sh
# Configure and build SpiderMonkey.
#
# Its own build stage because the configure script is not at the root of the
# tarball -- it is js/src/configure, five directories of browser away from where
# the generic build.sh would look.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_DIR:-}" ] || die "no source tree to build"

configure=$SRC_PATH/js/src/configure
[ -x "$configure" ] || die "no js/src/configure in $SRC_PATH -- this is the full Firefox tarball and only js/src is built from it"

command -v cargo >/dev/null 2>&1 || die "no cargo; SpiderMonkey is part Rust and will not configure without it"
command -v cbindgen >/dev/null 2>&1 || \
	die "no cbindgen on PATH. build/moz.configure/bindgen.configure raises a FatalCheckError for this, and the message it prints tells you to run 'mach bootstrap' or 'cargo install cbindgen' -- neither of which is what this distribution wants. Install the cbindgen package instead."

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# /dev/shm has to be a mount point or Python's multiprocessing cannot create a
# semaphore, and configure dies in a traceback through
# multiprocessing/synchronize.py that says nothing about /dev/shm. Docker
# provides one; assert it rather than let the traceback be the diagnosis.
[ -d /dev/shm ] || die "/dev/shm is missing; SpiderMonkey's configure needs it for Python multiprocessing and fails with an unrelated-looking traceback without it"

# The flags are BLFS 12.4's, which is the combination this gjs is known to work
# against, plus two made explicit:
#
#   --disable-debug --enable-optimize
#     Both are already the defaults. They are written down because gjs does not
#     merely prefer a non-debug SpiderMonkey, it REFUSES a debug one: its
#     meson.build compiles a probe for JS_DEBUG and, on a release build, calls
#     error() with "You are trying to make a release build with a debug-enabled
#     copy of SpiderMonkey". A default that changes silently would take gjs out
#     with it, so it is pinned here rather than inherited.
#
#   --disable-jemalloc
#     jemalloc is for the browser. An embedder that allocates in jemalloc and
#     frees on glibc's allocator crashes, which is the failure this avoids.
#
#   --enable-readline    the js140 shell's line editing; see pkgs/readline.
#   --with-intl-api      the Intl object. NOT optional here: it is what gjs
#                        needs, and it is what makes --with-system-icu matter.
#   --with-system-icu    one ICU in the process, not two. See pkgs/icu.
#   --with-system-zlib   likewise for zlib.
#   --disable-debug-symbols  they are enormous and nothing here ships them.
#
# NOT PASSED, THOUGH BLFS PASSES IT: --enable-rust-simd. It turns on the
# `simd-accel` feature of the vendored encoding_rs, which is written against
# core::simd -- and core::simd is unstable, so what compiles depends on the
# exact rustc. BLFS 12.4 pairs SpiderMonkey 140 with rustc 1.89.0; this tree
# pins 1.97.1, and in between `Mask::select` moved behind a `Select` trait that
# encoding_rs 0.8.35 does not import:
#
#   error[E0599]: no method named `select` found for struct `Mask<T, N>`
#     --> third_party/rust/encoding_rs/src/x_user_defined.rs:23:56
#     = help: trait `Select` ... is implemented but not in scope
#
# It failed on both architectures, which is what a source incompatibility looks
# like as opposed to a flaky runner. The flag is a PERFORMANCE option for text
# decoding and nothing here needs it, so it is dropped rather than papered over
# with a patch to a vendored crate that upstream will fix on its own schedule.
#
# Worth stating plainly because it is the general hazard of following a book
# whose toolchain this tree has moved past: everything else in BLFS's command
# line describes what SpiderMonkey should BE, and this one described what a
# 2025 rustc could COMPILE.
log "configuring"
"$configure" \
	--prefix=/usr \
	--libdir=/usr/lib \
	--disable-debug \
	--enable-optimize \
	--disable-debug-symbols \
	--disable-jemalloc \
	--enable-readline \
	--with-intl-api \
	--with-system-icu \
	--with-system-zlib \
	|| die "configure failed"

# Bounded by memory rather than by cores, for the same reason llvm is: the
# larger C++ translation units here are big, and this is the second-heaviest
# build in the tree. Upstream's own note is that the C++ compilation respects
# $MAKEFLAGS and defaults to -j1 while the Rust half uses every processor
# regardless -- so the make job count is the only lever available, and it is
# worth setting it from memory rather than from nproc.
jobs=$(memory_jobs 2)
log "building with -j$jobs (memory-bounded; $JOBS cores available)"
make -j"$jobs" || die "make failed"
