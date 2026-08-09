#!/bin/sh
# Build libcap. No configure script: a hand-written Makefile taking variables.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# The static archive is not wanted and, unusually, has to be refused in the
# makefile rather than at configure time.
sed -i '/install -m.*STA/d' libcap/Makefile || die "could not disable the static library"

# lib=lib, not the default lib64: Duct is a merged-/usr system whose libraries
# all live in /usr/lib, and libcap would otherwise create a second library
# directory that nothing is configured to search.
log "building with -j$JOBS"
make -j"$JOBS" prefix=/usr lib=lib || die "make failed"
