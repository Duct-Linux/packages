#!/bin/sh
# Configure and build mesa.
#
# Its own build stage because the gallium driver list is a property of the
# architecture, and a single MESON_ARGS string in pkg.env cannot express that.
# Building a driver for hardware the architecture does not have is not merely
# wasted time -- several of them do not compile at all off their own platform.

. "$(dirname "$0")/../_scripts/common.sh"

command -v meson >/dev/null 2>&1 || die "meson is not installed"

# Read from the compiler rather than from uname: uname reports the machine the
# build is running on, which is the wrong answer the moment anything here is
# cross-compiled.
arch=$(${CC:-gcc} -dumpmachine | cut -d- -f1)

# llvmpipe and softpipe are in every list. They are the software path, and on a
# live ISO the software path is not a fallback for exotic cases -- it is what
# runs whenever the machine's own driver did not load, which is most of the
# first boot on unfamiliar hardware. virgl is there for the same reason from the
# other direction: an ISO is usually tried in a virtual machine first.
case "$arch" in
	x86_64|i?86)
		drivers=llvmpipe,softpipe,virgl,iris,crocus,radeonsi,r300,r600,nouveau,svga
		;;
	aarch64|arm*)
		drivers=llvmpipe,softpipe,virgl,panfrost,lima,v3d,vc4,freedreno,etnaviv
		;;
	*)
		# An architecture nobody has tried yet still deserves a working desktop,
		# and the software rasterisers build everywhere.
		log "no driver list for $arch; building the software rasterisers only"
		drivers=llvmpipe,softpipe
		;;
esac

log "gallium drivers for $arch: $drivers"

rm -rf "$BUILD_DIR"

# platforms=wayland with glx disabled is the Wayland-first decision made
# concrete. Nothing here runs an X server, so GLX would be an interface with no
# implementation behind it; an X client under Xwayland gets GL through EGL.
#
# vulkan-drivers is deliberately empty. The Vulkan drivers worth having on this
# hardware are NVK and ANV, and NVK is written in Rust -- which would make mesa
# the second package in the distribution needing a Rust toolchain in its build
# image. GL is what GNOME renders with; Vulkan can follow.
#
# rusticl is off for the same reason, and video-codecs is empty because the
# accelerated codecs carry patent conditions a distribution should opt into
# deliberately rather than inherit from a default.
meson setup "$BUILD_DIR" "$SRC_PATH" \
	--prefix=/usr \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nodownload \
	-Dplatforms=wayland \
	-Dgallium-drivers="$drivers" \
	-Dvulkan-drivers= \
	-Dglx=disabled \
	-Degl=enabled \
	-Dgbm=enabled \
	-Dopengl=true \
	-Dgles1=disabled \
	-Dgles2=enabled \
	-Dllvm=enabled \
	-Dshared-llvm=enabled \
	-Dgallium-rusticl=false \
	-Dvideo-codecs= \
	-Dzstd=disabled \
	-Dvalgrind=disabled \
	-Dlibunwind=disabled \
	-Dbuild-tests=false \
	|| die "meson setup failed"

log "building with -j$JOBS"
ninja -C "$BUILD_DIR" -j"$JOBS" || die "ninja failed"
