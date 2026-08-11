#!/bin/sh
# Stage nettle and assert both halves landed in the one library directory this
# system uses.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# THE OUTCOME OF --libdir=/usr/lib, CHECKED FIRST AND DELIBERATELY SO.
#
# nettle's configure guesses a distribution's library layout by looking for
# /usr/lib64 on the BUILD machine, and both of this project's builder images
# have one -- so the book's own configure line lands the libraries in
# /usr/lib64 here. That location WORKS (it is on the loader path, and gcc ships
# its sanitizer runtimes there); the objection is that it was chosen by probing
# a filesystem rather than by policy, and would change if the image changed.
# This assertion pins the layout so it cannot drift silently.
#
# ORDER MATTERS, and this was found by removing the flag and watching rather
# than by reasoning. With --libdir gone, the libnettle.so.8 check below fires
# first and reports "libnettle.so.8 was not installed in /usr/lib" -- true,
# useless, and pointing at the wrong thing: it reads as a build that failed to
# produce a library, when the library was built perfectly and put somewhere
# else. Checking for /usr/lib64 BEFORE checking /usr/lib is what turns the
# message into the diagnosis.
if [ -e "$DESTDIR/usr/lib64" ]; then
	die "libraries were installed into /usr/lib64; --libdir did not take"
fi

# Both libraries, through their soname links. The majors come from
# configure.ac (LIBNETTLE_MAJOR=8, LIBHOGWEED_MAJOR=6) rather than from the
# 3.10.2 in the package name.
[ -s "$DESTDIR/usr/lib/libnettle.so.8" ] || die "libnettle.so.8 was not installed in /usr/lib"

# HOGWEED IS THE PUBLIC-KEY HALF and is the reason gmp is a dependency. It is
# asserted separately from libnettle because --disable-public-key would drop
# this one alone, leaving a nettle that installs cleanly and cannot do RSA or
# ECDSA -- so GnuTLS would lose certificate authentication rather than fail.
[ -s "$DESTDIR/usr/lib/libhogweed.so.6" ] || die "libhogweed.so.6 was not installed; the public-key half is missing"

for pc in nettle.pc hogweed.pc; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc was not installed"
done

# --disable-static, asserted for the same reason as in libtasn1: static is the
# default here and nothing prunes .a files.
for a in libnettle.a libhogweed.a; do
	if [ -e "$DESTDIR/usr/lib/$a" ]; then
		die "$a was installed; --disable-static did not take"
	fi
done

log "installed nettle and hogweed in /usr/lib, shared only"
