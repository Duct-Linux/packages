#!/bin/sh
# Install the sanitised kernel headers userspace compiles against.
#
# These are not the kernel's internal headers -- those are not usable outside
# the tree. `make headers` produces the exported subset, which is what glibc and
# every other package build against.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$SRC_PATH"

# Guarantees no generated file from a previous build or from the tarball itself
# leaks into the exported set.
log "cleaning the kernel tree"
make mrproper >/dev/null

log "exporting headers"
make headers >/dev/null

# The headers target leaves behind a few non-header artefacts that must not ship.
find usr/include -type f ! -name '*.h' -delete

# The destination mode is set here rather than inherited: cp -r takes the mode
# from the source directory, which the kernel's own build created under
# whatever umask was in effect.
install -d "$DESTDIR/usr"
install -d -m 0755 "$DESTDIR/usr/include"
cp -r usr/include/. "$DESTDIR/usr/include/"

[ -f "$DESTDIR/usr/include/linux/version.h" ] || die "headers were not produced"
log "installed $(find "$DESTDIR/usr/include" -name '*.h' | wc -l) headers"
