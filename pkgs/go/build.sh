#!/bin/sh
# Build the Go toolchain from source.

. "$(dirname "$0")/../_scripts/common.sh"

command -v go >/dev/null 2>&1 || \
	die "no bootstrap go -- this package builds in duct/go, not duct/builder"
[ -n "${GOROOT_BOOTSTRAP:-}" ] || die "GOROOT_BOOTSTRAP is not set"
[ -x "$GOROOT_BOOTSTRAP/bin/go" ] || die "no go at GOROOT_BOOTSTRAP=$GOROOT_BOOTSTRAP"

cd "$SRC_PATH/src"

# make.bash writes into the source tree, so GOROOT is the unpacked source, not
# the bootstrap toolchain. Setting GOROOT here would make it build against the
# imported release instead of itself.
unset GOROOT
unset GOPATH

# Reproducibility: Go stamps the toolchain with the build user and host unless
# told otherwise, and -trimpath keeps the build directory out of the binaries.
export GOFLAGS="-trimpath"
export CGO_ENABLED=1
export GOMAXPROCS=$JOBS

log "building go $(cat "$SRC_PATH/VERSION" 2>/dev/null || echo '') with $GOROOT_BOOTSTRAP"
./make.bash || die "make.bash failed"

[ -x "$SRC_PATH/bin/go" ] || die "make.bash produced no go binary"
log "built $("$SRC_PATH/bin/go" version)"
