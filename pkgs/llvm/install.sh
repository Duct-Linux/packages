#!/bin/sh
# Stage LLVM.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# The static archives are what make an LLVM package enormous, and nothing here
# links them: mesa uses libLLVM.so, which is what BUILD_LLVM_DYLIB produced.
find "$DESTDIR/usr/lib" -name 'libLLVM*.a' -type f -delete 2>/dev/null || true
find "$DESTDIR/usr/lib" -name 'libclang*.a' -type f -delete 2>/dev/null || true

[ -x "$DESTDIR/usr/bin/llvm-config" ] || die "llvm-config was not installed"
[ -n "$(find "$DESTDIR/usr/lib" -name 'libLLVM*.so*' -print -quit)" ] \
	|| die "no shared libLLVM was produced; mesa cannot link against this"

finish_install
log "installed llvm"
