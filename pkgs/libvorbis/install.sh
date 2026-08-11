#!/bin/sh
# Stage libvorbis and prove the THREE libraries it ships are all present.
#
# WHY ALL THREE. libvorbis builds libvorbis, libvorbisenc and libvorbisfile, and
# they are not interchangeable: libcanberra asks pkg-config for `vorbisfile`
# specifically (configure.ac:586), which is the highest-level of the three and
# the one a decode-only consumer needs. Asserting libvorbis.so alone would pass
# on a build that shipped the core and not the file API -- and the failure would
# surface in libcanberra's configure as "vorbisfile not found" against a
# libvorbis package that looks installed.

. "$(dirname "$0")/../_scripts/common.sh"

cd "$BUILD_DIR"
log "installing into the staging root"
make DESTDIR="$DESTDIR" install || die "make install failed"

for lib in libvorbis libvorbisenc libvorbisfile; do
	[ -s "$DESTDIR/usr/lib/$lib.so" ] || die "$lib.so is missing or empty"
done
[ -s "$DESTDIR/usr/lib/pkgconfig/vorbisfile.pc" ] || \
	die "vorbisfile.pc is missing or empty; libcanberra's configure asks pkg-config for 'vorbisfile' by that exact name"

finish_install
log "installed libvorbis with its enc and file libraries"
