#!/bin/sh
# Record what the image build still has to do for udev.

. "$(dirname "$0")/../_scripts/common.sh"

[ -x "$DESTDIR/usr/sbin/udevd" ] || [ -x "$DESTDIR/usr/bin/udevd" ] \
	|| die "udevd was not installed"

# eudev's `make install` writes /usr/sbin/udevadm as an ABSOLUTE symlink to
# /usr/bin/udevadm, and tape-repo refuses to archive it:
#
#     [repo] [addToRepo] ERROR: tar: absolute symlink target
#                               "/usr/bin/udevadm" rejected
#
# THE REFUSAL IS CORRECT AND MUST NOT BE RELAXED. An absolute target inside a
# package does not mean "/usr/bin/udevadm on the target system" -- it means that
# path on whatever filesystem the link is resolved against, which during install
# is the BUILD HOST. It escapes DESTDIR by construction. Loosening the archiver
# to accept it would let any package point anywhere.
#
# ../bin/udevadm resolves to exactly the same file on the installed system, is
# relative to the link's own directory, and cannot escape. It is also what the
# rest of this tree already does -- duct-live writes /usr/sbin/init as
# `ln -sfn ../bin/busybox` for the same reason. eudev was the only outlier.
#
# WHY THIS NEVER FIRED BEFORE: it is not a regression. eudev has never been
# published -- zero rows in every index snapshot taken today, across five
# fetches spanning 39 to 44 packages. Publishing only runs after a SUCCESSFUL
# climb, and no climb had ever succeeded with eudev in it until tonight. The
# defect has been latent since the recipe was written and the first complete
# climb is what reached it.
if [ -L "$DESTDIR/usr/sbin/udevadm" ]; then
	log "rewriting /usr/sbin/udevadm as a relative symlink"
	ln -sfn ../bin/udevadm "$DESTDIR/usr/sbin/udevadm"
fi

# Assert it, because the whole point is that the archiver rejects one form and
# accepts the other, and a silent no-op here would publish the same failure.
case $(readlink "$DESTDIR/usr/sbin/udevadm" 2>/dev/null) in
	/*) die "/usr/sbin/udevadm is still an absolute symlink; tape-repo will reject it" ;;
esac

# /etc/udev/hwdb.bin is compiled from the hwdb.d text files by
# `udevadm hwdb --update`. It is not shipped: it is a build product of whatever
# hwdb fragments are installed *system-wide*, so a copy from this package alone
# would be wrong the moment anything else adds a fragment. tape has no install
# hooks, so the image build runs it -- the same place it runs ldconfig.
log "note: the image build must run 'udevadm hwdb --update' after installation"
