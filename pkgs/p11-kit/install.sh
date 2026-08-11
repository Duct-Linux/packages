#!/bin/sh
# Stage p11-kit and assert the trust module actually exists.

. "$(dirname "$0")/../_scripts/common.sh"

log "installing into the staging root"
DESTDIR="$DESTDIR" meson install -C "$BUILD_DIR" --no-rebuild --skip-subprojects \
	|| die "meson install failed"

finish_install

# The router itself and its .pc files.
[ -s "$DESTDIR/usr/lib/libp11-kit.so.0" ] || die "libp11-kit.so.0 was not installed"
for pc in p11-kit-1.pc; do
	[ -s "$DESTDIR/usr/lib/pkgconfig/$pc" ] || die "$pc was not installed"
done
[ -x "$DESTDIR/usr/bin/p11-kit" ] || die "the p11-kit tool was not installed"

# THE TRUST MODULE, WHICH IS THE WHOLE REASON -Dtrust_module=enabled IS PINNED.
#
# Under the upstream default of 'auto' this file is simply not built when
# libtasn1 or the asn1Parser PROGRAM cannot be found, and the build succeeds
# anyway. A p11-kit without it installs cleanly, answers PKCS#11 calls, and
# knows no certificate authorities -- so everything above it validates against
# an empty trust store rather than failing. Its presence is the only evidence
# in the payload that the option took effect.
[ -s "$DESTDIR/usr/lib/pkcs11/p11-kit-trust.so" ] \
	|| die "p11-kit-trust.so was not built; the trust module is missing and nothing would have said so"

# The trust module links libtasn1 -- checked in the built object rather than
# inferred from the flag, because 'enabled' could in principle be satisfied by
# a libtasn1 found at configure time and not linked here.
if command -v readelf >/dev/null 2>&1; then
	readelf -d "$DESTDIR/usr/lib/pkcs11/p11-kit-trust.so" 2>/dev/null \
		| grep -q 'NEEDED.*libtasn1' \
		|| die "p11-kit-trust.so does not link libtasn1"
else
	die "no readelf; cannot verify the trust module's libtasn1 link, and this check is not optional"
fi

# THE COMPILED-IN TRUST PATH. -Dtrust_paths is a STRING: a typo is not an
# error, it is a path, and the trust module would load zero anchors from it.
# BLFS's own value (/etc/pki/anchors) is exactly such a path on this system,
# which is why this is checked against the binary rather than against the
# recipe. grep the shipped object for the path we asked for.
if ! strings "$DESTDIR/usr/lib/pkcs11/p11-kit-trust.so" 2>/dev/null | grep -q '/etc/pki/tls/certs/ca-bundle.crt'; then
	die "the trust module does not carry the configured trust path; -Dtrust_paths did not take"
fi

# -Dbash_completion=disabled and -Dtest=false, asserted as absences.
if [ -e "$DESTDIR/usr/share/bash-completion" ]; then
	die "bash completions were installed; -Dbash_completion did not take"
fi

log "installed p11-kit with its trust module"
