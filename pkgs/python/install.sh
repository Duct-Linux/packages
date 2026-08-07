#!/bin/sh
# Install Python, and give it the unversioned names things actually invoke.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
make DESTDIR="$DESTDIR" install || die "make install failed"

# Upstream installs python3 and python3.13 but no bare `python`. Plenty of
# configure scripts -- glibc's among them -- look for `python`, so the absence
# is the difference between building and not.
cd "$DESTDIR/usr/bin"
[ -e python3 ] || die "python3 was not installed"
[ -e python ] || ln -s python3 python

rm -f "$DESTDIR/usr/share/info/dir"
find "$DESTDIR" -name '*.la' -type f -delete 2>/dev/null || true
strip_payload

log "installed $(./python3 --version 2>&1 || echo python)"
