#!/bin/sh
# Stage e2fsprogs, then check the two things that can go wrong silently.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# Plain `install`, and NOT `install-libs`.
#
# An earlier draft of this recipe ran both, on the assumption that the default
# target stages only the programs. It does not: Makefile.in:74 shows `install`
# already depends on install-shlibs-libs-recursive, so the shared libraries
# e2fsck links against are staged by it. `install-libs` additionally stages the
# static archives and the development headers, which nothing here uses and
# which would go into every installed system.
#
# The assertion below checks that the shared libraries really are present,
# rather than trusting either reading of the Makefile.
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# ---------------------------------------------------------------------------
# 1. THE PATHS THAT MUST NOT BE HERE
#
# This is the assertion that guards the three disables in pkg.env, and it is
# worth more than they are: the flags state an intention, this measures the
# result. --disable-libuuid and --disable-libblkid only build private copies
# WHEN THE SYSTEM ONES ARE ABSENT AT CONFIGURE TIME, so a recipe that lost one
# of those flags would install perfectly in an image where util-linux happened
# to be present and conflict in one where it was not. That is a defect that
# depends on the build environment, which is exactly the kind CI catches long
# after the change that caused it.
#
# Checked AFTER finish_install, so it sees the tree that will actually be
# packaged rather than an intermediate one.
#
# Each of these is owned by util-linux, and tape treats two packages claiming
# one path as a hard install error with no override.
# ---------------------------------------------------------------------------
for p in usr/sbin/fsck usr/sbin/blkid usr/bin/uuidgen usr/sbin/uuidd \
         usr/lib/libblkid.so usr/lib/libuuid.so; do
	if [ -e "$DESTDIR/$p" ]; then
		die "$p is in the staging root; util-linux owns it and tape would refuse
       to install this package. A --disable-* flag in pkg.env has been lost or
       stopped working -- see the comment there, none of them are decoration."
	fi
done

# The converse: the binaries this package exists for.
for p in usr/sbin/mke2fs usr/sbin/e2fsck usr/sbin/tune2fs usr/sbin/resize2fs; do
	[ -x "$DESTDIR/$p" ] || die "$p was not installed"
done

# The shared libraries the programs are linked against. This is what the
# dropped `install-libs` was wrongly believed to be needed for, so it is the
# claim worth measuring rather than reasoning about a second time.
for l in libext2fs libe2p libcom_err libss; do
	# A glob expansion rather than `ls <glob> >/dev/null 2>&1`.
	#
	# The ls form works here -- this runs under a non-interactive sh, where
	# aliases are not loaded -- but it is the shape of a defect that bit two
	# people on this project today: `ls` aliased to long format turns a path
	# into an "ls -l" line, and the 2>&1 that keeps the check tidy eats the
	# error that would have named it. SILENCING STDERR TO KEEP OUTPUT TIDY IS
	# HOW A BROKEN COMMAND BECOMES AN EMPTY RESULT.
	#
	# This form calls nothing, hides nothing, and cannot be affected by the
	# environment: an unmatched glob stays literal, so $1 is a path that does
	# not exist and -e is false.
	set -- "$DESTDIR"/usr/lib/$l.so*
	[ -e "$1" ] || die "$l shared library was not staged; e2fsck and mke2fs would not start"
done

# No static archives: nothing links them and they would ship in every installed
# system. If a future upstream starts installing them by default, this says so
# rather than letting the package quietly grow.
for a in "$DESTDIR"/usr/lib/*.a; do
	[ -e "$a" ] || continue
	die "static archive $(basename "$a") was staged; nothing here links it"
done

# mke2fs.conf decides what features a filesystem gets when no -O is passed, and
# the installer passes none. Without it mke2fs falls back to compiled-in
# defaults that differ from every other distribution's ext4.
[ -f "$DESTDIR/etc/mke2fs.conf" ] || die "mke2fs.conf was not installed"

# ---------------------------------------------------------------------------
# 2. THAT mke2fs ACTUALLY MAKES A FILESYSTEM
#
# Verifying the artefact rather than the command. A zero exit from an mkfs is
# not evidence that a filesystem exists -- this family of tools is prone to
# warning about something it dislikes and carrying on -- so this reads the
# ext2/3/4 superblock magic (0xEF53 at byte 1080) out of the result.
#
# od rather than blkid: blkid belongs to util-linux, which is not necessarily
# in the builder image, and rather than dumpe2fs because asking e2fsprogs
# whether e2fsprogs produced a filesystem is a weaker question than reading the
# bytes.
# ---------------------------------------------------------------------------
img=$BUILD_DIR/.mkfs-check.img
rm -f "$img"

# No cross-build escape hatch, deliberately.
#
# An earlier version skipped this check when TAPE_TARGET's architecture did not
# match `uname -m`. Two things were wrong with it. TAPE_TARGET is always set --
# tape-builder defaults it to arch.Current()+"-linux-gnu" (builder/cmd/build.go)
# and exports it (builder/utils/exec.go:23) -- so the guard was reachable, but
# the comparison was not reliable: tape names 32-bit ARM `armv7h` while uname
# reports `armv7l`, so a NATIVE armv7 build would have taken the cross branch
# and skipped the check without failing. A guard that silently skips the only
# functional test in the recipe, on one architecture, is worse than no guard.
#
# So a build that cannot run what it produced fails here and says so. Nothing
# cross-compiles in this tree today, and if that changes, a loud failure naming
# the reason is the right thing to meet.
LD_LIBRARY_PATH="$DESTDIR/usr/lib" "$DESTDIR/usr/sbin/mke2fs" -V >/dev/null 2>&1 ||
	die "the mke2fs that was just built cannot be executed on this machine.
       If this is a cross build, the filesystem check below cannot run and this
       recipe needs a decision rather than a silent skip."

truncate -s 16M "$img" 2>/dev/null || dd if=/dev/zero of="$img" bs=1M count=16 >/dev/null 2>&1 ||
	die "could not create a scratch image for the filesystem check"

LD_LIBRARY_PATH="$DESTDIR/usr/lib" "$DESTDIR/usr/sbin/mke2fs" -q -F -t ext4 -L duct-check "$img" ||
	die "mke2fs failed on a scratch image"

# Byte 1080 and 1081, little-endian 0x53 0xEF.
magic=$(od -An -tx1 -j 1080 -N 2 "$img" 2>/dev/null | tr -d ' \n')
rm -f "$img"

[ "$magic" = "53ef" ] ||
	die "mke2fs exited 0 but the result has no ext4 superblock magic (read '$magic',
       expected '53ef'). The command succeeded and produced nothing usable."

log "installed e2fsprogs; mke2fs produces a valid ext4 superblock"
