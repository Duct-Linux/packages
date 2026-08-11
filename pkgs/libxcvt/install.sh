#!/bin/sh
# Stage libxcvt, then assert the library, its header and its pkg-config file.
#
# Its own install stage rather than a post-install.sh because the assertions
# want the tree that ships, which is what exists after finish_install.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# THE SONAME IS ASSERTED AS A NUMBER, not as the bare symlink. meson's
# shared_library(version: '0.1.3') produces libxcvt.so.0.1.3 with an soname of
# libxcvt.so.0, and it is the soname that every consumer records. A future
# version bump that moved it to .so.1 would install cleanly and leave every
# already-built consumer unable to start, which is precisely the class of
# failure the openssl 3-vs-4 split produced in this tree.
[ -s "$DESTDIR/usr/lib/libxcvt.so.0" ] \
	|| die "libxcvt.so.0 is missing or dangling; the soname is not what consumers were built against"

# The pkg-config file is the deliverable, not a nicety: xwayland's meson looks
# this package up by name three separate times and two of them are
# `required: true`. A library installed without its .pc is a package that
# exists and cannot be found.
[ -s "$DESTDIR/usr/lib/pkgconfig/libxcvt.pc" ] \
	|| die "libxcvt.pc was not installed into /usr/lib/pkgconfig; --libdir=lib did not take effect and nothing will find this package"

[ -s "$DESTDIR/usr/include/libxcvt/libxcvt.h" ] \
	|| die "libxcvt.h was not installed; nothing could compile against this package"

# cvt(1) is the command-line front end. Asserted because it is the only way to
# check this library's arithmetic by hand, and because Makefile.am marks it
# install: true -- if it stops being installed, that is a change worth noticing
# rather than a detail.
[ -x "$DESTDIR/usr/bin/cvt" ] && [ -s "$DESTDIR/usr/bin/cvt" ] \
	|| die "cvt was not installed as a non-empty executable"
