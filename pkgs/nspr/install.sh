#!/bin/sh
# Stage NSPR and prove the three libraries and the header path NSS needs.
#
# WHY THE HEADER PATH IS ASSERTED AND NOT JUST THE LIBRARIES. prepare.sh
# comments out RELEASE in pr/src/misc/Makefile.in specifically so the headers
# land in /usr/include/nspr rather than a release-numbered directory -- because
# NSS's build is told NSPR_INCLUDE_DIR=/usr/include/nspr literally. If that sed
# ever stops matching, NSPR still builds, still installs, and still ships every
# library; the only symptom is NSS failing to find prtypes.h one package later,
# naming NSS rather than naming this.
#
# THREE LIBRARIES, NOT ONE. NSPR ships libnspr4, libplc4 and libplds4, and NSS
# links all three (its build passes -lplc4 -lplds4 -lnspr4). Asserting libnspr4
# alone would pass on a build that shipped the core and not the companions.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

for lib in libnspr4 libplc4 libplds4; do
	[ -s "$DESTDIR/usr/lib/$lib.so" ] || \
		die "$lib.so is missing or empty; NSS links all three of NSPR's libraries, not just libnspr4"
done

[ -s "$DESTDIR/usr/include/nspr/prtypes.h" ] || \
	die "prtypes.h is not at /usr/include/nspr. prepare.sh disables NSPR's RELEASE variable precisely so the headers land there, because NSS's build is given NSPR_INCLUDE_DIR=/usr/include/nspr literally -- if that edit stopped matching, this package still builds and installs and NSS fails one package later under its own name"

[ -s "$DESTDIR/usr/lib/pkgconfig/nspr.pc" ] || \
	die "nspr.pc is missing or empty; evolution-data-server's FindSMIME.cmake searches for nspr by pkg-config name before falling back to a manual header hunt"

# The static archives should be gone: prepare.sh edits config/rules.mk to stop
# installing them. Asserting their ABSENCE is what proves that edit still bites
# -- the .so set above would be identical either way.
if [ -e "$DESTDIR/usr/lib/libnspr4.a" ]; then
	die "libnspr4.a was installed despite prepare.sh removing \$(LIBRARY) from config/rules.mk; that edit no longer matches and the package is carrying static archives nothing links"
fi

finish_install
log "installed NSPR with its three libraries and unversioned headers"
