#!/bin/sh
# Install cargo-c's binaries, then prove they carry NO dynamic openssl.
#
# WHY THIS ASSERTION IS THE POINT OF THE RECIPE. cargo-c depends on the cargo
# crate, which pulls openssl-sys, libgit2 and libcurl. Built without
# --features vendored-openssl the binaries name libcrypto.so.N and libssl.so.N
# in DT_NEEDED, and then have to FIND that exact SONAME at run time in whichever
# container receives them. This tree has two openssl majors in play -- 3.5.7 in
# the published index, 4.0.1 in some build images -- so such a binary works
# where it was built and fails to start where it is used, with a message naming
# a library rather than naming cargo-c.
#
# The flag in pkg.env is not evidence: features can be misspelled, renamed
# upstream, or dropped by a future edit, and the build succeeds either way. The
# binary either names openssl or it does not.
#
# AND THE DETECTOR IS ITSELF CHECKED. A grep for NEEDED lines that silently
# matched nothing -- wrong readelf flags, a busybox readelf, an unexpected
# output format -- would report "no openssl" for every binary on earth,
# including one that links it. So the same function is first run against a
# binary that certainly DOES link openssl. If that does not fire, the clean
# result below means nothing and this fails instead.

. "$(dirname "$0")/../_scripts/common.sh"

bins="cargo-capi cargo-cbuild cargo-cinstall cargo-ctest"
target=$SRC_PATH/target/release

log "installing into the staging root"
install -d "$DESTDIR/usr/bin"
for b in $bins; do
	[ -s "$target/$b" ] || die "$b was not produced by the build"
	install -m 755 "$target/$b" "$DESTDIR/usr/bin/$b"
done

links_openssl() {
	readelf -d "$1" 2>/dev/null | grep -qE 'NEEDED.*\[lib(ssl|crypto)\.so'
}

# THE POSITIVE CONTROL. Without this, a broken detector passes everything.
control=""
for c in /usr/bin/openssl /usr/bin/curl /usr/bin/wget; do
	[ -x "$c" ] && { control=$c; break; }
done
if [ -n "$control" ]; then
	if links_openssl "$control"; then
		log "openssl detector verified against $control"
	else
		die "the openssl detector did not fire on $control, which links libcrypto. The detector is broken, so a clean result on cargo-c's binaries would prove nothing -- refusing to report a pass this check is incapable of failing"
	fi
else
	die "no binary known to link openssl was found to validate the detector against; refusing to run an unchecked check"
fi

# THE ACTUAL ASSERTION.
for b in $bins; do
	if links_openssl "$DESTDIR/usr/bin/$b"; then
		die "$b carries a dynamic openssl in DT_NEEDED despite --features vendored-openssl. It would need that exact SONAME at run time, and this tree has openssl 3.5.7 in the published index against 4.0.1 in some build images -- so this binary would work where it was built and fail to start where it is used"
	fi
done
log "no dynamic libssl or libcrypto in any of cargo-c's binaries"

# The full closure, printed rather than asserted: it is what a future reader
# needs when something DOES change, and it costs one line per binary.
for b in $bins; do
	log "$b DT_NEEDED: $(readelf -d "$DESTDIR/usr/bin/$b" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
done

finish_install
log "installed cargo-c: $bins"
