#!/bin/sh
# Configure and build the kernel.
#
# The configuration is assembled in three layers: the architecture's own
# defconfig, then config/common.config, then config/<arch>.config. merge_config.sh
# is the kernel's own tool for exactly this, and using it rather than a shipped
# .config means a version bump does not silently drop every symbol upstream
# renamed -- olddefconfig resolves the new tree and merge_config.sh reports any
# request it could not honour.

. "$(dirname "$0")/../_scripts/common.sh"

# The kernel's name for the architecture is not uname's name for it, and it is
# not the same as the tuple either. Guessing wrong here does not fail loudly:
# it builds a kernel for the host's default architecture and installs it under
# a plausible-looking name.
machine=$(uname -m)
#
# arm64 takes the uncompressed Image, not Image.gz, and that is not a
# preference. GRUB's arm64 loader identifies a kernel by the "ARM\x64" magic in
# the Linux image header and boots it through the EFI stub, which is a PE
# header on the same file; a gzipped image has neither, and GRUB rejects it
# with "invalid arm64 image". x86 is the other way round -- bzImage carries its
# own decompressor and is what every loader expects.
case "$machine" in
	x86_64)  karch=x86;   image_path=arch/x86/boot/bzImage;   dtbs=no  ;;
	aarch64) karch=arm64; image_path=arch/arm64/boot/Image;   dtbs=yes ;;
	*) die "no kernel configuration for $machine; add config/$machine.config" ;;
esac

fragments="$RECIPE_DIR/config/common.config $RECIPE_DIR/config/$machine.config"
for f in $fragments; do
	[ -f "$f" ] || die "missing config fragment $f"
done

# Recorded for install.sh, which has to know where the image is and whether
# there are device trees without repeating this case statement.
mkdir -p "$BUILD_DIR"
{
	echo "KARCH=$karch"
	echo "IMAGE_PATH=$image_path"
	echo "DTBS=$dtbs"
} >"$BUILD_DIR/duct-arch.env"

cd "$SRC_PATH"

log "generating defconfig for $karch"
make O="$BUILD_DIR" ARCH="$karch" defconfig >/dev/null || die "defconfig failed"

# merge_config.sh is given a copy of the base rather than the live .config: it
# writes its result to the same directory, and handing it a file it is also
# about to overwrite is a race nobody should have to reason about.
cp "$BUILD_DIR/.config" "$BUILD_DIR/defconfig.base"

log "merging config/common.config and config/$machine.config"
# -m merges without invoking make, so the merge and the resolution are separate
# steps and a merge warning is not buried in a rebuild. -O puts the result
# where the out-of-tree build expects it.
# shellcheck disable=SC2086
ARCH="$karch" ./scripts/kconfig/merge_config.sh -m -O "$BUILD_DIR" \
	"$BUILD_DIR/defconfig.base" $fragments || die "merging the config fragments failed"

log "resolving the merged configuration"
make O="$BUILD_DIR" ARCH="$karch" olddefconfig >/dev/null || die "olddefconfig failed"

# merge_config.sh reports a symbol it could not set and carries on, which is
# right for a symbol the architecture does not have -- but not for these. A
# kernel without squashfs or overlayfs cannot mount a live root at all, and the
# failure would appear as an unbootable ISO twenty minutes later rather than
# here.
for required in \
	CONFIG_SQUASHFS=y CONFIG_OVERLAY_FS=y CONFIG_BLK_DEV_LOOP=y \
	CONFIG_ISO9660_FS=y CONFIG_VFAT_FS=y CONFIG_BLK_DEV_INITRD=y \
	CONFIG_DEVTMPFS=y CONFIG_EFI_STUB=y CONFIG_MODULES=y
do
	grep -q "^$required\$" "$BUILD_DIR/.config" || \
		die "$required is not in the resolved configuration; the ISO would not boot"
done

release=$(make O="$BUILD_DIR" ARCH="$karch" -s kernelrelease) || die "cannot determine the kernel release"
log "building $release with -j$JOBS"

# `all` covers the image, vmlinux and the modules. Naming them separately would
# invite one of them to be forgotten.
make O="$BUILD_DIR" ARCH="$karch" -j"$JOBS" all || die "make failed"

[ -f "$BUILD_DIR/$image_path" ] || die "the build produced no $image_path"
