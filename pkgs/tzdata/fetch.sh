#!/bin/sh
# tzdata's tarball has NO TOP-LEVEL DIRECTORY, which is why this stage is not
# the generic one.
#
# It expands Makefile, africa, asia, europe and forty other files straight into
# whatever directory tar is pointed at, and _scripts/fetch.sh ends with
#
#     tar -xf "$archive" -C "$WORK_DIR"
#     [ -d "$SRC_PATH" ] || die "expected $SRC_DIR/ inside the tarball..."
#
# so the generic stage unpacks correctly and then dies on a directory that was
# never going to exist.
#
# REJECTED: SRC_DIR=. -- which works, and that is exactly what is wrong with it.
# SRC_PATH would become work/., which is always a directory, so fetch.sh's guard
# could never fail for this recipe. An assertion that cannot fail is worse than
# no assertion, and this one would have been load-bearing for every other
# package while being decorative for this one.
#
# So the directory is created here and the tarball unpacked into it, which makes
# the same guard meaningful again: SRC_DIR names a real directory that this
# stage is responsible for producing.
#
# The download-and-verify is NOT duplicated -- verify_sha256 comes from
# common.sh, the same helper the generic stage uses, so the digest rule stays in
# one place. What is repeated here is only the cache-or-fetch branch.

. "$(dirname "$0")/../_scripts/common.sh"

[ -n "${SRC_URL:-}" ] || die "SRC_URL is not set"
[ -n "${SRC_SHA256:-}" ] || die "SRC_SHA256 is required whenever SRC_URL is set"
[ -n "${SRC_DIR:-}" ] || die "SRC_DIR is required; this stage creates it"

mkdir -p "$SRC_CACHE"
archive=$SRC_CACHE/${SRC_FILE:-$(basename "$SRC_URL")}

if [ -f "$archive" ] && verify_sha256 "$archive" "$SRC_SHA256" 2>/dev/null; then
	log "using cached $(basename "$archive")"
else
	# A cached file that fails verification is deleted rather than reused: it is
	# either a partial download or something that is not what we asked for.
	rm -f "$archive"
	log "fetching $SRC_URL"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "$archive.part" "$SRC_URL" || die "download failed"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$archive.part" "$SRC_URL" || die "download failed"
	else
		die "no curl or wget available to fetch $SRC_URL"
	fi
	verify_sha256 "$archive.part" "$SRC_SHA256" || die "refusing to use a source that does not match its recorded digest"
	mv "$archive.part" "$archive"
fi

log "unpacking into $(basename "$WORK_DIR")/$SRC_DIR/"
mkdir -p "$SRC_PATH"
tar -xf "$archive" -C "$SRC_PATH" || die "could not unpack $archive"

# The same guard the generic stage makes, and it means something here because
# the line above is what has to have worked.
[ -f "$SRC_PATH/europe" ] || die "the tzdata source does not look right: no 'europe' zone file in $SRC_PATH"
