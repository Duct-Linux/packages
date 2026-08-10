#!/bin/sh
# Stage LLVM.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
DESTDIR="$DESTDIR" ninja install || die "ninja install failed"

# The static archives are NOT pruned, though they are most of the size.
#
# They used to be, on the reasoning that nothing links them -- mesa uses
# libLLVM.so, which is what BUILD_LLVM_DYLIB produces. That reasoning was about
# linking and the archives are not only for linking: LLVM installs 39 CMake
# files declaring imported targets that point at them, so deleting the archives
# left the package's own metadata referencing files the package does not
# contain. Anything using find_package(LLVM) then fails at configure with
#
#   The imported target "LLVMDemangle" references the file
#      "/usr/lib/libLLVMDemangle.a"
#   but this file does not exist.
#
# which is what a standalone clang does. mesa never noticed because it asks
# llvm-config rather than find_package, so the package was internally
# inconsistent for as long as its only consumer happened not to look.
#
# There is no supported way to build the dylib and install exports that do not
# reference the components; distributions ship both. So this package is large
# and correct rather than smaller and subtly broken.

[ -x "$DESTDIR/usr/bin/llvm-config" ] || die "llvm-config was not installed"
[ -n "$(find "$DESTDIR/usr/lib" -name 'libLLVM*.so*' -print -quit)" ] \
	|| die "no shared libLLVM was produced; mesa cannot link against this"

finish_install
log "installed llvm"
