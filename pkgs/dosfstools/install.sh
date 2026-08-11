#!/bin/sh
# Stage dosfstools, then check that it can actually make a FAT32 filesystem.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# ---------------------------------------------------------------------------
# 1. THE NAME THE INSTALLER CALLS
#
# mkfs.vfat is a compat symlink, and --enable-compat-symlinks defaults to OFF.
# A recipe that lost that flag would still build, still install a working FAT
# formatter, and still pass every existence check written against the real
# program names -- and the graphical installer would then fail at the moment it
# creates the EFI system partition, on a machine with a disk already erased.
#
# So the assertion is written against the name the caller uses, not the name
# upstream ships. Checked after finish_install so it sees the tree that will be
# packaged.
# ---------------------------------------------------------------------------
for p in usr/sbin/mkfs.fat usr/sbin/fsck.fat usr/sbin/fatlabel; do
	[ -x "$DESTDIR/$p" ] || die "$p was not installed"
done

for p in usr/sbin/mkfs.vfat usr/sbin/mkdosfs usr/sbin/fsck.vfat usr/sbin/dosfsck; do
	[ -e "$DESTDIR/$p" ] || die "$p is missing -- --enable-compat-symlinks was
       not honoured. The package works and the installer does not: it calls
       mkfs.vfat, and would fail with 'not found' after erasing a disk."
done

# ---------------------------------------------------------------------------
# 2. THAT mkfs.fat MAKES A FAT32 FILESYSTEM, NOT MERELY EXITS ZERO
#
# This tool is the reason the installer's design notes carry a warning about
# mkfs.vfat: handed a geometry it dislikes it can warn and carry on rather than
# refuse, so a zero exit is not evidence that a filesystem exists. UEFI reads
# FAT32 and nothing else on a fixed disk, so "it made SOMETHING" is not good
# enough -- a FAT16 filesystem would satisfy any check that only asked whether
# mkfs succeeded, and would not boot.
#
# So this reads the filesystem type string out of the boot sector: FAT32 puts
# "FAT32   " at offset 82, and the boot signature 0x55AA sits at 510.
#
# 64 MiB because FAT32 needs at least ~33 MiB before mkfs.fat will produce it
# at the default cluster size -- and an image so small that mkfs REFUSED would
# exercise the failure path while looking like a passing test.
# ---------------------------------------------------------------------------
img=$BUILD_DIR/.mkfs-check.img
rm -f "$img"

"$DESTDIR/usr/sbin/mkfs.fat" --help >/dev/null 2>&1 ||
	die "the mkfs.fat that was just built cannot be executed on this machine"

truncate -s 64M "$img" 2>/dev/null || dd if=/dev/zero of="$img" bs=1M count=64 >/dev/null 2>&1 ||
	die "could not create a scratch image for the filesystem check"

"$DESTDIR/usr/sbin/mkfs.fat" -F 32 -n DUCTCHECK "$img" >/dev/null ||
	die "mkfs.fat failed on a scratch image"

fstype=$(od -An -c -j 82 -N 8 "$img" 2>/dev/null | tr -d ' \n')
bootsig=$(od -An -tx1 -j 510 -N 2 "$img" 2>/dev/null | tr -d ' \n')
rm -f "$img"

[ "$fstype" = "FAT32" ] ||
	die "mkfs.fat -F 32 exited 0 but the boot sector's type field reads
       '$fstype' rather than FAT32. UEFI firmware reads FAT32 and nothing else
       on a fixed disk, so this would produce an unbootable EFI partition."

[ "$bootsig" = "55aa" ] ||
	die "mkfs.fat exited 0 but the result has no 0x55AA boot signature (read '$bootsig')"

log "installed dosfstools; mkfs.fat -F 32 produces a FAT32 boot sector"
