#!/bin/sh
# Stage the kernel, its modules and its device trees.

. "$(dirname "$0")/../_scripts/common.sh"

[ -f "$BUILD_DIR/duct-arch.env" ] || die "build.sh did not run"
# shellcheck disable=SC1091
. "$BUILD_DIR/duct-arch.env"

cd "$SRC_PATH"

release=$(make O="$BUILD_DIR" ARCH="$KARCH" -s kernelrelease) || die "cannot determine the kernel release"
log "installing $release"

install -d -m 0755 "$DESTDIR/boot"
install -m 0644 "$BUILD_DIR/$IMAGE_PATH" "$DESTDIR/boot/vmlinuz-$release"
install -m 0644 "$BUILD_DIR/System.map" "$DESTDIR/boot/System.map-$release"
install -m 0644 "$BUILD_DIR/.config" "$DESTDIR/boot/config-$release"

# A stable name, so a bootloader configuration does not have to be regenerated
# for a version bump. The link is relative: an absolute target would resolve
# against the build host while the package is being staged.
ln -sfn "vmlinuz-$release" "$DESTDIR/boot/vmlinuz"

# INSTALL_MOD_PATH is $DESTDIR/usr, not $DESTDIR: the kernel appends
# /lib/modules to it, and Duct is merged-/usr, so modules belong at
# /usr/lib/modules. Staging them at $DESTDIR/lib/modules instead would make
# this package claim /lib -- which duct-filesystem owns, as a symlink -- and
# tape rejects two packages owning one path outright.
#
# DEPMOD=true suppresses the kernel's own depmod call, which would run
# `depmod -b $DESTDIR/usr`. kmod is configured with /usr/lib/modules as its
# module directory, so that prefix would send it looking in
# $DESTDIR/usr/usr/lib/modules, find nothing, and write an empty modules.dep
# without complaining. depmod is run below with the prefix it actually wants.
#
# INSTALL_MOD_STRIP=1 is the difference between a 200 MB modules tree and a
# 60 MB one, on an image that has to fit on a USB stick.
log "installing modules"
make O="$BUILD_DIR" ARCH="$KARCH" \
	INSTALL_MOD_PATH="$DESTDIR/usr" \
	INSTALL_MOD_STRIP=1 \
	DEPMOD=true \
	modules_install >/dev/null || die "modules_install failed"

moddir=$DESTDIR/usr/lib/modules/$release
[ -d "$moddir" ] || die "modules were not installed into $moddir"

# Both point into the build tree, which does not exist on the installed system.
# Packaging a dangling symlink is not fatal, but it is a lie -- and anything
# that follows /usr/lib/modules/<release>/build to compile a module would
# rather be told there is nothing there.
rm -f "$moddir/build" "$moddir/source"

log "running depmod"
depmod -b "$DESTDIR" -F "$BUILD_DIR/System.map" -a "$release" || die "depmod failed"
[ -s "$moddir/modules.dep" ] || die "depmod produced an empty modules.dep"

if [ "$DTBS" = yes ]; then
	log "installing device trees"
	make O="$BUILD_DIR" ARCH="$KARCH" \
		INSTALL_DTBS_PATH="$DESTDIR/boot/dtbs/$release" \
		dtbs_install >/dev/null || die "dtbs_install failed"
fi

# Deliberately not strip_payload: it strips everything under usr/bin, usr/sbin
# and usr/libexec, and this package installs nothing there. The modules were
# stripped by INSTALL_MOD_STRIP during modules_install, and the kernel image
# must not be touched at all -- `strip` on a bzImage produces a file that is
# still a valid ELF and no longer a bootable kernel.
log "installed $(find "$moddir" -name '*.ko*' | wc -l) modules"
