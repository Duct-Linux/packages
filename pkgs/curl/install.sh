#!/bin/sh
# Stage curl, and refuse to ship one that cannot speak TLS.
#
# curl's configure does not fail when it finds no usable TLS backend -- it
# builds a libcurl that simply cannot fetch an https URL, and says so only in a
# summary line nobody reads. This package has already shipped in that state
# once, when it was built --without-ssl to get past OpenSSL 4.0, and the gap was
# invisible from the artifact.
#
# The same class cost the distribution a python published with no ssl module:
# it built, it installed, and nothing could tell. An assertion here is what
# turns "quietly missing a feature" into "this build fails".
#
# Checked from libcurl.pc rather than by running the binary: a staged curl
# cannot find its own libcurl, and the loader error that produces looks like a
# broken build when nothing is wrong.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
make DESTDIR="$DESTDIR" install || die "make install failed"

pc=$DESTDIR/usr/lib/pkgconfig/libcurl.pc
[ -f "$pc" ] || die "libcurl.pc was not installed"

# supported_features is generated from what configure actually found.
grep -q '^supported_features=.*SSL' "$pc" \
	|| die "this libcurl has no TLS backend -- it cannot fetch an https URL.
	curl's configure does not fail on a missing TLS backend, it just builds
	without one, so check that openssl was installed before this package built."

[ -x "$DESTDIR/usr/bin/curl" ] || die "the curl tool was not installed"

finish_install
log "installed curl with TLS"
