#!/bin/sh
# Configure and build GRUB for the EFI platform.
#
# Not the generic build stage, for one reason: GRUB compiles two different
# kinds of object from the same tree. The tools that run on the host are
# ordinary programs, and the modules that run under firmware are freestanding
# code with no libc, no stack protector and no PIE. GRUB works out the second
# set of flags itself, and it can only do that if the environment is not
# telling it something else.

. "$(dirname "$0")/../_scripts/common.sh"

# Inherited optimisation and hardening flags leak into the firmware objects and
# produce a bootloader that builds cleanly and hangs on the first instruction.
# GRUB's own configure notes say as much; LFS's grub page opens by unsetting
# exactly these.
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# --target is deliberately absent. GRUB derives the firmware target from the
# host tuple, so aarch64 gives arm64-efi and x86_64 gives x86_64-efi, using the
# compiler that is already here. Passing --target=aarch64 instead makes
# configure prefix every tool with "aarch64-" and hunt for a cross toolchain
# that does not exist.
log "configuring for the EFI platform"
"$SRC_PATH/configure" \
	--prefix=/usr \
	--sysconfdir=/etc \
	--with-platform=efi \
	--disable-nls \
	--disable-werror \
	--disable-efiemu \
	--disable-device-mapper \
	--disable-grub-mkfont \
	--disable-grub-mount \
	--disable-grub-themes \
	--disable-liblzma \
	--disable-libzfs \
	|| die "configure failed"

log "building with -j$JOBS"
make -j"$JOBS" || die "make failed"

# The platform directory name is what every later step spells out --
# grub-mkimage -O, the modules the ISO copies, the EFI binary's name. If
# configure picked something unexpected, finding out here beats finding out
# when the firmware declines to boot.
platform=$(sed -n 's/^GRUB_PLATFORM = //p' Makefile | head -1)
target=$(sed -n 's/^target_cpu = //p' Makefile | head -1)
[ -n "$target" ] && [ -n "$platform" ] || die "cannot determine the GRUB target from the generated Makefile"
log "built ${target}-${platform}"
