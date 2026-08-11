#!/bin/sh
# Stage libtasn1 and assert it is a shared library with a .pc, and that no
# static archive came with it.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

finish_install

# The library through its soname link. The major is CURRENT - AGE, read out of
# configure (LT_CURRENT=12, LT_AGE=6) rather than guessed from the 4.20.0 in
# the package name -- the two numbers are unrelated, and a wrong guess here
# would assert the existence of a file that never existed and fail every build.
# -s follows the link, so this checks the link AND that its target is non-empty.
[ -s "$DESTDIR/usr/lib/libtasn1.so.6" ] || die "libtasn1.so.6 was not installed"

# The .pc is the whole interface for the two consumers in this wave. p11-kit
# takes dependency('libtasn1'), and gnutls pkg-config-checks `libtasn1 >=
# $LIBTASN1_MINIMUM` and HARD-ERRORS when it is missing rather than quietly
# using its own bundled lib/minitasn1 -- so a libtasn1 without this file does
# not degrade gnutls, it stops it.
[ -s "$DESTDIR/usr/lib/pkgconfig/libtasn1.pc" ] || die "libtasn1.pc was not installed"

# THE OUTCOME OF --disable-static, asserted rather than trusted, because the
# flag is load-bearing here: configure builds static libraries by default
# (unlike npth, where libtool already defaulted to shared-only) and nothing in
# finish_install prunes .a files. A static archive would ship silently.
#
# `if ... then die`, not `[ ... ] && die`: under set -e a failing test at the
# head of an AND-list can end the script, and here the test failing is the
# GOOD outcome.
if [ -e "$DESTDIR/usr/lib/libtasn1.a" ]; then
	die "libtasn1.a was installed; --disable-static did not take"
fi

# The header every consumer includes.
[ -s "$DESTDIR/usr/include/libtasn1.h" ] || die "libtasn1.h was not installed"

# THE asn1Parser BINARY, WHICH IS A DEPENDENCY NO LINKAGE CHECK CAN SEE.
#
# p11-kit does not merely link libtasn1; its trust module needs the COMMAND:
#
#     libtasn1  = dependency('libtasn1', required: get_option('trust_module'))
#     asn1Parser = find_program('asn1Parser', required: get_option('trust_module'))
#     if asn1Parser.found() ... with_trust_module = true
#
# Under the upstream default of trust_module='auto' neither is required, so a
# libtasn1 that shipped the library and not this program would leave p11-kit
# building cleanly WITH NO TRUST MODULE -- which is to say no CA anchors, and
# a TLS stack that validates against nothing. Nothing in a DT_NEEDED scan or a
# .pc check would notice, because the relationship is an exec, not a link.
#
# p11-kit's own recipe pins -Dtrust_module=enabled so that it fails loudly
# instead; this assertion is the other half, on the producing side.
[ -x "$DESTDIR/usr/bin/asn1Parser" ] || die "asn1Parser was not installed; p11-kit would silently build with no trust module"

log "installed libtasn1, shared only"
