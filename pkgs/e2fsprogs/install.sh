#!/bin/sh
# Stage e2fsprogs, then check the two things that can go wrong silently.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"

# Plain 'install', and NOT 'install-libs'.
#
# WHAT EACH TARGET STAGES, MEASURED FROM A BUILD RATHER THAN READ OFF THE
# MAKEFILE. The comment that stood here until now said that install-libs was
# what added the static archives and the development headers, and that plain
# install added neither. BOTH HALVES WERE WRONG. It was written by reading the
# top-level install target, seeing it depend on install-shlibs-libs-recursive
# rather than install-libs-recursive, and concluding what the lib
# subdirectories must therefore not do. The lib subdirectories have their own
# install:: rules -- lib/et/Makefile.in carries one -- and those run whichever
# top-level target asked for them.
#
# Plain install stages ALL of: the programs, the shared libraries, the
# development headers under /usr/include/{e2p,et,ext2fs,ss}, the four
# pkg-config files, and the three static archives.
#
# The error survived a full day because this recipe had never once got past
# configure in CI -- util-linux was missing from the published repository -- so
# no tree had ever existed to look at, and a claim about the outcome was made
# from the mechanism alone.
#
# Consequences, both load-bearing for other packages:
#   - THE HEADERS SHIP. ostree compiles against libe2p and needs nothing
#     further from this recipe.
#   - The archives are removed below. That is a decision about static linking
#     and NOT an answer to whether this should become a -dev package, which is
#     deliberately still open.
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

# ---------------------------------------------------------------------------
# THE STATIC ARCHIVES: REMOVED BY NAME, AND THEN THE ABSENCE IS MEASURED
#
# libcom_err.a, libe2p.a and libext2fs.a are staged by plain install and are
# deleted here. Nothing in Duct links statically, LFS deletes them too, and
# they would otherwise go into every installed system. One line to reverse if
# something ever does need static linking.
#
# BY NAME, and not `rm usr/lib/*.a`, so the guard below is not measuring its
# own cleanup. A blanket remove followed by "assert no archives remain" is an
# assertion that cannot fail -- it would report on the rm rather than on the
# package, which is the shape of guard this recipe exists to avoid.
#
# Each one must be PRESENT before it is removed. A silent `rm -f` of something
# upstream no longer produces would hide exactly the change worth knowing
# about, and the version is pinned, so this can only fire when a human is
# already bumping it.
#
# THERE ARE FOUR, AND THE GUARD BELOW IS WHY THIS LIST IS RIGHT. The first
# version of this loop named three. libss.a was missing from it, the guard
# caught it on both architectures, and the reason it was missing is worth
# keeping: the list was built by grepping a build log for the staged archives,
# and lib/ss logs its install with the ABSOLUTE staging path
#
#     INSTALL_DATA /tmp/pkgs/e2fsprogs/work/install/usr/lib/libss.a
#
# where the other three log a /usr/lib/-relative one. A pattern anchored on
# /usr/lib/ matched three of four and looked like a complete enumeration.
#
# So do not rebuild this list by grepping. If it needs to change, let the guard
# below name what is missing -- it reads the staging tree, which cannot format
# itself inconsistently.
#
# libsupport.a is built (GEN_LIB) and never staged, which is why it is absent
# here and why the guard does not report it either.
# ---------------------------------------------------------------------------
for a in libcom_err.a libe2p.a libext2fs.a libss.a; do
	[ -e "$DESTDIR/usr/lib/$a" ] ||
		die "$a was not staged, so this recipe is deleting something that is no
       longer there. Upstream changed what the install target produces -- find
       out what else moved before trimming this loop."
	rm -f "$DESTDIR/usr/lib/$a" || die "could not remove $a from the staging root"
done

# Any OTHER archive is an upstream change nobody has made a decision about.
# This is the original guard, kept, and it now runs against a tree the three
# known archives have already been taken out of -- so it can only report
# something new.
for a in "$DESTDIR"/usr/lib/*.a; do
	[ -e "$a" ] || continue
	die "static archive $(basename "$a") was staged; nothing here links it, and it
       is not one of the four this recipe knows about. Decide whether it ships
       before this package does -- and add it to the loop above rather than
       widening this one, so the next new archive is still caught."
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
