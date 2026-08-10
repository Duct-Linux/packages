#!/bin/sh
# Build rustc and cargo from source, against a locally built LLVM.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

for t in cmake ninja python3 g++; do
	command -v "$t" >/dev/null 2>&1 || die "no $t -- rust builds in duct/rust with cmake and ninja installed"
done
command -v rustc >/dev/null 2>&1 || \
	die "no bootstrap rustc -- this package builds in duct/rust, not duct/builder"

boot_rustc=$(command -v rustc)
boot_cargo=$(command -v cargo)
host=$(rustc -vV | sed -n 's/^host: //p')
[ -n "$host" ] || die "cannot determine the host triple"

# download-ci-llvm is off deliberately. It is the fast path -- it fetches a
# prebuilt LLVM from Rust's CI -- and it is exactly the thing packaging is meant
# to remove: an unpinned foreign binary landing inside a Duct package. The
# vendored llvm-project in this tarball is built instead, which is most of the
# hours this recipe takes.
#
# vendor + locked-deps: the tarball ships its own crates, so cargo resolves
# nothing from the network and cannot silently pick different versions.
cat > bootstrap.toml <<TOML
profile = "dist"
change-id = "ignore"

[llvm]
download-ci-llvm = false
ninja = true
targets = "AArch64;X86"
static-libstdcpp = false

[build]
host = ["${host}"]
target = ["${host}"]
rustc = "${boot_rustc}"
cargo = "${boot_cargo}"
python = "python3"
docs = false
extended = true
tools = ["cargo", "rustdoc"]
vendor = true
locked-deps = true
verbose = 0

[install]
prefix = "/usr"
sysconfdir = "/etc"

[rust]
channel = "stable"
codegen-tests = false
deny-warnings = false
TOML

# -j from memory, not from cores. x.py builds its own vendored LLVM before it
# builds anything Rust, so this compiles the same enormous C++ translation
# units the llvm package does and fails the same way: at -j$(nproc) on a 7.7 GB
# machine it was OOM-killed on SLPVectorizer.cpp, one of LLVM's hungriest
# files, at object 1551 of 2920 -- hours in, with a message naming neither
# memory nor the job count.
#
# This is the second place that bug has appeared. It was fixed in the llvm
# package first and did not travel here, because x.py's LLVM has nothing to do
# with the llvm recipe -- different build, different image, same failure. The
# arithmetic now lives in common.sh so a third such build inherits it rather
# than rediscovering it.
jobs=$(memory_jobs 2)
log "building llvm and rustc for $host with $jobs jobs (this takes hours)"
python3 x.py build --stage 2 -j "$jobs" || die "x.py build failed"

[ -x "build/$host/stage2/bin/rustc" ] || die "no stage2 rustc was produced"
log "built $(build/"$host"/stage2/bin/rustc --version)"
