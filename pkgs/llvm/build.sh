#!/bin/sh
# Configure and build LLVM.
#
# Its own build stage rather than the generic one: LLVM is cmake, the source
# root of the monorepo tarball is not the cmake source directory (that is
# llvm/ inside it), and the option set below is most of the recipe.

. "$(dirname "$0")/../_scripts/common.sh"

command -v cmake >/dev/null 2>&1 || die "cmake is not installed"
command -v ninja >/dev/null 2>&1 || die "ninja is not installed"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# TARGETS_TO_BUILD is the single biggest lever on how long this takes and how
# large it is. "host" is what llvmpipe needs -- it emits code for the machine it
# is running on and nothing else. AMDGPU is added because radeonsi compiles its
# shaders through LLVM too, and a Radeon in the machine that boots the ISO is
# not an exotic case.
#
# BUILD_LLVM_DYLIB with LINK_LLVM_DYLIB gives one libLLVM.so rather than a
# hundred static archives; mesa links the shared one, and without it every mesa
# driver absorbs its own copy of the optimiser.
#
# ENABLE_RTTI is not optional: mesa's C++ is built with RTTI and fails to link
# against an LLVM without it, with an error that names a vtable rather than the
# flag.
#
# LIBDIR_SUFFIX is empty for the same reason meson is told --libdir=lib: cmake
# would otherwise write to /usr/lib64, where nothing looks.
log "configuring"
cmake -G Ninja "$SRC_PATH/llvm" \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_BUILD_TYPE=Release \
	-DLLVM_LIBDIR_SUFFIX= \
	-DLLVM_ENABLE_PROJECTS= \
	-DLLVM_TARGETS_TO_BUILD="host;AMDGPU" \
	-DLLVM_BUILD_LLVM_DYLIB=ON \
	-DLLVM_LINK_LLVM_DYLIB=ON \
	-DLLVM_ENABLE_RTTI=ON \
	-DLLVM_ENABLE_FFI=ON \
	-DLLVM_ENABLE_ZLIB=ON \
	-DLLVM_ENABLE_ZSTD=OFF \
	-DLLVM_ENABLE_TERMINFO=OFF \
	-DLLVM_ENABLE_LIBXML2=OFF \
	-DLLVM_ENABLE_LIBEDIT=OFF \
	-DLLVM_ENABLE_BINDINGS=OFF \
	-DLLVM_INCLUDE_TESTS=OFF \
	-DLLVM_INCLUDE_EXAMPLES=OFF \
	-DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_DOCS=OFF \
	-DLLVM_INSTALL_UTILS=OFF \
	|| die "cmake failed"

log "building with -j$JOBS"
ninja -j"$JOBS" || die "ninja failed"
