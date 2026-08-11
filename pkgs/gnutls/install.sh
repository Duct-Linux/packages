#!/bin/sh
# Stage GnuTLS and assert it trusts something, links the system libraries
# rather than its own bundled copies, and carries the compression it was
# configured for.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

lib=$DESTDIR/usr/lib/libgnutls.so.30

[ -s "$lib" ] || die "libgnutls.so.30 was not installed"
[ -s "$DESTDIR/usr/lib/pkgconfig/gnutls.pc" ] || die "gnutls.pc was not installed"
# NetworkManager is built -Dcrypto=gnutls against this header.
[ -s "$DESTDIR/usr/include/gnutls/gnutls.h" ] || die "gnutls.h was not installed"
# certtool is how a certificate problem gets diagnosed on a running system.
[ -x "$DESTDIR/usr/bin/certtool" ] || die "certtool was not installed"

if ! command -v readelf >/dev/null 2>&1; then
	die "no readelf; the link assertions below are the point of this file and cannot be skipped"
fi

needed=$(readelf -d "$lib" 2>/dev/null)

# THE SYSTEM libtasn1 AND libunistring, NOT THE BUNDLED COPIES.
#
# gnutls ships lib/minitasn1 and lib/unistring and can be told to use them with
# --with-included-libtasn1 / --with-included-unistring. It is NOT told to, and
# the defaults hard-error rather than falling back -- but that is a claim about
# configure, and this is the artefact. If either ever resolved to the bundled
# copy, the DT_NEEDED entry is what disappears: the library would still build,
# still work, and quietly carry a second private implementation that no
# security update to libtasn1 would ever reach.
echo "$needed" | grep -q 'NEEDED.*libtasn1' \
	|| die "libgnutls does not link the system libtasn1; the bundled minitasn1 was used"
echo "$needed" | grep -q 'NEEDED.*libunistring' \
	|| die "libgnutls does not link the system libunistring; the bundled copy was used"

# nettle and hogweed, the two halves of the crypto backend. hogweed is the
# public-key one; without it there is no RSA or ECDSA and therefore no
# certificate authentication, which is a working TLS library that cannot
# authenticate anybody.
echo "$needed" | grep -q 'NEEDED.*libnettle' || die "libgnutls does not link libnettle"
echo "$needed" | grep -q 'NEEDED.*libhogweed' || die "libgnutls does not link libhogweed; no public-key support"

# p11-kit, which is where the trust store comes from.
echo "$needed" | grep -q 'NEEDED.*libp11-kit' \
	|| die "libgnutls does not link p11-kit; --without-p11-kit took effect and there is no trust store"

# THE COMPRESSION LIBRARIES, AS LINKS RATHER THAN dlopen.
#
# --with-*=link was passed precisely so these appear here. Left at their
# default the three would be dlopened by soname, carry no DT_NEEDED at all,
# and this assertion would be the only thing able to tell the difference --
# which is why it is written against DT_NEEDED and not against a config
# summary line.
for l in libz libbrotlidec libzstd; do
	echo "$needed" | grep -q "NEEDED.*$l" \
		|| die "libgnutls does not link $l; --with-*=link did not take and the library would dlopen it instead"
done

# THE DEFAULT TRUST STORE, WHICH IS THE ONE THING THAT MAKES THIS USEFUL.
#
# --with-default-trust-store-pkcs11 is a STRING baked into the library. A typo
# is not an error, it is a URI that resolves to nothing, and the result is a
# TLS stack that negotiates perfectly and trusts no certificate authority.
# There is no runtime warning for an empty trust store. Checked in the shipped
# binary rather than in the recipe.
if ! strings "$lib" 2>/dev/null | grep -q '^pkcs11:'; then
	die "no pkcs11: trust store URI in libgnutls; --with-default-trust-store-pkcs11 did not take"
fi

# Static archives, asserted absent. gnutls defaults to shared-only so no flag
# is passed for this; the assertion is what makes that true rather than assumed.
if [ -e "$DESTDIR/usr/lib/libgnutls.a" ]; then
	die "libgnutls.a was installed"
fi

log "installed gnutls: system libtasn1 and libunistring, nettle+hogweed, p11-kit trust store"
