#!/bin/sh
# Build sassc against the installed libsass.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# Without SASS_LIBSASS_PATH the Makefile expects a libsass source tree beside
# it and builds its own copy; pointing it at the system one is what makes this
# a package rather than a second private libsass.
export SASSC_VERSION=3.6.2
export SASS_LIBSASS_PATH=

log "building with -j$JOBS"
make -j"$JOBS" sassc || die "make failed"

[ -x bin/sassc ] || die "sassc was not produced"
