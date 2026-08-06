#!/bin/sh
# Stage 1 -- fetch and unpack the upstream tarball.
#
# Every source is verified against a recorded sha256 before it is unpacked. The
# old distro scripts decided a cached download was valid by checking whether a
# sidecar file mentioned the URL, which verifies nothing at all: a truncated,
# corrupted or substituted tarball passed just as happily as a good one.

. "$(dirname "$0")/common.sh"

if [ -z "${SRC_URL:-}" ]; then
	log "no SRC_URL; nothing to fetch"
	exit 0
fi

[ -n "${SRC_SHA256:-}" ] || die "SRC_SHA256 is required whenever SRC_URL is set"
[ -n "${SRC_DIR:-}" ] || die "SRC_DIR (the directory inside the tarball) is required"

mkdir -p "$SRC_CACHE"

# SRC_FILE exists because a URL's last path element is not always a usable file
# name. GitHub's archive URLs end in the bare tag, so uutils 0.10.0 would cache
# as "0.10.0.tar.gz" -- uninformative on its own and liable to collide with any
# other project that ever tags 0.10.0.
archive=$SRC_CACHE/${SRC_FILE:-$(basename "$SRC_URL")}

if [ -f "$archive" ] && verify_sha256 "$archive" "$SRC_SHA256" 2>/dev/null; then
	log "using cached $(basename "$archive")"
else
	# A cached file that fails verification is deleted rather than reused: it is
	# either a partial download or something that is not what we asked for, and
	# both should be re-fetched rather than silently trusted.
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

log "unpacking into $(basename "$WORK_DIR")/"
tar -xf "$archive" -C "$WORK_DIR"

[ -d "$SRC_PATH" ] || die "expected $SRC_DIR/ inside the tarball, but it is not there"
