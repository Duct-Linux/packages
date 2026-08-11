#!/bin/sh
# Stage libunistring and assert the one symbol gnutls probes for is reachable.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# In /usr/lib, checked explicitly. libunistring does not rewrite libdir the way
# nettle does -- its lib64 references are gnulib's search-path machinery -- but
# that is a reading of configure, and this is the outcome. If the reading is
# ever wrong, this fires instead of shipping a library somewhere unintended.
if [ -e "$DESTDIR/usr/lib64" ]; then
	die "libraries were installed into /usr/lib64, not /usr/lib"
fi

# The library through its soname link. Major is CURRENT - AGE from
# lib/Makefile.am (LTV_CURRENT=7, LTV_AGE=2), not the 1.3 in the package name.
[ -s "$DESTDIR/usr/lib/libunistring.so.5" ] || die "libunistring.so.5 was not installed"

[ -s "$DESTDIR/usr/include/unistr.h" ] || die "unistr.h was not installed"

# THE SYMBOL GNUTLS ACTUALLY PROBES FOR, checked in the shipped binary rather
# than assumed from the library existing.
#
# gnutls does not look for a .pc file here -- libunistring installs none -- it
# LINK-PROBES for u8_normalize in -lunistring and hard-errors if the link
# fails. So the question this package has to answer is not "is there a
# library?" but "does that symbol resolve from it?", and those come apart: a
# libunistring built without the normalisation module would install, provide a
# soname, and still fail gnutls at configure with a message about a missing
# library rather than a missing function.
if command -v readelf >/dev/null 2>&1; then
	readelf --dyn-syms -W "$DESTDIR/usr/lib/libunistring.so.5" 2>/dev/null \
		| grep -q ' u8_normalize$' \
		|| die "libunistring exports no u8_normalize; gnutls would fail to configure against it"
else
	die "no readelf; cannot verify u8_normalize, and this check is not optional"
fi

# --disable-static, asserted rather than trusted.
if [ -e "$DESTDIR/usr/lib/libunistring.a" ]; then
	die "libunistring.a was installed; --disable-static did not take"
fi

log "installed libunistring, u8_normalize exported"
