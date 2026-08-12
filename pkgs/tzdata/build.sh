#!/bin/sh
# tzdata has no configure and nothing to compile. The "build" is zic, glibc's
# time zone compiler, turning the source zone files into the TZif binaries the
# C library reads.
#
# Everything happens in install.sh instead, because zic writes its output
# directly into a destination directory -- there is no build tree to stage from
# and no `make install` to run. This file exists to say that rather than to
# leave the build stage looking forgotten.

. "$(dirname "$0")/../_scripts/common.sh"

command -v zic >/dev/null 2>&1 || die "no zic; it comes from glibc, which must be seeded before this package builds"

log "nothing to compile; the zone files are compiled by zic during install"
