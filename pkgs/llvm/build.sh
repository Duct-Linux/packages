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

# LLVM is the one package here that is bounded by memory rather than by cores.
# A single cc1plus on its larger translation units peaks around 2 GB, and the
# link of libLLVM.so needs several more; -j$(nproc) on a machine with a
# conventional amount of RAM per core does not run slowly, it gets OOM-killed.
# That is exactly what happened here, and the message it leaves --
# "c++: fatal error: Killed signal terminated program cc1plus" -- names neither
# memory nor the job count, so it is worth not rediscovering.
#
# So the job counts come from available memory, not from the core count, and the
# smaller of the two limits wins. Link jobs are separately and much more tightly
# capped: linking is where the peak is.
mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$mem_kb" -gt 0 ]; then
	mem_gb=$((mem_kb / 1024 / 1024))
	compile_jobs=$((mem_gb / 2))
	link_jobs=$((mem_gb / 8))
	[ "$compile_jobs" -lt 1 ] && compile_jobs=1
	[ "$link_jobs" -lt 1 ] && link_jobs=1
	[ "$compile_jobs" -gt "$JOBS" ] && compile_jobs=$JOBS
	[ "$link_jobs" -gt "$JOBS" ] && link_jobs=$JOBS
	log "${mem_gb} GB visible: $compile_jobs compile jobs, $link_jobs link jobs"
else
	# No /proc/meminfo to read. Being wrong in the cautious direction costs
	# time; being wrong in the other direction costs the whole build.
	compile_jobs=1
	link_jobs=1
	log "cannot read /proc/meminfo; building single-threaded"
fi

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
	-DLLVM_PARALLEL_COMPILE_JOBS="$compile_jobs" \
	-DLLVM_PARALLEL_LINK_JOBS="$link_jobs" \
	|| die "cmake failed"

# The job pools above are what ninja actually honours for LLVM's own targets;
# -j here only bounds everything else.
log "building"
ninja -j"$compile_jobs" || die "ninja failed"
